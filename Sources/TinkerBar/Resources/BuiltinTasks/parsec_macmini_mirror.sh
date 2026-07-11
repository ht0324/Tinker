#!/bin/zsh
emulate -LR zsh
set -euo pipefail
setopt pipefail

EVENT="${1:-sync}"
STATUS_FILE="${2:-$HOME/Library/Application Support/TinkerBar/tasks/parsec-macmini-mirror/status.tsv}"
LOG_FILE="${3:-$HOME/Library/Application Support/TinkerBar/tasks/parsec-macmini-mirror/task.log}"
LOCK_DIR="${STATUS_FILE}.lock"
TASK_DIR="${STATUS_FILE:h}"
CONFIG_FILE="${TINKERBAR_PARSEC_CONFIG_FILE:-$TASK_DIR/config.env}"

REMOTE_HOST="${TINKERBAR_PARSEC_REMOTE_HOST:-macmini}"
LOCAL_APP_NAME="${TINKERBAR_PARSEC_LOCAL_APP_NAME:-Parsec}"
SSH_BIN="${TINKERBAR_PARSEC_SSH_BIN:-ssh}"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1)
REMOTE_OPEN_COMMAND="${TINKERBAR_PARSEC_OPEN_COMMAND:-/usr/bin/open -gja Parsec}"
REMOTE_CLOSE_COMMAND="${TINKERBAR_PARSEC_CLOSE_COMMAND:-/usr/bin/osascript -e 'quit app \"Parsec\"' >/dev/null 2>&1 || /usr/bin/pkill -x Parsec >/dev/null 2>&1 || true}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

mkdir -p "$TASK_DIR" "${LOG_FILE:h}"

if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

if [[ -n "${TINKERBAR_PARSEC_SSH_OPTIONS:-}" ]]; then
  ssh_options_value="$TINKERBAR_PARSEC_SSH_OPTIONS"
  SSH_OPTIONS=(${=ssh_options_value})
fi

exec >>"$LOG_FILE" 2>&1

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] error: another run owns $LOCK_DIR"
  exit 75
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

is_local_parsec_running() {
  [[ "$(/usr/bin/osascript -e "application \"$LOCAL_APP_NAME\" is running" 2>/dev/null || true)" == "true" ]]
}

LAST_RUN_ISO=$(timestamp)
LAST_SUCCESS_ISO=""
SUCCESS_COUNT=0
LAST_OUTPUT=""
LAST_ERROR=""

if [[ -f "$STATUS_FILE" ]]; then
  while IFS=$'\t' read -r key value; do
    case "$key" in
      last_success_iso) LAST_SUCCESS_ISO="$value" ;;
      success_count) SUCCESS_COUNT="${value:-0}" ;;
      last_output) LAST_OUTPUT="$value" ;;
    esac
  done < "$STATUS_FILE"
fi

case "$EVENT" in
  opened)
    action="open"
    remote_command="$REMOTE_OPEN_COMMAND"
    ;;
  closed)
    action="close"
    remote_command="$REMOTE_CLOSE_COMMAND"
    ;;
  sync)
    if is_local_parsec_running; then
      action="open"
      EVENT="opened"
      remote_command="$REMOTE_OPEN_COMMAND"
    else
      action="close"
      EVENT="closed"
      remote_command="$REMOTE_CLOSE_COMMAND"
    fi
    ;;
  *)
    LAST_ERROR="unknown Parsec event: $EVENT"
    echo "[$LAST_RUN_ISO] error: $LAST_ERROR"
    action=""
    remote_command=""
    ;;
esac

if [[ -n "$remote_command" ]]; then
  echo "[$LAST_RUN_ISO] Parsec event '$EVENT'; running remote $action on $REMOTE_HOST"

  if output=$("$SSH_BIN" "${SSH_OPTIONS[@]}" "$REMOTE_HOST" "$remote_command" 2>&1); then
    [[ -n "$output" ]] && print -r -- "$output"
    LAST_SUCCESS_ISO=$(timestamp)
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    LAST_OUTPUT="$action Parsec on $REMOTE_HOST"
    echo "[$LAST_SUCCESS_ISO] $LAST_OUTPUT"
  else
    print -r -- "$output"
    LAST_ERROR="failed to $action Parsec on $REMOTE_HOST"
    echo "[$(timestamp)] error: $LAST_ERROR"
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
