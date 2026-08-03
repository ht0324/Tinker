# Codex usage ledger

The bundled `codex-usage-ledger` task records estimated Standard-tier API-equivalent Codex cost for the local Mac and any configured remote hosts. These figures are estimates, not invoices or measured ChatGPT or Codex subscription spend.

## Private configuration

The task reads an optional environment file from its runtime folder:

```text
~/Library/Application Support/TinkerBar/tasks/codex-usage-ledger/config.env
```

For example:

```zsh
TINKERBAR_CODEX_USAGE_REMOTE_HOSTS="workstation server"
TINKERBAR_CODEX_USAGE_TIMEZONE="America/Los_Angeles"
```

Keep this file out of Git. Set `TINKERBAR_CODEX_USAGE_CONFIG_FILE` to read configuration from another private path.

## How collection works

The worker runs the pinned `ccusage@20.0.17` collector through `npx` on each configured host. The first run may take longer while npm fetches the package. No global ccusage installation is required, although `npx` may contact npm to obtain the pinned version.

The collector uses its embedded offline pricing data. TinkerBar fixes estimates to Standard-tier pricing so switching a host between Fast and Priority does not change historical figures.

The ledger keeps the model breakdown returned by ccusage and marks fallback-attributed or potentially unpriced rows in `latest-summary.json`. A local, best-effort Codex App Server probe also records the current official model catalog and aggregate account activity for reference. The official data has no per-host or per-model dollar breakdown, so it does not replace the ccusage estimate.

## Ledger migrations

When the ledger schema or pinned collector version changes, TinkerBar rebuilds the history in temporary files. It switches to them only after collection succeeds for every configured host and the replacement summary passes validation.

The ledger and summary share a generation ID. If a switch is interrupted, the app hides the estimate instead of combining mismatched generations. After a successful migration, the previous ledger and summary receive timestamped `.bak` copies. A failed migration leaves the originals untouched.
