#!/bin/zsh
emulate -LR zsh
set -euo pipefail
setopt pipefail

MONITORED_DIR="${1:-$HOME/Downloads}"
STATUS_FILE="${2:-$HOME/Library/Application Support/TinkerBar/tasks/heic-to-jpeg/status.tsv}"
LOG_FILE="${3:-$HOME/Library/Application Support/TinkerBar/tasks/heic-to-jpeg/task.log}"
LOCK_DIR="${STATUS_FILE}.lock"

mkdir -p "${STATUS_FILE:h}" "${LOG_FILE:h}"
exec >>"$LOG_FILE" 2>&1

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

trash_file() {
  local file="$1"
  local trash_dir="$HOME/.Trash"
  local base_name candidate stem ext suffix

  mkdir -p "$trash_dir"
  base_name="${file:t}"
  candidate="$trash_dir/$base_name"

  if [[ -e "$candidate" ]]; then
    stem="${base_name:r}"
    ext="${base_name:e}"
    suffix=$(date +%s)
    if [[ -n "$ext" && "$ext" != "$base_name" ]]; then
      candidate="$trash_dir/${stem}-${suffix}.${ext}"
    else
      candidate="$trash_dir/${base_name}-${suffix}"
    fi
  fi

  mv "$file" "$candidate"
}

is_stable_file() {
  local file="$1"
  local size1 size2
  size1=$(stat -f %z "$file" 2>/dev/null || echo -1)
  sleep 1
  size2=$(stat -f %z "$file" 2>/dev/null || echo -2)
  [[ "$size1" -gt 0 && "$size1" == "$size2" ]]
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

echo "[$LAST_RUN_ISO] trigger received for $MONITORED_DIR"

while IFS= read -r -d '' file; do
  output="${file%.*}.jpg"

  if [[ -e "$output" ]]; then
    continue
  fi

  if ! is_stable_file "$file"; then
    echo "[$(timestamp)] skip unstable file $file"
    continue
  fi

  if /usr/bin/sips -s format jpeg "$file" --out "$output" >/dev/null 2>&1; then
    if trash_file "$file"; then
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      LAST_SUCCESS_ISO=$(timestamp)
      LAST_OUTPUT="$output"
      echo "[$LAST_SUCCESS_ISO] converted $file -> $output and moved original to Trash"
    else
      LAST_ERROR="Converted but could not move original to Trash: $file"
      echo "[$(timestamp)] error: $LAST_ERROR"
    fi
  else
    LAST_ERROR="Failed to convert $file"
    echo "[$(timestamp)] error: $LAST_ERROR"
  fi
done < <(/usr/bin/find "$MONITORED_DIR" -maxdepth 1 -type f \( -iname '*.heic' -o -iname '*.heif' \) -print0)

tmp_file="${STATUS_FILE}.tmp"
{
  printf 'last_run_iso\t%s\n' "$LAST_RUN_ISO"
  printf 'last_success_iso\t%s\n' "$LAST_SUCCESS_ISO"
  printf 'success_count\t%s\n' "$SUCCESS_COUNT"
  printf 'last_output\t%s\n' "$LAST_OUTPUT"
  printf 'last_error\t%s\n' "$LAST_ERROR"
} >| "$tmp_file"
mv "$tmp_file" "$STATUS_FILE"
