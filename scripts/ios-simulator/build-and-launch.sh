#!/usr/bin/env bash
# Locate, build, install and launch an iOS application on the booted simulator.
# If the repository has no iOS app, a small built-in demo app is compiled with
# swiftc so the session still has something real to show and interact with.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

require_cmd xcodebuild
require_cmd xcrun
export DEVELOPER_DIR="${XCODE_PATH:-$(xcode-select -p)}"
[[ -n "${UDID:-}" ]] || fail_step "UDID missing; simulator boot did not complete."

REPO_ROOT="${GITHUB_WORKSPACE:-$PWD}"
BUILD_DIR="$REPO_ROOT/build"
mkdir -p "$BUILD_DIR" "$ARTIFACTS_DIR"

find_first() {
  local pattern="$1"
  find "$REPO_ROOT" -maxdepth 4 -name "$pattern" -not -path "*/build/*" -not -path "*/node_modules/*" \
    -not -path "*/.git/*" -print -quit 2>/dev/null || true
}

WORKSPACE="$(find_first '*.xcworkspace')"
PROJECT="$(find_first '*.xcodeproj')"
PACKAGE_SWIFT="$(find_first 'Package.swift')"

# An .xcworkspace inside an .xcodeproj's parent is normal; prefer workspaces
# only when they actually exist at the top of a project directory.
if [[ -n "$WORKSPACE" && "$WORKSPACE" == *"/project.xcworkspace" ]]; then
  WORKSPACE=""
fi

BUNDLE_ID=""
APP_NAME=""
BUILD_STATUS="not started"
LAUNCH_STATUS="not started"
TEST_STATUS="not available"

build_demo_app() {
  log "No iOS application found in the repository; building the built-in demo app with swiftc (no Xcode project required)."
  local sdk arch app_dir
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  arch="$(uname -m)"
  case "$arch" in
    arm64) target_arch="arm64" ;;
    *) target_arch="x86_64" ;;
  esac
  app_dir="$BUILD_DIR/SimulatorDemo.app"
  rm -rf "$app_dir"
  mkdir -p "$app_dir"

  xcrun --sdk iphonesimulator swiftc \
    -parse-as-library \
    -O \
    -sdk "$sdk" \
    -target "${target_arch}-apple-ios16.0-simulator" \
    "$SCRIPT_DIR/demo-app/SimulatorDemo.swift" \
    -o "$app_dir/SimulatorDemo" 2>&1 | tee "$ARTIFACTS_DIR/demo-build.log"

  cp "$SCRIPT_DIR/demo-app/Info.plist" "$app_dir/Info.plist"
  chmod +x "$app_dir/SimulatorDemo"
  plutil -lint "$app_dir/Info.plist" >/dev/null

  APP_PATH="$app_dir"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Info.plist")"
  APP_NAME="Simulator Demo (built-in)"
  BUILD_STATUS="success (built-in demo app)"
  state_set APP_SOURCE "built-in demo app — the repository contains no iOS application source"
}

if [[ -n "$WORKSPACE" || -n "$PROJECT" ]]; then
  CONTAINER_FLAG="-project"
  CONTAINER_PATH="$PROJECT"
  if [[ -n "$WORKSPACE" ]]; then
    CONTAINER_FLAG="-workspace"
    CONTAINER_PATH="$WORKSPACE"
  fi
  state_set APP_SOURCE "repository app ($CONTAINER_PATH)"
  log "Using $CONTAINER_FLAG $CONTAINER_PATH"

  # Resolve Swift package dependencies before building.
  if [[ -n "$PACKAGE_SWIFT" ]]; then
    log "Resolving Swift package dependencies"
    xcodebuild -resolvePackageDependencies "$CONTAINER_FLAG" "$CONTAINER_PATH" 2>&1 | tail -n 20 || warn "Package resolution reported problems."
  fi

  LIST_JSON="$(xcodebuild -list -json "$CONTAINER_FLAG" "$CONTAINER_PATH" 2>/dev/null || true)"
  printf '%s\n' "$LIST_JSON" > "$ARTIFACTS_DIR/xcodebuild-list.json"

  SCHEME="$(printf '%s\n' "$LIST_JSON" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
info = data.get("workspace") or data.get("project") or {}
schemes = info.get("schemes") or []
if not schemes:
    sys.exit(1)
preferred = [s for s in schemes if not s.lower().endswith("tests") and "test" not in s.lower()]
print((preferred or schemes)[0])
' || true)"

  if [[ -z "${SCHEME:-}" ]]; then
    state_set BUILD_STATUS "failed: no scheme"
    fail_step "No Xcode scheme could be resolved for $CONTAINER_PATH. xcodebuild -list output is in artifacts/xcodebuild-list.json."
  fi
  state_set SCHEME "$SCHEME"
  log "Scheme: $SCHEME"

  set +e
  xcodebuild \
    "$CONTAINER_FLAG" "$CONTAINER_PATH" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -allowProvisioningUpdates \
    build > "$ARTIFACTS_DIR/xcodebuild-build.log" 2>&1
  BUILD_RC=$?
  set -e

  if (( BUILD_RC != 0 )); then
    tail -n 60 "$ARTIFACTS_DIR/xcodebuild-build.log" >&2 || true
    state_set BUILD_STATUS "failed"
    fail_step "xcodebuild build failed (exit $BUILD_RC). Full log: artifacts/xcodebuild-build.log."
  fi
  BUILD_STATUS="success"
  state_set BUILD_STATUS "success"

  APP_PATH="$(find "$BUILD_DIR/DerivedData/Build/Products" -maxdepth 2 -name '*.app' -type d 2>/dev/null | head -n 1)"
  [[ -n "${APP_PATH:-}" ]] || fail_step "Build succeeded but no .app bundle was produced."

  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || true)"
  APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP_PATH/Info.plist" 2>/dev/null || echo "$SCHEME")"
  [[ -n "$BUNDLE_ID" ]] || fail_step "Could not read CFBundleIdentifier from $APP_PATH."

  # Optional tests: only if the scheme has a test action.
  if [[ "${INPUT_RUN_TESTS:-false}" == "true" ]]; then
    log "Running tests for scheme $SCHEME"
    set +e
    timeout 900 xcodebuild \
      "$CONTAINER_FLAG" "$CONTAINER_PATH" \
      -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,id=$UDID" \
      -derivedDataPath "$BUILD_DIR/DerivedData" \
      test > "$ARTIFACTS_DIR/xcodebuild-test.log" 2>&1
    TEST_RC=$?
    set -e
    if (( TEST_RC == 0 )); then
      TEST_STATUS="passed"
    elif (( TEST_RC == 124 )); then
      TEST_STATUS="timed out after 15 min"
    else
      TEST_STATUS="failed (exit $TEST_RC, see artifacts/xcodebuild-test.log)"
    fi
    log "Test status: $TEST_STATUS"
  fi
else
  build_demo_app
fi

state_set APP_PATH "$APP_PATH"
state_set BUNDLE_ID "$BUNDLE_ID"
state_set APP_NAME "$APP_NAME"
state_set BUILD_STATUS "$BUILD_STATUS"
state_set TEST_STATUS "$TEST_STATUS"

# --------------------------------------------------------- install/launch ---
log "Installing $APP_PATH"
xcrun simctl install "$UDID" "$APP_PATH" 2>&1 | sed 's/^/  /' || fail_step "simctl install failed for $APP_PATH."

log "Launching $BUNDLE_ID"
LAUNCH_OUT="$(xcrun simctl launch "$UDID" "$BUNDLE_ID" 2>&1 || true)"
printf '%s\n' "$LAUNCH_OUT" > "$ARTIFACTS_DIR/launch.log"
log "simctl launch output: $LAUNCH_OUT"

if [[ "$LAUNCH_OUT" =~ :\ ([0-9]+)$ ]]; then
  LAUNCH_PID="${BASH_REMATCH[1]}"
  state_set APP_PID "$LAUNCH_PID"
  LAUNCH_STATUS="launched (pid $LAUNCH_PID)"
  log "Application running with pid $LAUNCH_PID"
else
  LAUNCH_STATUS="failed"
  state_set LAUNCH_STATUS "failed"
  fail_step "Application did not launch: $LAUNCH_OUT"
fi

sleep 4
if xcrun simctl io "$UDID" screenshot "$ARTIFACTS_DIR/app-screen.png" >/dev/null 2>&1; then
  log "Captured post-launch screenshot: artifacts/app-screen.png"
fi
# Confirm the process is still alive a few seconds after launch.
if ! xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; then
  warn "Application is not listed in launchctl after launch; it may have crashed."
  LAUNCH_STATUS="$LAUNCH_STATUS (not present in launchctl afterwards)"
fi

state_set LAUNCH_STATUS "$LAUNCH_STATUS"

summary_md ""
summary_md "## Application"
summary_md ""
summary_md "| Item | Value |"
summary_md "| --- | --- |"
summary_row "Source" "$(state_get APP_SOURCE "unknown")"
summary_row "Scheme" "$(state_get SCHEME "—")"
summary_row "Bundle identifier" "$BUNDLE_ID"
summary_row "Build" "$BUILD_STATUS"
summary_row "Launch" "$LAUNCH_STATUS"
summary_row "Tests" "$TEST_STATUS"
summary_md ""
