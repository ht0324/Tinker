#!/bin/zsh

emulate -LR zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
APP_NAME="TinkerBar"
BUNDLE_IDENTIFIER="com.huntae.tinkerbar"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ICON_FILE="$ROOT_DIR/Sources/TinkerBar/Resources/AppIcon.icns"
INSTALL_DIR="${TINKERBAR_INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
INSTALL_REQUESTED=0
TEMP_DIRECTORIES=()

usage() {
  cat <<'EOF'
Usage: ./scripts/build-app.sh [--install]

Builds and ad-hoc signs dist/TinkerBar.app, then strictly verifies a clean
restaging of the published artifact.

  --install  Also replace ~/Applications/TinkerBar.app, relaunch it, and
             verify that the installed executable is the running copy.

Set TINKERBAR_INSTALL_DIR to use another local installation directory.
EOF
}

die() {
  print -u2 -- "error: $*"
  exit 1
}

cleanup() {
  local directory
  for directory in "${TEMP_DIRECTORIES[@]}"; do
    [[ -n "$directory" ]] && rm -rf "$directory"
  done
}

clear_signing_xattrs() {
  local bundle="$1"
  local item

  while IFS= read -r -d '' item; do
    xattr -d com.apple.FinderInfo "$item" >/dev/null 2>&1 || true
    xattr -d com.apple.ResourceFork "$item" >/dev/null 2>&1 || true
    xattr -d com.apple.quarantine "$item" >/dev/null 2>&1 || true
  done < <(find "$bundle" -depth -print0)
}

has_disallowed_signing_xattrs() {
  local bundle="$1"
  local item
  local found=0

  while IFS= read -r -d '' item; do
    if xattr -p com.apple.FinderInfo "$item" >/dev/null 2>&1; then
      print -u2 -- "Disallowed xattr com.apple.FinderInfo remains on $item"
      found=1
    fi
    if xattr -p com.apple.ResourceFork "$item" >/dev/null 2>&1; then
      print -u2 -- "Disallowed xattr com.apple.ResourceFork remains on $item"
      found=1
    fi
  done < <(find "$bundle" -depth -print0)

  (( found == 0 ))
}

validate_bundle() {
  local bundle="$1"
  local executable="$bundle/Contents/MacOS/$APP_NAME"
  local resource_bundle="$bundle/Contents/Resources/Tinker_TinkerBar.bundle"

  [[ -x "$executable" ]] || {
    print -u2 -- "Missing executable: $executable"
    return 1
  }
  [[ -d "$resource_bundle" ]] || {
    print -u2 -- "Missing SwiftPM resource bundle: $resource_bundle"
    return 1
  }
  plutil -lint "$bundle/Contents/Info.plist" >/dev/null || return 1
  has_disallowed_signing_xattrs "$bundle" || return 1
  codesign --verify --deep --strict --verbose=2 "$bundle" || return 1
}

sign_and_verify_bundle() {
  local bundle="$1"
  local attempt

  # FileProvider can attach FinderInfo once when a new .app appears under
  # Documents. Retrying keeps that race inside the packaging implementation.
  for attempt in {1..10}; do
    clear_signing_xattrs "$bundle"
    if codesign --force --sign - --timestamp=none "$bundle" && validate_bundle "$bundle"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_until_tinkerbar_stops() {
  local attempt
  for attempt in {1..100}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

quit_running_tinkerbar() {
  local -a pids

  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    return 0
  fi

  osascript -e "tell application id \"$BUNDLE_IDENTIFIER\" to quit" >/dev/null 2>&1 || true
  if wait_until_tinkerbar_stops; then
    return 0
  fi

  pids=("${(@f)$(pgrep -x "$APP_NAME" 2>/dev/null || true)}")
  if (( ${#pids} > 0 )); then
    kill "${pids[@]}" >/dev/null 2>&1 || true
  fi
  wait_until_tinkerbar_stops
}

running_installed_pids() {
  local executable="$1"

  ps -axo pid=,command= | awk -v executable="$executable" '
    {
      pid = $1
      $1 = ""
      sub(/^[[:space:]]+/, "", $0)
      if ($0 == executable || index($0, executable " ") == 1) {
        print pid
      }
    }
  '
}

wait_until_installed_app_runs() {
  local executable="$1"
  local attempt

  for attempt in {1..100}; do
    if [[ -n "$(running_installed_pids "$executable")" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

restore_previous_install() {
  local backup_app="$1"

  quit_running_tinkerbar >/dev/null 2>&1 || true
  rm -rf "$INSTALLED_APP"
  if [[ -d "$backup_app" ]]; then
    mv "$backup_app" "$INSTALLED_APP"
    open -gj "$INSTALLED_APP" >/dev/null 2>&1 || true
  fi
}

install_built_app() {
  local install_staging_directory
  local staged_app
  local backup_app="$INSTALL_DIR/.$APP_NAME.previous.$$"
  local staged_hash
  local source_hash
  local installed_hash
  local running_pids

  mkdir -p "$INSTALL_DIR"
  install_staging_directory=$(mktemp -d "$INSTALL_DIR/.$APP_NAME.install.XXXXXX")
  TEMP_DIRECTORIES+=("$install_staging_directory")
  staged_app="$install_staging_directory/$APP_NAME.app"

  ditto --norsrc --noextattr --noqtn "$APP_DIR" "$staged_app"
  sign_and_verify_bundle "$staged_app" || die "staged install failed bundle validation"
  staged_hash=$(shasum -a 256 "$staged_app/Contents/MacOS/$APP_NAME" | awk '{print $1}')
  source_hash=$(shasum -a 256 "$APP_DIR/Contents/MacOS/$APP_NAME" | awk '{print $1}')

  quit_running_tinkerbar || die "could not stop the running $APP_NAME process"

  rm -rf "$backup_app"
  if [[ -d "$INSTALLED_APP" ]]; then
    mv "$INSTALLED_APP" "$backup_app"
  fi

  if ! mv "$staged_app" "$INSTALLED_APP"; then
    restore_previous_install "$backup_app"
    die "could not activate $INSTALLED_APP"
  fi

  clear_signing_xattrs "$INSTALLED_APP"
  if ! validate_bundle "$INSTALLED_APP"; then
    restore_previous_install "$backup_app"
    die "installed bundle failed validation; restored the previous app"
  fi

  if ! installed_hash=$(shasum -a 256 "$INSTALLED_APP/Contents/MacOS/$APP_NAME" | awk '{print $1}'); then
    restore_previous_install "$backup_app"
    die "could not hash the installed executable; restored the previous app"
  fi
  if [[ "$staged_hash" != "$installed_hash" ]]; then
    restore_previous_install "$backup_app"
    die "installed executable does not match the verified staging bundle; restored the previous app"
  fi

  if ! open -gj "$INSTALLED_APP"; then
    restore_previous_install "$backup_app"
    die "could not launch the installed app; restored the previous app"
  fi
  if ! wait_until_installed_app_runs "$INSTALLED_APP/Contents/MacOS/$APP_NAME"; then
    restore_previous_install "$backup_app"
    die "the installed executable did not become the running copy; restored the previous app"
  fi

  running_pids=$(running_installed_pids "$INSTALLED_APP/Contents/MacOS/$APP_NAME")
  rm -rf "$backup_app"

  print -- "Installed $INSTALLED_APP"
  print -- "Verified staged/install executable SHA-256: $installed_hash"
  if [[ "$source_hash" != "$installed_hash" ]]; then
    print -- "Note: the restaged ad-hoc signature changed the dist executable hash ($source_hash)."
  fi
  print -- "Running PID: ${running_pids//$'\n'/, }"

  local launch_agent="$HOME/Library/LaunchAgents/com.huntae.tinkerbar.startup.plist"
  local launch_agent_target
  if [[ -f "$launch_agent" ]]; then
    launch_agent_target=$(
      /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$launch_agent" 2>/dev/null || true
    )
    if [[ "$launch_agent_target" == "$INSTALLED_APP" ]]; then
      print -- "Verified login item target: $launch_agent_target"
    else
      print -u2 -- "warning: existing login item targets ${launch_agent_target:-an unreadable path}"
    fi
  fi
}

case "${1:-}" in
  "") ;;
  --install)
    INSTALL_REQUESTED=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "unknown argument: $1"
    ;;
esac

(( $# <= 1 )) || die "expected at most one argument"

trap cleanup EXIT

cd "$ROOT_DIR"
mkdir -p "$DIST_DIR"

SWIFT_BUILD_FLAGS=(
  -c release
  -Xswiftc -strict-concurrency=complete
  -Xswiftc -warnings-as-errors
)
swift build "${SWIFT_BUILD_FLAGS[@]}"
BIN_DIR=$(swift build -c release --show-bin-path)

BUILD_STAGING_DIRECTORY=$(mktemp -d "${TMPDIR%/}/$APP_NAME.build.XXXXXX")
TEMP_DIRECTORIES+=("$BUILD_STAGING_DIRECTORY")
STAGED_APP="$BUILD_STAGING_DIRECTORY/$APP_NAME.app"

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
install -m 755 "$BIN_DIR/$APP_NAME" "$STAGED_APP/Contents/MacOS/$APP_NAME"
install -m 644 "$ICON_FILE" "$STAGED_APP/Contents/Resources/AppIcon.icns"

for resource_bundle in "$BIN_DIR"/*.bundle(N); do
  ditto --norsrc --noextattr --noqtn \
    "$resource_bundle" \
    "$STAGED_APP/Contents/Resources/${resource_bundle:t}"
done

cat > "$STAGED_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>TinkerBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.huntae.tinkerbar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TinkerBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

sign_and_verify_bundle "$STAGED_APP" || die "staged build failed bundle validation"
STAGED_HASH=$(shasum -a 256 "$STAGED_APP/Contents/MacOS/$APP_NAME" | awk '{print $1}')

DIST_PUBLISH_APP="$DIST_DIR/.$APP_NAME.publish.$$"
DIST_BACKUP_APP="$DIST_DIR/.$APP_NAME.previous.$$"
TEMP_DIRECTORIES+=("$DIST_PUBLISH_APP")
rm -rf "$DIST_PUBLISH_APP" "$DIST_BACKUP_APP"
ditto --norsrc --noextattr --noqtn "$STAGED_APP" "$DIST_PUBLISH_APP"

# Documents/FileProvider may attach FinderInfo to dist after publication.
# Prove the published code and signature through a clean, metadata-free copy.
VALIDATION_DIRECTORY=$(mktemp -d "${TMPDIR%/}/$APP_NAME.validation.XXXXXX")
TEMP_DIRECTORIES+=("$VALIDATION_DIRECTORY")
VALIDATION_APP="$VALIDATION_DIRECTORY/$APP_NAME.app"
ditto --norsrc --noextattr --noqtn "$DIST_PUBLISH_APP" "$VALIDATION_APP"
clear_signing_xattrs "$VALIDATION_APP"
validate_bundle "$VALIDATION_APP" || die "published build failed clean-restaging validation"

PUBLISHED_HASH=$(shasum -a 256 "$DIST_PUBLISH_APP/Contents/MacOS/$APP_NAME" | awk '{print $1}')
VALIDATION_HASH=$(shasum -a 256 "$VALIDATION_APP/Contents/MacOS/$APP_NAME" | awk '{print $1}')
if [[ "$STAGED_HASH" != "$PUBLISHED_HASH" || "$PUBLISHED_HASH" != "$VALIDATION_HASH" ]]; then
  die "published executable changed during staging"
fi

if [[ -d "$APP_DIR" ]]; then
  mv "$APP_DIR" "$DIST_BACKUP_APP"
fi
if ! mv "$DIST_PUBLISH_APP" "$APP_DIR"; then
  [[ -d "$DIST_BACKUP_APP" ]] && mv "$DIST_BACKUP_APP" "$APP_DIR"
  die "could not activate $APP_DIR"
fi
if ! FINAL_HASH=$(shasum -a 256 "$APP_DIR/Contents/MacOS/$APP_NAME" | awk '{print $1}'); then
  rm -rf "$APP_DIR"
  [[ -d "$DIST_BACKUP_APP" ]] && mv "$DIST_BACKUP_APP" "$APP_DIR"
  die "could not hash the final dist executable; restored the previous dist app"
fi
if [[ "$FINAL_HASH" != "$PUBLISHED_HASH" ]]; then
  rm -rf "$APP_DIR"
  [[ -d "$DIST_BACKUP_APP" ]] && mv "$DIST_BACKUP_APP" "$APP_DIR"
  die "final dist executable changed during activation; restored the previous dist app"
fi
rm -rf "$DIST_BACKUP_APP"

print -- "Built and ad-hoc signed $APP_DIR"
print -- "Verified published executable through clean restaging: $PUBLISHED_HASH"

if (( INSTALL_REQUESTED )); then
  install_built_app
fi
