#!/usr/bin/env node

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const codexBin = process.argv[2] || "codex";
const timeoutMilliseconds = Number.parseInt(
    process.env.TINKERBAR_CODEX_USAGE_OFFICIAL_TIMEOUT_MS || "12000",
    10
);

const child = spawn(codexBin, ["app-server", "--listen", "stdio://"], {
    stdio: ["pipe", "pipe", "pipe"],
});

let settled = false;
let initialized = false;
let usageResult;
let usageError = null;
let nextRequestID = 10;
let pendingModelRequestID = null;
let pendingUsageRequestID = null;
let modelPages = 0;
const models = [];
let modelError = null;
let stderr = "";
const seenCursors = new Set();

function stopChild() {
    if (child.exitCode !== null || child.signalCode !== null) {
        return;
    }

    child.kill("SIGTERM");
    const forceKillTimer = setTimeout(() => {
        if (child.exitCode === null && child.signalCode === null) {
            child.kill("SIGKILL");
        }
    }, 750);
    forceKillTimer.unref();
}

function normalizedError(error) {
    if (!error) {
        return null;
    }

    if (typeof error === "string") {
        return { message: error };
    }

    return {
        code: typeof error.code === "number" ? error.code : null,
        message: typeof error.message === "string" ? error.message : "Unknown App Server error",
    };
}

function send(message) {
    child.stdin.write(`${JSON.stringify(message)}\n`);
}

function requestModelPage(cursor = null) {
    pendingModelRequestID = nextRequestID++;
    const params = { includeHidden: true, limit: 100 };
    if (cursor) {
        params.cursor = cursor;
    }
    send({ method: "model/list", id: pendingModelRequestID, params });
}

function finishIfReady() {
    if (settled || !initialized || pendingUsageRequestID !== null || pendingModelRequestID !== null) {
        return;
    }

    settled = true;
    clearTimeout(timeout);
    child.stdin.end();

    const normalizedModels = models
        .filter((model) => model && typeof model === "object")
        .map((model) => ({
            id: typeof model.id === "string" ? model.id : null,
            model: typeof model.model === "string" ? model.model : null,
            displayName: typeof model.displayName === "string" ? model.displayName : null,
            hidden: model.hidden === true,
            isDefault: model.isDefault === true,
            serviceTiers: Array.isArray(model.serviceTiers) ? model.serviceTiers : [],
        }));

    process.stdout.write(`${JSON.stringify({
        schemaVersion: 1,
        capturedAt: new Date().toISOString(),
        models: {
            available: modelError === null,
            data: normalizedModels,
            error: normalizedError(modelError),
        },
        accountUsage: {
            available: usageError === null && usageResult !== undefined,
            summary: usageResult?.summary ?? null,
            dailyUsageBuckets: usageResult?.dailyUsageBuckets ?? null,
            error: normalizedError(usageError),
        },
    })}\n`);

    const gracefulExitTimer = setTimeout(stopChild, 1_000);
    gracefulExitTimer.unref();
}

function fail(message) {
    if (settled) {
        return;
    }

    settled = true;
    clearTimeout(timeout);
    stopChild();
    const stderrSuffix = stderr.trim() ? `: ${stderr.trim().slice(-1000)}` : "";
    process.stderr.write(`${message}${stderrSuffix}\n`);
    process.exitCode = 1;
}

const timeout = setTimeout(() => {
    fail(`Codex App Server probe timed out after ${timeoutMilliseconds} ms`);
}, timeoutMilliseconds);

child.on("error", (error) => {
    fail(`Could not start Codex App Server: ${error.message}`);
});

child.stderr.on("data", (chunk) => {
    stderr = `${stderr}${chunk.toString("utf8")}`.slice(-4000);
});

child.on("exit", (code, signal) => {
    if (!settled) {
        fail(`Codex App Server exited before the probe completed (${signal || code})`);
    }
});

const lines = createInterface({ input: child.stdout });
lines.on("line", (line) => {
    let message;
    try {
        message = JSON.parse(line);
    } catch {
        fail("Codex App Server emitted malformed JSON");
        return;
    }

    if (message.id === 1) {
        if (message.error) {
            fail(`Codex App Server initialization failed: ${message.error.message || "unknown error"}`);
            return;
        }

        initialized = true;
        send({ method: "initialized", params: {} });
        requestModelPage();
        pendingUsageRequestID = nextRequestID++;
        send({ method: "account/usage/read", id: pendingUsageRequestID });
        return;
    }

    if (message.id === pendingUsageRequestID) {
        pendingUsageRequestID = null;
        if (message.error) {
            usageError = message.error;
        } else if (
            !message.result ||
            typeof message.result !== "object" ||
            !message.result.summary ||
            typeof message.result.summary !== "object" ||
            !Array.isArray(message.result.dailyUsageBuckets) ||
            message.result.dailyUsageBuckets.some((bucket) =>
                !bucket ||
                typeof bucket !== "object" ||
                typeof bucket.startDate !== "string" ||
                !Number.isSafeInteger(bucket.tokens) ||
                bucket.tokens < 0
            )
        ) {
            usageError = { message: "App Server returned an invalid account-usage result" };
        } else {
            usageResult = message.result;
        }
        finishIfReady();
        return;
    }

    if (message.id === pendingModelRequestID) {
        pendingModelRequestID = null;
        if (message.error) {
            modelError = message.error;
            finishIfReady();
            return;
        }

        if (
            !message.result ||
            typeof message.result !== "object" ||
            !Array.isArray(message.result.data) ||
            message.result.data.some((model) =>
                !model ||
                typeof model !== "object" ||
                (typeof model.id !== "string" && typeof model.model !== "string")
            ) ||
            (
                message.result.nextCursor !== null &&
                message.result.nextCursor !== undefined &&
                typeof message.result.nextCursor !== "string"
            )
        ) {
            modelError = { message: "App Server returned an invalid model catalog result" };
            finishIfReady();
            return;
        }

        const page = message.result.data;
        models.push(...page);
        const nextModelCursor = message.result?.nextCursor ?? null;
        modelPages += 1;

        if (nextModelCursor && modelPages < 20 && !seenCursors.has(nextModelCursor)) {
            seenCursors.add(nextModelCursor);
            requestModelPage(nextModelCursor);
        } else if (nextModelCursor) {
            modelError = { message: "Model catalog pagination did not complete safely" };
        }

        finishIfReady();
    }
});

send({
    method: "initialize",
    id: 1,
    params: {
        clientInfo: {
            name: "tinkerbar",
            title: "TinkerBar",
            version: "0.1.0",
        },
    },
});

for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, () => {
        if (!settled) {
            settled = true;
            clearTimeout(timeout);
            process.stderr.write(`Codex App Server probe interrupted by ${signal}\n`);
        }
        stopChild();
        process.exitCode = 128 + (signal === "SIGINT" ? 2 : 15);
    });
}
