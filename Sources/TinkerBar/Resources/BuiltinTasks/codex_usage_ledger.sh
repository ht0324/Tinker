#!/bin/zsh
emulate -LR zsh
set -euo pipefail
setopt pipefail

STATUS_FILE="${1:-$HOME/Library/Application Support/TinkerBar/tasks/codex-usage-ledger/status.tsv}"
LOG_FILE="${2:-$HOME/Library/Application Support/TinkerBar/tasks/codex-usage-ledger/task.log}"
LOCK_DIR="${STATUS_FILE}.lock"
TASK_DIR="${STATUS_FILE:h}"
LEDGER_FILE="$TASK_DIR/ledger.jsonl"
SUMMARY_FILE="$TASK_DIR/latest-summary.json"
OFFICIAL_SNAPSHOT_FILE="$TASK_DIR/official-usage.json"
CONFIG_FILE="${TINKERBAR_CODEX_USAGE_CONFIG_FILE:-$TASK_DIR/config.env}"
REMOTE_HOSTS=()
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

mkdir -p "$TASK_DIR" "${LOG_FILE:h}"

if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

TIMEZONE="${TINKERBAR_CODEX_USAGE_TIMEZONE:-${TIMEZONE:-America/Los_Angeles}}"
FETCH_TIMEOUT_SECONDS="${TINKERBAR_CODEX_USAGE_FETCH_TIMEOUT_SECONDS:-${FETCH_TIMEOUT_SECONDS:-300}}"
DISCOVERY_FLOOR_DATE="${TINKERBAR_CODEX_USAGE_DISCOVERY_FLOOR_DATE:-${DISCOVERY_FLOOR_DATE:-2024-01-01}}"
LEDGER_SCHEMA_VERSION=2
CCUSAGE_VERSION="20.0.17"
CCUSAGE_PACKAGE="ccusage@$CCUSAGE_VERSION"
# Keep historical estimates comparable. The active Codex client tier must not
# retroactively change the price basis of previously recorded usage.
CCUSAGE_SPEED="standard"
CCUSAGE_BIN_OVERRIDE="${TINKERBAR_CODEX_USAGE_CCUSAGE_BIN:-}"
NPX_BIN="${TINKERBAR_CODEX_USAGE_NPX_BIN:-npx}"
SSH_BIN="${TINKERBAR_CODEX_USAGE_SSH_BIN:-${SSH_BIN:-ssh}}"
NODE_BIN="${TINKERBAR_CODEX_USAGE_NODE_BIN:-node}"
CODEX_CLI_BIN="${TINKERBAR_CODEX_USAGE_CODEX_CLI_BIN:-codex}"
APP_SERVER_HELPER="${TINKERBAR_CODEX_USAGE_APP_SERVER_HELPER:-$TASK_DIR/codex-usage-app-server.mjs}"
OFFICIAL_PROBE_ENABLED="${TINKERBAR_CODEX_USAGE_OFFICIAL_PROBE_ENABLED:-1}"
OFFICIAL_PROBE_TIMEOUT_SECONDS="${TINKERBAR_CODEX_USAGE_OFFICIAL_TIMEOUT_SECONDS:-20}"

if [[ -n "${TINKERBAR_CODEX_USAGE_REMOTE_HOSTS:-}" ]]; then
  remote_hosts_value="${TINKERBAR_CODEX_USAGE_REMOTE_HOSTS//,/ }"
  REMOTE_HOSTS=(${=remote_hosts_value})
fi

if [[ -n "${TINKERBAR_CODEX_USAGE_SSH_OPTIONS:-}" ]]; then
  ssh_options_value="$TINKERBAR_CODEX_USAGE_SSH_OPTIONS"
  SSH_OPTIONS=(${=ssh_options_value})
fi

touch "$LEDGER_FILE"
exec >>"$LOG_FILE" 2>&1

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] error: another run owns $LOCK_DIR"
  exit 75
fi
TEMP_FILES=()
cleanup() {
  local temp_file
  for temp_file in "${TEMP_FILES[@]:-}"; do
    [[ -n "$temp_file" ]] && rm -f "$temp_file"
  done
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

today_in_timezone() {
  TZ="$TIMEZONE" date +%Y-%m-%d
}

yesterday_in_timezone() {
  TZ="$TIMEZONE" date -v-1d +%Y-%m-%d
}

month_start_in_timezone() {
  TZ="$TIMEZONE" date +%Y-%m-01
}

initial_start_in_timezone() {
  print -r -- "$DISCOVERY_FLOOR_DATE"
}

next_date() {
  TZ="$TIMEZONE" date -j -v+1d -f "%Y-%m-%d" "$1" +%Y-%m-%d
}

date_to_epoch() {
  TZ="$TIMEZONE" date -j -f "%Y-%m-%d" "$1" +%s
}

date_is_on_or_before() {
  local left_epoch right_epoch
  left_epoch=$(date_to_epoch "$1")
  right_epoch=$(date_to_epoch "$2")
  [[ "$left_epoch" -le "$right_epoch" ]]
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "[$(timestamp)] error: missing required command: $name"
    exit 1
  fi
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  perl -MPOSIX=:sys_wait_h -e '
    my $timeout = shift @ARGV;
    my @cmd = @ARGV;
    my $pid = fork();
    die "fork failed: $!\n" unless defined $pid;

    if ($pid == 0) {
      setpgrp(0, 0);
      exec @cmd or die "exec failed: $!\n";
    }

    my $deadline = time() + $timeout;
    while (1) {
      my $done = waitpid($pid, WNOHANG);
      if ($done == $pid) {
        my $status = $?;
        exit(128 + ($status & 127)) if $status & 127;
        exit($status >> 8);
      }

      if (time() >= $deadline) {
        warn "command timed out after ${timeout}s: @cmd\n";
        kill "TERM", -$pid;
        select undef, undef, undef, 1;
        kill "KILL", -$pid;
        waitpid($pid, 0);
        exit 124;
      }

      select undef, undef, undef, 0.2;
    }
  ' "$timeout_seconds" "$@"
}

latest_date_for_host() {
  local host="$1"

  if [[ ! -s "$COLLECTION_LEDGER_FILE" ]]; then
    return 0
  fi

  jq -sr --arg host "$host" '[.[] | select(.host == $host) | .date] | max // ""' \
    "$COLLECTION_LEDGER_FILE"
}

usage_coverage_from_json_file() {
  local json_file="$1"
  jq -r '
    [
      .daily[]? |
      select((.totalTokens // 0) > 0 or (.costUSD // 0) > 0) |
      .date
    ] |
    [min // "", max // ""] |
    @tsv
  ' "$json_file"
}

new_ledger_generation() {
  printf '%s-%s\n' "$(date -u +"%Y%m%dT%H%M%SZ")" "$$"
}

fetch_local_daily_range_json() {
  local since_date="$1"
  local until_date="$2"

  if [[ -n "$CCUSAGE_BIN_OVERRIDE" ]]; then
    run_with_timeout "$FETCH_TIMEOUT_SECONDS" \
      "$CCUSAGE_BIN_OVERRIDE" codex daily --json --offline --speed "$CCUSAGE_SPEED" \
      --timezone "$TIMEZONE" --since "$since_date" --until "$until_date"
  else
    run_with_timeout "$FETCH_TIMEOUT_SECONDS" \
      "$NPX_BIN" --yes "$CCUSAGE_PACKAGE" codex daily --json --offline --speed "$CCUSAGE_SPEED" \
      --timezone "$TIMEZONE" --since "$since_date" --until "$until_date"
  fi
}

fetch_remote_daily_range_json() {
  local host="$1"
  local since_date="$2"
  local until_date="$3"

  run_with_timeout "$FETCH_TIMEOUT_SECONDS" "$SSH_BIN" "${SSH_OPTIONS[@]}" "$host" /bin/zsh <<EOF
emulate -LR zsh
set -euo pipefail
export PATH="\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
npx --yes '$CCUSAGE_PACKAGE' codex daily --json --offline --speed '$CCUSAGE_SPEED' --timezone '$TIMEZONE' --since '$since_date' --until '$until_date'
EOF
}

fetch_daily_range_json() {
  local host="$1"
  local since_date="$2"
  local until_date="$3"

  if [[ "$host" == "local" ]]; then
    fetch_local_daily_range_json "$since_date" "$until_date"
  else
    fetch_remote_daily_range_json "$host" "$since_date" "$until_date"
  fi
}

record_collection_failure() {
  local host="$1"
  local phase="$2"
  local message="$3"

  COLLECTION_ERRORS+=("$message")
  case "$phase" in
    historical) HISTORICAL_FAILED_HOSTS+=("$host") ;;
    today) TODAY_FAILED_HOSTS+=("$host") ;;
  esac
  echo "[$(timestamp)] error: $message"
}

is_valid_daily_json() {
  local json_file="$1"
  local since_date="$2"
  local until_date="$3"
  jq -e \
    --arg since "$since_date" \
    --arg until "$until_date" '
    def nonnegative_number: type == "number" and . >= 0;
    (.daily | type == "array") and
    (.totals | type == "object") and
    (([.daily[].date] | length) == ([.daily[].date] | unique | length)) and
    all(.daily[];
      (.date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
      (.date >= $since and .date <= $until) and
      (.inputTokens | nonnegative_number) and
      (.cacheCreationTokens | nonnegative_number) and
      (.cacheReadTokens | nonnegative_number) and
      (.outputTokens | nonnegative_number) and
      (.reasoningOutputTokens | nonnegative_number) and
      (.totalTokens | nonnegative_number) and
      (.costUSD | nonnegative_number) and
      (.models | type == "object") and
      all(.models | to_entries[];
        (.key | type == "string") and
        (.value | type == "object") and
        (.value.inputTokens | nonnegative_number) and
        (.value.cacheCreationTokens | nonnegative_number) and
        (.value.cacheReadTokens | nonnegative_number) and
        (.value.outputTokens | nonnegative_number) and
        (.value.reasoningOutputTokens | nonnegative_number) and
        (.value.totalTokens | nonnegative_number) and
        (.value.isFallback | type == "boolean")
      )
    )
  ' "$json_file" >/dev/null 2>&1
}

extract_row_for_date() {
  local json_file="$1"
  local host="$2"
  local report_date="$3"
  local captured_at="$4"
  jq -c \
    --arg host "$host" \
    --arg date "$report_date" \
    --arg timezone "$TIMEZONE" \
    --arg capturedAt "$captured_at" \
    --arg ledgerGeneration "$LEDGER_GENERATION" \
    --arg collectorVersion "$CCUSAGE_VERSION" \
    --arg pricingSpeed "$CCUSAGE_SPEED" \
    --argjson schemaVersion "$LEDGER_SCHEMA_VERSION" '
    (
      first(.daily[]? | select(.date == $date)) // {
        date: $date,
        inputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0,
        costUSD: 0,
        models: {}
      }
    ) |
    .models = ((.models // {}) | with_entries(
      .value = {
        inputTokens: (.value.inputTokens // 0),
        cacheCreationTokens: (.value.cacheCreationTokens // 0),
        cacheReadTokens: (.value.cacheReadTokens // 0),
        outputTokens: (.value.outputTokens // 0),
        reasoningOutputTokens: (.value.reasoningOutputTokens // 0),
        totalTokens: (.value.totalTokens // 0),
        isFallback: (.value.isFallback // false)
      }
    )) |
    . + {
      ledgerSchemaVersion: $schemaVersion,
      ledgerGeneration: $ledgerGeneration,
      date: $date,
      host: $host,
      timezone: $timezone,
      capturedAt: $capturedAt,
      costBasis: "estimated_standard_api_equivalent",
      collector: {
        name: "ccusage",
        version: $collectorVersion,
        pricingSource: "embedded_offline",
        speed: $pricingSpeed
      }
    }
  ' "$json_file"
}

append_rows_from_json_file() {
  local json_file="$1"
  local host="$2"
  local start_date="$3"
  local end_date="$4"
  local captured_at="$5"
  local current_date row

  current_date="$start_date"
  while date_is_on_or_before "$current_date" "$end_date"; do
    row=$(extract_row_for_date "$json_file" "$host" "$current_date" "$captured_at")
    printf '%s\n' "$row" >>"$COLLECTION_LEDGER_FILE"
    ROWS_ADDED=$((ROWS_ADDED + 1))
    current_date=$(next_date "$current_date")
  done
}

ledger_requires_migration() {
  [[ -s "$LEDGER_FILE" ]] || return 1

  if jq -se \
    --arg version "$CCUSAGE_VERSION" \
    --arg speed "$CCUSAGE_SPEED" \
    --arg timezone "$TIMEZONE" \
    --argjson schemaVersion "$LEDGER_SCHEMA_VERSION" '
      length > 0 and
      ([.[].ledgerGeneration] | unique | length) == 1 and
      (.[0].ledgerGeneration | type == "string" and length > 0) and
      all(.[];
        (.ledgerSchemaVersion // 0) == $schemaVersion and
        (.collector.version // "") == $version and
        (.collector.speed // "") == $speed and
        (.collector.pricingSource // "") == "embedded_offline" and
        (.timezone // "") == $timezone and
        (.costBasis // "") == "estimated_standard_api_equivalent"
      )
    ' "$LEDGER_FILE" >/dev/null 2>&1; then
    return 1
  fi

  return 0
}

begin_ledger_rebuild() {
  local reason="$1"

  REBUILDING_LEDGER=1
  LEDGER_GENERATION=$(new_ledger_generation)
  STAGING_LEDGER_FILE=$(mktemp "$TASK_DIR/ledger.rebuild.XXXXXX")
  TEMP_FILES+=("$STAGING_LEDGER_FILE")
  COLLECTION_LEDGER_FILE="$STAGING_LEDGER_FILE"
  : >"$COLLECTION_LEDGER_FILE"
  echo "[$(timestamp)] rebuilding Codex usage ledger from $DISCOVERY_FLOOR_DATE ($reason)"
}

original_ledger_has_usage_for_host() {
  local host="$1"
  local has_rows
  [[ -s "$LEDGER_FILE" ]] || return 1
  has_rows=$(jq -sr --arg host "$host" '
    any(.[];
      .host == $host and
      ((.totalTokens // 0) > 0 or (.costUSD // 0) > 0)
    )
  ' "$LEDGER_FILE" 2>/dev/null) || return 0
  [[ "$has_rows" == "true" ]]
}

original_host_usage_coverage() {
  local host="$1"
  jq -sr --arg host "$host" '
    [
      .[] |
      select(
        .host == $host and
        ((.totalTokens // 0) > 0 or (.costUSD // 0) > 0)
      ) |
      .date
    ] |
    [min // "", max // ""] |
    @tsv
  ' "$LEDGER_FILE"
}

commit_ledger_rebuild() {
  local rebuilt_summary_file="$1"
  local rebuild_stamp ledger_backup summary_backup had_ledger=0 had_summary=0
  local ledger_restore summary_restore

  rebuild_stamp=$(date -u +"%Y%m%dT%H%M%SZ")
  if [[ -s "$LEDGER_FILE" ]]; then
    ledger_backup="$LEDGER_FILE.rebuild-$rebuild_stamp.bak"
    cp "$LEDGER_FILE" "$ledger_backup"
    had_ledger=1
  fi
  if [[ -s "$SUMMARY_FILE" ]]; then
    summary_backup="$SUMMARY_FILE.rebuild-$rebuild_stamp.bak"
    cp "$SUMMARY_FILE" "$summary_backup"
    had_summary=1
  fi

  if ! mv "$STAGING_LEDGER_FILE" "$LEDGER_FILE"; then
    echo "[$(timestamp)] error: could not activate rebuilt ledger"
    return 1
  fi

  if ! mv "$rebuilt_summary_file" "$SUMMARY_FILE"; then
    echo "[$(timestamp)] error: could not activate rebuilt summary; restoring previous ledger"
    if [[ "$had_ledger" == "1" ]]; then
      ledger_restore=$(mktemp "$TASK_DIR/ledger.restore.XXXXXX")
      TEMP_FILES+=("$ledger_restore")
      cp "$ledger_backup" "$ledger_restore"
      mv "$ledger_restore" "$LEDGER_FILE"
    else
      ledger_restore=$(mktemp "$TASK_DIR/ledger.restore.XXXXXX")
      TEMP_FILES+=("$ledger_restore")
      mv "$ledger_restore" "$LEDGER_FILE"
    fi
    if [[ "$had_summary" == "1" ]]; then
      summary_restore=$(mktemp "$TASK_DIR/summary.restore.XXXXXX")
      TEMP_FILES+=("$summary_restore")
      cp "$summary_backup" "$summary_restore"
      mv "$summary_restore" "$SUMMARY_FILE"
    fi
    return 1
  fi

  COLLECTION_LEDGER_FILE="$LEDGER_FILE"
  echo "[$(timestamp)] committed rebuilt ledger and summary after validation"
}

is_valid_official_snapshot() {
  local snapshot_file="$1"
  jq -e '
    (.schemaVersion == 1) and
    (.capturedAt | type == "string") and
    (.models | type == "object") and
    (.models.available | type == "boolean") and
    (.models.data | type == "array") and
    all(.models.data[];
      type == "object" and
      ((.id | type == "string") or (.model | type == "string"))
    ) and
    (.accountUsage | type == "object") and
    (.accountUsage.available | type == "boolean") and
    (
      .accountUsage.dailyUsageBuckets == null or
      (
        (.accountUsage.dailyUsageBuckets | type == "array") and
        all(.accountUsage.dailyUsageBuckets[];
          type == "object" and
          (.startDate | type == "string") and
          (.tokens | type == "number" and . >= 0 and . <= 9007199254740991 and . == floor)
        )
      )
    )
  ' "$snapshot_file" >/dev/null 2>&1
}

collect_official_snapshot() {
  local snapshot_tmp

  OFFICIAL_PROBE_WARNING=""
  OFFICIAL_SNAPSHOT_INPUT="$OFFICIAL_SNAPSHOT_FILE"

  if [[ "$OFFICIAL_PROBE_ENABLED" != "1" ]]; then
    OFFICIAL_PROBE_WARNING="Official Codex account probe disabled"
  elif ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    OFFICIAL_PROBE_WARNING="Official Codex account probe unavailable: node not found"
  elif ! command -v "$CODEX_CLI_BIN" >/dev/null 2>&1; then
    OFFICIAL_PROBE_WARNING="Official Codex account probe unavailable: codex not found"
  elif [[ ! -f "$APP_SERVER_HELPER" ]]; then
    OFFICIAL_PROBE_WARNING="Official Codex account probe unavailable: helper not installed"
  else
    snapshot_tmp=$(mktemp)
    TEMP_FILES+=("$snapshot_tmp")
    if run_with_timeout "$OFFICIAL_PROBE_TIMEOUT_SECONDS" \
      "$NODE_BIN" "$APP_SERVER_HELPER" "$CODEX_CLI_BIN" >"$snapshot_tmp" && \
      is_valid_official_snapshot "$snapshot_tmp"; then
      cp "$snapshot_tmp" "$OFFICIAL_SNAPSHOT_FILE.tmp"
      mv "$OFFICIAL_SNAPSHOT_FILE.tmp" "$OFFICIAL_SNAPSHOT_FILE"
      echo "[$(timestamp)] refreshed official Codex model and account-usage snapshot"
    else
      OFFICIAL_PROBE_WARNING="Official Codex account probe failed; using last successful snapshot"
      echo "[$(timestamp)] warning: $OFFICIAL_PROBE_WARNING"
    fi
  fi

  if [[ -s "$OFFICIAL_SNAPSHOT_INPUT" ]] && is_valid_official_snapshot "$OFFICIAL_SNAPSHOT_INPUT"; then
    return 0
  fi

  if [[ -s "$OFFICIAL_SNAPSHOT_INPUT" ]]; then
    if [[ -n "$OFFICIAL_PROBE_WARNING" ]]; then
      OFFICIAL_PROBE_WARNING="$OFFICIAL_PROBE_WARNING; saved snapshot was invalid"
    else
      OFFICIAL_PROBE_WARNING="Official Codex account snapshot was invalid"
    fi
    echo "[$(timestamp)] warning: $OFFICIAL_PROBE_WARNING"
  fi

  if [[ ! -s "$OFFICIAL_SNAPSHOT_INPUT" ]] || ! is_valid_official_snapshot "$OFFICIAL_SNAPSHOT_INPUT"; then
    OFFICIAL_SNAPSHOT_INPUT=$(mktemp)
    TEMP_FILES+=("$OFFICIAL_SNAPSHOT_INPUT")
    jq -nc \
      --arg capturedAt "$(timestamp)" \
      --arg error "$OFFICIAL_PROBE_WARNING" '
      {
        schemaVersion: 1,
        capturedAt: $capturedAt,
        models: {available: false, data: [], error: {message: $error}},
        accountUsage: {
          available: false,
          summary: null,
          dailyUsageBuckets: null,
          error: {message: $error}
        }
      }
    ' >"$OFFICIAL_SNAPSHOT_INPUT"
  fi
}

write_summary() {
  local ledger_input_file="$1"
  local summary_output_file="$2"
  local generated_at="$3"
  local month_start="$4"
  local today_rows_file="$5"
  local today_date="$6"
  local yesterday_date="$7"
  local configured_hosts_json historical_failed_hosts_json today_failed_hosts_json

  configured_hosts_json=$(printf '%s\n' "${CONFIGURED_HOSTS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
  historical_failed_hosts_json=$(printf '%s\n' "${HISTORICAL_FAILED_HOSTS[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
  today_failed_hosts_json=$(printf '%s\n' "${TODAY_FAILED_HOSTS[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')

  jq -s \
    --slurpfile todayRows "$today_rows_file" \
    --slurpfile official "$OFFICIAL_SNAPSHOT_INPUT" \
    --arg generatedAt "$generated_at" \
    --arg timezone "$TIMEZONE" \
    --arg monthStart "$month_start" \
    --arg todayDate "$today_date" \
    --arg yesterdayDate "$yesterday_date" \
    --arg collectorVersion "$CCUSAGE_VERSION" \
    --arg pricingSpeed "$CCUSAGE_SPEED" \
    --arg ledgerGeneration "$LEDGER_GENERATION" \
    --arg officialProbeWarning "$OFFICIAL_PROBE_WARNING" \
    --argjson ledgerSchemaVersion "$LEDGER_SCHEMA_VERSION" \
    --argjson configuredHosts "$configured_hosts_json" \
    --argjson historicalFailedHosts "$historical_failed_hosts_json" \
    --argjson todayFailedHosts "$today_failed_hosts_json" '
    def by_host(rows):
      (rows
        | sort_by(.host)
        | group_by(.host)
        | map({
            host: .[0].host,
            rows: length,
            totalCostUSD: (map(.costUSD // 0) | add // 0),
            totalTokens: (map(.totalTokens // 0) | add // 0),
            latestDate: (map(.date) | max // "")
          }));

    def day_by_host(rows; date):
      (rows
        | sort_by(.host)
        | group_by(.host)
        | map({
            host: .[0].host,
            date: date,
            costUSD: (map(.costUSD // 0) | add // 0),
            totalTokens: (map(.totalTokens // 0) | add // 0)
          }));

    def model_ids(rows):
      [rows[] | (.models // {}) | keys[]] | unique;

    def fallback_models(rows):
      [
        rows[] |
        (.models // {}) | to_entries[] |
        select(.value.isFallback == true) |
        .key
      ] | unique;

    . as $historicalRows |
    ($todayRows + $historicalRows) as $allRows |
    ($allRows | map(select(.date >= $monthStart))) as $recentRows |
    ($official[0] // {
      capturedAt: $generatedAt,
      models: {available: false, data: []},
      accountUsage: {available: false, summary: null, dailyUsageBuckets: null}
    }) as $officialSnapshot |
    ([
      ($officialSnapshot.models.data // [])[] |
      (.id // empty), (.model // empty)
    ] | unique) as $catalogModels |
    (model_ids($recentRows)) as $observedRecentModels |
    (model_ids($recentRows | map(select(.host == "local")))) as $observedLocalRecentModels |
    {
      ledgerSchemaVersion: $ledgerSchemaVersion,
      ledgerGeneration: $ledgerGeneration,
      costBasis: "estimated_standard_api_equivalent",
      collector: {
        name: "ccusage",
        version: $collectorVersion,
        pricingSource: "embedded_offline",
        speed: $pricingSpeed
      },
      generatedAt: $generatedAt,
      timezone: $timezone,
      rows: length,
      latestRecordedDate: (map(.date) | max // ""),
      collection: {
        expectedHosts: $configuredHosts,
        historicalFailedHosts: $historicalFailedHosts,
        todayFailedHosts: $todayFailedHosts
      },
      models: {
        observedRecent: $observedRecentModels,
        observedToday: model_ids($todayRows),
        currentCatalog: $catalogModels,
        catalogAvailable: ($officialSnapshot.models.available == true),
        notInCurrentCatalog: (
          if $officialSnapshot.models.available == true
          then ($observedLocalRecentModels - $catalogModels)
          else []
          end
        ),
        fallbackAttributed: fallback_models($recentRows),
        possiblyUnpricedRows: [
          $recentRows[] |
          select((.totalTokens // 0) > 0 and (.costUSD // 0) == 0) |
          {date, host, models: ((.models // {}) | keys)}
        ]
      },
      official: ($officialSnapshot + {probeWarning: $officialProbeWarning}),
      monthToDate: {
        since: $monthStart,
        totalCostUSD: (map(select(.date >= $monthStart)) | map(.costUSD // 0) | add // 0),
        byHost: by_host(map(select(.date >= $monthStart)))
      },
      latestByHost: (
        sort_by(.host, .date)
        | group_by(.host)
        | map(last | {
            host,
            date,
            costUSD,
            totalTokens
          })
      ),
      yesterday: {
        date: $yesterdayDate,
        totalCostUSD: (map(select(.date == $yesterdayDate)) | map(.costUSD // 0) | add // 0),
        totalTokens: (map(select(.date == $yesterdayDate)) | map(.totalTokens // 0) | add // 0),
        byHost: day_by_host(map(select(.date == $yesterdayDate)); $yesterdayDate)
      },
      today: {
        date: $todayDate,
        totalCostUSD: ($todayRows | map(.costUSD // 0) | add // 0),
        totalTokens: ($todayRows | map(.totalTokens // 0) | add // 0),
        byHost: day_by_host($todayRows; $todayDate),
        unavailableHosts: ($configuredHosts - ($todayRows | map(.host) | unique))
      }
    }
  ' "$ledger_input_file" >| "$summary_output_file"

  jq -e \
    --argjson schemaVersion "$LEDGER_SCHEMA_VERSION" \
    --arg collectorVersion "$CCUSAGE_VERSION" \
    --arg speed "$CCUSAGE_SPEED" \
    --arg ledgerGeneration "$LEDGER_GENERATION" '
      (.ledgerSchemaVersion == $schemaVersion) and
      (.ledgerGeneration == $ledgerGeneration) and
      (.collector.version == $collectorVersion) and
      (.collector.speed == $speed) and
      (.collection | type == "object") and
      (.monthToDate | type == "object") and
      (.today | type == "object")
    ' "$summary_output_file" >/dev/null
}

LAST_RUN_ISO=$(timestamp)
LAST_SUCCESS_ISO=""
SUCCESS_COUNT=0
LAST_OUTPUT=""
LAST_ERROR=""
ROWS_ADDED=0
CONFIGURED_HOSTS=(local "${REMOTE_HOSTS[@]}")
COLLECTION_ERRORS=()
HISTORICAL_FAILED_HOSTS=()
TODAY_FAILED_HOSTS=()
COLLECTION_LEDGER_FILE="$LEDGER_FILE"
STAGING_LEDGER_FILE=""
STAGING_SUMMARY_FILE=""
REBUILDING_LEDGER=0
LEDGER_GENERATION=""
OFFICIAL_PROBE_WARNING=""
OFFICIAL_SNAPSHOT_INPUT="$OFFICIAL_SNAPSHOT_FILE"

if [[ -f "$STATUS_FILE" ]]; then
  while IFS=$'\t' read -r key value; do
    case "$key" in
      last_success_iso) LAST_SUCCESS_ISO="$value" ;;
    esac
  done < "$STATUS_FILE"
fi

require_command jq
require_command perl

if [[ "${REBUILD_LEDGER:-0}" == "1" ]]; then
  begin_ledger_rebuild "explicit rebuild requested"
elif ledger_requires_migration; then
  begin_ledger_rebuild "ledger schema or collector contract changed"
fi

if [[ -z "$LEDGER_GENERATION" ]]; then
  if [[ -s "$LEDGER_FILE" ]]; then
    LEDGER_GENERATION=$(jq -sr '.[0].ledgerGeneration // ""' "$LEDGER_FILE")
  fi
  [[ -n "$LEDGER_GENERATION" ]] || LEDGER_GENERATION=$(new_ledger_generation)
fi

END_DATE=$(yesterday_in_timezone)
TODAY_DATE=$(today_in_timezone)
MONTH_START=$(month_start_in_timezone)
TODAY_ROWS_FILE=$(mktemp)
TEMP_FILES+=("$TODAY_ROWS_FILE")

for host in local "${REMOTE_HOSTS[@]}"; do
  latest_date=$(latest_date_for_host "$host")
  if [[ -n "$latest_date" ]]; then
    current_date=$(next_date "$latest_date")
  else
    current_date=$(initial_start_in_timezone)
  fi

  if ! date_is_on_or_before "$current_date" "$END_DATE"; then
    continue
  fi

  echo "[$(timestamp)] collecting $host usage from $current_date through $END_DATE"

  json_file=$(mktemp)
  TEMP_FILES+=("$json_file")
  if ! fetch_daily_range_json "$host" "$current_date" "$END_DATE" >"$json_file"; then
    rm -f "$json_file"
    record_collection_failure "$host" historical "Failed to collect $host usage from $current_date through $END_DATE"
    continue
  fi

  if ! is_valid_daily_json "$json_file" "$current_date" "$END_DATE"; then
    rm -f "$json_file"
    record_collection_failure "$host" historical "Invalid usage response from $host for $current_date through $END_DATE"
    continue
  fi

  if [[ -z "$latest_date" ]]; then
    IFS=$'\t' read -r discovered_start_date discovered_end_date \
      <<< "$(usage_coverage_from_json_file "$json_file")"
    if [[ -z "$discovered_start_date" ]]; then
      rm -f "$json_file"
      if [[ "$REBUILDING_LEDGER" == "1" ]] && original_ledger_has_usage_for_host "$host"; then
        record_collection_failure "$host" historical "Empty usage response from $host would discard existing history"
        continue
      fi
      echo "[$(timestamp)] no $host usage found between $current_date and $END_DATE"
      continue
    fi

    if [[ "$REBUILDING_LEDGER" == "1" ]] && original_ledger_has_usage_for_host "$host"; then
      IFS=$'\t' read -r original_start_date original_end_date \
        <<< "$(original_host_usage_coverage "$host")"
      if [[ "$discovered_start_date" > "$original_start_date" || "$discovered_end_date" < "$original_end_date" ]]; then
        rm -f "$json_file"
        record_collection_failure "$host" historical \
          "Incomplete usage coverage from $host ($discovered_start_date through $discovered_end_date; previous history spans $original_start_date through $original_end_date)"
        continue
      fi
    fi
    current_date="$discovered_start_date"
  fi

  captured_at=$(timestamp)
  append_rows_from_json_file "$json_file" "$host" "$current_date" "$END_DATE" "$captured_at"
  rm -f "$json_file"
done

if [[ "$REBUILDING_LEDGER" == "1" ]]; then
  if (( ${#HISTORICAL_FAILED_HOSTS[@]} > 0 )); then
    LAST_ERROR="Ledger rebuild not committed because historical collection failed: ${(j:, :)HISTORICAL_FAILED_HOSTS}"
    LAST_OUTPUT="Previous ledger retained; corrected rebuild is incomplete"
    SUCCESS_COUNT=$(wc -l <"$LEDGER_FILE" | tr -d ' ')
    echo "[$(timestamp)] error: $LAST_ERROR"

    tmp_file="${STATUS_FILE}.tmp"
    {
      printf 'last_run_iso\t%s\n' "$LAST_RUN_ISO"
      printf 'last_success_iso\t%s\n' "$LAST_SUCCESS_ISO"
      printf 'success_count\t%s\n' "${SUCCESS_COUNT:-0}"
      printf 'last_output\t%s\n' "$LAST_OUTPUT"
      printf 'last_error\t%s\n' "$LAST_ERROR"
    } >| "$tmp_file"
    mv "$tmp_file" "$STATUS_FILE"
    exit 1
  fi
fi

for host in local "${REMOTE_HOSTS[@]}"; do
  echo "[$(timestamp)] collecting $host usage for today so far: $TODAY_DATE"

  json_file=$(mktemp)
  TEMP_FILES+=("$json_file")
  if ! fetch_daily_range_json "$host" "$TODAY_DATE" "$TODAY_DATE" >"$json_file"; then
    rm -f "$json_file"
    record_collection_failure "$host" today "Failed to collect $host usage for today so far: $TODAY_DATE"
    continue
  fi

  if ! is_valid_daily_json "$json_file" "$TODAY_DATE" "$TODAY_DATE"; then
    rm -f "$json_file"
    record_collection_failure "$host" today "Invalid usage response from $host for today: $TODAY_DATE"
    continue
  fi

  captured_at=$(timestamp)
  today_row=$(extract_row_for_date "$json_file" "$host" "$TODAY_DATE" "$captured_at")
  print -r -- "$today_row" >>"$TODAY_ROWS_FILE"
  rm -f "$json_file"
done

if (( ${#COLLECTION_ERRORS[@]} > 0 )); then
  LAST_ERROR="${(j:; :)COLLECTION_ERRORS}"
fi

collect_official_snapshot
if [[ "$REBUILDING_LEDGER" == "1" ]]; then
  STAGING_SUMMARY_FILE=$(mktemp "$TASK_DIR/summary.rebuild.XXXXXX")
  TEMP_FILES+=("$STAGING_SUMMARY_FILE")
  write_summary \
    "$COLLECTION_LEDGER_FILE" "$STAGING_SUMMARY_FILE" \
    "$LAST_RUN_ISO" "$MONTH_START" "$TODAY_ROWS_FILE" "$TODAY_DATE" "$END_DATE"
  commit_ledger_rebuild "$STAGING_SUMMARY_FILE"
else
  summary_tmp="${SUMMARY_FILE}.tmp"
  TEMP_FILES+=("$summary_tmp")
  write_summary \
    "$LEDGER_FILE" "$summary_tmp" \
    "$LAST_RUN_ISO" "$MONTH_START" "$TODAY_ROWS_FILE" "$TODAY_DATE" "$END_DATE"
  mv "$summary_tmp" "$SUMMARY_FILE"
fi

ledger_rows=$(wc -l <"$LEDGER_FILE" | tr -d ' ')
SUCCESS_COUNT="${ledger_rows:-0}"
latest_recorded_date=$(jq -r '.latestRecordedDate // ""' "$SUMMARY_FILE")
month_to_date_cost=$(jq -r '.monthToDate.totalCostUSD // 0' "$SUMMARY_FILE")
month_to_date_cost_fmt=$(printf "%.2f" "$month_to_date_cost")
yesterday_cost=$(jq -r '.yesterday.totalCostUSD // 0' "$SUMMARY_FILE")
yesterday_cost_fmt=$(printf "%.2f" "$yesterday_cost")
today_cost=$(jq -r '.today.totalCostUSD // 0' "$SUMMARY_FILE")
today_cost_fmt=$(printf "%.2f" "$today_cost")

if [[ -n "$LAST_ERROR" ]]; then
  LAST_OUTPUT="Partial collection; ledger has $SUCCESS_COUNT rows through ${latest_recorded_date:-unknown}; known today estimate \$${today_cost_fmt}"
else
  LAST_SUCCESS_ISO=$(timestamp)
  if [[ "$ROWS_ADDED" -gt 0 ]]; then
    LAST_OUTPUT="Added $ROWS_ADDED rows; yesterday estimate \$${yesterday_cost_fmt}; today \$${today_cost_fmt}; MTD estimate \$${month_to_date_cost_fmt} through $latest_recorded_date"
  else
    LAST_OUTPUT="Already current through $latest_recorded_date; yesterday estimate \$${yesterday_cost_fmt}; today \$${today_cost_fmt}; MTD estimate \$${month_to_date_cost_fmt}"
  fi
fi

tmp_file="${STATUS_FILE}.tmp"
{
  printf 'last_run_iso\t%s\n' "$LAST_RUN_ISO"
  printf 'last_success_iso\t%s\n' "$LAST_SUCCESS_ISO"
  printf 'success_count\t%s\n' "$SUCCESS_COUNT"
  printf 'last_output\t%s\n' "$LAST_OUTPUT"
  printf 'last_error\t%s\n' "$LAST_ERROR"
} >| "$tmp_file"
mv "$tmp_file" "$STATUS_FILE"

if [[ -n "$LAST_ERROR" ]]; then
  exit 1
fi
