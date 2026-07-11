#!/bin/zsh
emulate -LR zsh
set -euo pipefail
setopt pipefail

STATUS_FILE="${1:-$HOME/Library/Application Support/TinkerBar/tasks/codex-update/status.tsv}"
LOG_FILE="${2:-$HOME/Library/Application Support/TinkerBar/tasks/codex-update/task.log}"
LOCK_DIR="${STATUS_FILE}.lock"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

mkdir -p "${STATUS_FILE:h}" "${LOG_FILE:h}"
exec >>"$LOG_FILE" 2>&1

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] error: another run owns $LOCK_DIR"
  exit 75
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
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

NPM_BIN=$(command -v npm || true)
if [[ -z "$NPM_BIN" ]]; then
  LAST_ERROR="npm not found in PATH"
  echo "[$(timestamp)] error: $LAST_ERROR"
else
  echo "[$LAST_RUN_ISO] running $NPM_BIN install -g @openai/codex@latest"

  if output=$("$NPM_BIN" install -g @openai/codex@latest 2>&1); then
    print -r -- "$output"
    LAST_SUCCESS_ISO=$(timestamp)
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

    version=$("$NPM_BIN" list -g @openai/codex --depth=0 2>/dev/null | /usr/bin/tail -n 1 | /usr/bin/sed -n 's/.*\(@openai\/codex@[0-9][^ ]*\).*/\1/p' || true)
    if [[ -n "$version" ]]; then
      LAST_OUTPUT="$version"
    else
      LAST_OUTPUT="@openai/codex updated"
    fi

    echo "[$LAST_SUCCESS_ISO] codex update complete: $LAST_OUTPUT"
  else
    print -r -- "$output"
    LAST_ERROR="npm install -g @openai/codex@latest failed"
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
