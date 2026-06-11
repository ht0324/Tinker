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
FAST_MODE_INTRO_DATE="${TINKERBAR_CODEX_USAGE_FAST_MODE_INTRO_DATE:-${FAST_MODE_INTRO_DATE:-2026-03-03}}"
CCUSAGE_CODEX_BIN="${TINKERBAR_CODEX_USAGE_CODEX_BIN:-${CCUSAGE_CODEX_BIN:-ccusage-codex}}"
SSH_BIN="${TINKERBAR_CODEX_USAGE_SSH_BIN:-${SSH_BIN:-ssh}}"

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
  exit 0
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

  if [[ ! -s "$LEDGER_FILE" ]]; then
    return 0
  fi

  jq -r --arg host "$host" 'select(.host == $host) | .date' "$LEDGER_FILE" | tail -n 1
}

ccusage_display_date() {
  date -j -f "%Y-%m-%d" "$1" "+%b %d, %Y"
}

ccusage_date_to_iso() {
  date -j -f "%b %d, %Y" "$1" +%Y-%m-%d 2>/dev/null || date -j -f "%b %e, %Y" "$1" +%Y-%m-%d 2>/dev/null || true
}

first_usage_date_from_json_file() {
  local json_file="$1"
  local ccusage_date

  ccusage_date=$(jq -r '(.daily | first | .date) // ""' "$json_file")
  if [[ -z "$ccusage_date" ]]; then
    return 0
  fi

  ccusage_date_to_iso "$ccusage_date"
}

fetch_local_daily_range_json() {
  local since_date="$1"
  local until_date="$2"

  run_with_timeout "$FETCH_TIMEOUT_SECONDS" \
    "$CCUSAGE_CODEX_BIN" daily --json --timezone "$TIMEZONE" --since "$since_date" --until "$until_date"
}

fetch_remote_daily_range_json() {
  local host="$1"
  local since_date="$2"
  local until_date="$3"

  run_with_timeout "$FETCH_TIMEOUT_SECONDS" "$SSH_BIN" "${SSH_OPTIONS[@]}" "$host" /bin/zsh <<EOF
emulate -LR zsh
set -euo pipefail
export PATH="\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
ccusage-codex daily --json --timezone '$TIMEZONE' --since '$since_date' --until '$until_date'
EOF
}

extract_row_for_date() {
  local json_file="$1"
  local host="$2"
  local report_date="$3"
  local captured_at="$4"
  local ccusage_date

  ccusage_date=$(ccusage_display_date "$report_date")

  jq -c \
    --arg host "$host" \
    --arg date "$report_date" \
    --arg ccusageDate "$ccusage_date" \
    --arg timezone "$TIMEZONE" \
    --arg capturedAt "$captured_at" '
    (
      first(.daily[]? | select(.date == $ccusageDate)) // {
        date: $date,
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0,
        costUSD: 0,
        models: {}
      }
    ) + {
      date: $date,
      host: $host,
      timezone: $timezone,
      capturedAt: $capturedAt
    }
  ' "$json_file"
}

apply_codex_fast_mode_adjustment() {
  local row_json="$1"

  jq -c --arg fastIntro "$FAST_MODE_INTRO_DATE" '
    def fast_rule($model):
      if $model == "gpt-5.5" then
        { since: "2026-04-23", multiplier: 2.5, input: 5, cached: 0.5, output: 30 }
      elif $model == "gpt-5.4" then
        { since: "2026-03-05", multiplier: 2, input: 2.5, cached: 0.25, output: 15 }
      elif $model == "gpt-5.3-codex" then
        { since: $fastIntro, multiplier: 2, input: 1.75, cached: 0.175, output: 14 }
      else
        empty
      end;

    def standard_cost($rule; $usage):
      ($usage.inputTokens // 0) as $input |
      ([($usage.cachedInputTokens // 0), $input] | min) as $cached |
      (($input - $cached) | if . > 0 then . else 0 end) as $nonCached |
      ($usage.outputTokens // 0) as $output |
      (($nonCached * $rule.input) + ($cached * $rule.cached) + ($output * $rule.output)) / 1000000;

    (.date // "") as $rowDate |
    ((.models // {}) | to_entries | map(
      . as $entry |
      fast_rule($entry.key) as $rule |
      select($rowDate >= $rule.since) |
        {
          model: $entry.key,
          since: $rule.since,
          standardCostUSD: standard_cost($rule; $entry.value),
          multiplier: $rule.multiplier
        }
    )) as $fastModels |
    ($fastModels | map(.standardCostUSD) | add // 0) as $fastStandardCost |
    ($fastModels | map(.standardCostUSD * .multiplier) | add // 0) as $fastAdjustedCost |
    if $fastStandardCost > 0 then
      . + {
        standardCostUSD: (.standardCostUSD // .costUSD // 0),
        costUSD: ((.costUSD // 0) - $fastStandardCost + $fastAdjustedCost),
        pricingAdjustment: {
          kind: "codex_fast_mode",
          assumption: "fast_mode_enabled_since_intro",
          introDate: $fastIntro,
          standardCostUSD: (.standardCostUSD // .costUSD // 0),
          fastStandardCostUSD: $fastStandardCost,
          fastAdjustedCostUSD: $fastAdjustedCost,
          addedCostUSD: ($fastAdjustedCost - $fastStandardCost),
          models: $fastModels
        }
      }
    else
      .
    end
  ' <<< "$row_json"
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
    row=$(apply_codex_fast_mode_adjustment "$row")
    printf '%s\n' "$row" >>"$LEDGER_FILE"
    ROWS_ADDED=$((ROWS_ADDED + 1))
    current_date=$(next_date "$current_date")
  done
}

write_summary() {
  local generated_at="$1"
  local month_start="$2"
  local today_rows_file="$3"
  local today_date="$4"
  local yesterday_date="$5"

  jq -s --slurpfile todayRows "$today_rows_file" --arg generatedAt "$generated_at" --arg timezone "$TIMEZONE" --arg monthStart "$month_start" --arg todayDate "$today_date" --arg yesterdayDate "$yesterday_date" '
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

    {
      generatedAt: $generatedAt,
      timezone: $timezone,
      rows: length,
      latestRecordedDate: (map(.date) | max // ""),
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
        byHost: day_by_host($todayRows; $todayDate)
      }
    }
  ' "$LEDGER_FILE" >"$SUMMARY_FILE"
}

LAST_RUN_ISO=$(timestamp)
LAST_SUCCESS_ISO=""
SUCCESS_COUNT=0
LAST_OUTPUT=""
LAST_ERROR=""
ROWS_ADDED=0

if [[ -f "$STATUS_FILE" ]]; then
  while IFS=$'\t' read -r key value; do
    case "$key" in
      last_success_iso) LAST_SUCCESS_ISO="$value" ;;
      success_count) SUCCESS_COUNT="${value:-0}" ;;
      last_output) LAST_OUTPUT="$value" ;;
    esac
  done < "$STATUS_FILE"
fi

if [[ "${REBUILD_LEDGER:-0}" == "1" ]]; then
  rebuild_stamp=$(date -u +"%Y%m%dT%H%M%SZ")
  if [[ -s "$LEDGER_FILE" ]]; then
    cp "$LEDGER_FILE" "$LEDGER_FILE.rebuild-$rebuild_stamp.bak"
  fi
  if [[ -s "$SUMMARY_FILE" ]]; then
    cp "$SUMMARY_FILE" "$SUMMARY_FILE.rebuild-$rebuild_stamp.bak"
  fi
  : > "$LEDGER_FILE"
  rm -f "$SUMMARY_FILE"
  echo "[$(timestamp)] rebuilding full Codex usage ledger from $DISCOVERY_FLOOR_DATE"
fi

require_command jq
require_command "$CCUSAGE_CODEX_BIN"
if (( ${#REMOTE_HOSTS[@]} > 0 )); then
  require_command "$SSH_BIN"
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
  if [[ "$host" == "local" ]]; then
    if ! fetch_local_daily_range_json "$current_date" "$END_DATE" >"$json_file"; then
      rm -f "$json_file"
      LAST_ERROR="Failed to collect local usage from $current_date through $END_DATE"
      echo "[$(timestamp)] error: $LAST_ERROR"
      break
    fi
  else
    if ! fetch_remote_daily_range_json "$host" "$current_date" "$END_DATE" >"$json_file"; then
      rm -f "$json_file"
      LAST_ERROR="Failed to collect $host usage from $current_date through $END_DATE"
      echo "[$(timestamp)] error: $LAST_ERROR"
      break
    fi
  fi

  if [[ -z "$latest_date" ]]; then
    discovered_start_date=$(first_usage_date_from_json_file "$json_file")
    if [[ -z "$discovered_start_date" ]]; then
      rm -f "$json_file"
      echo "[$(timestamp)] no $host usage found between $current_date and $END_DATE"
      continue
    fi
    current_date="$discovered_start_date"
  fi

  captured_at=$(timestamp)
  append_rows_from_json_file "$json_file" "$host" "$current_date" "$END_DATE" "$captured_at"
  rm -f "$json_file"
done

if [[ -z "$LAST_ERROR" ]]; then
  for host in local "${REMOTE_HOSTS[@]}"; do
    echo "[$(timestamp)] collecting $host usage for today so far: $TODAY_DATE"

    json_file=$(mktemp)
    TEMP_FILES+=("$json_file")
    if [[ "$host" == "local" ]]; then
      if ! fetch_local_daily_range_json "$TODAY_DATE" "$TODAY_DATE" >"$json_file"; then
        LAST_ERROR="Failed to collect local usage for today so far: $TODAY_DATE"
        echo "[$(timestamp)] error: $LAST_ERROR"
        break
      fi
    else
      if ! fetch_remote_daily_range_json "$host" "$TODAY_DATE" "$TODAY_DATE" >"$json_file"; then
        LAST_ERROR="Failed to collect $host usage for today so far: $TODAY_DATE"
        echo "[$(timestamp)] error: $LAST_ERROR"
        break
      fi
    fi

    captured_at=$(timestamp)
    today_row=$(extract_row_for_date "$json_file" "$host" "$TODAY_DATE" "$captured_at")
    apply_codex_fast_mode_adjustment "$today_row" >>"$TODAY_ROWS_FILE"
    rm -f "$json_file"
  done
fi

write_summary "$LAST_RUN_ISO" "$MONTH_START" "$TODAY_ROWS_FILE" "$TODAY_DATE" "$END_DATE"

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
  LAST_OUTPUT="Ledger currently has $SUCCESS_COUNT rows through ${latest_recorded_date:-unknown}"
else
  LAST_SUCCESS_ISO=$(timestamp)
  if [[ "$ROWS_ADDED" -gt 0 ]]; then
    LAST_OUTPUT="Added $ROWS_ADDED rows; yesterday \$${yesterday_cost_fmt}; today \$${today_cost_fmt}; MTD total \$${month_to_date_cost_fmt} through $latest_recorded_date"
  else
    LAST_OUTPUT="Already current through $latest_recorded_date; yesterday \$${yesterday_cost_fmt}; today \$${today_cost_fmt}; MTD total \$${month_to_date_cost_fmt}"
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
