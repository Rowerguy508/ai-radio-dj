#!/usr/bin/env bash
# Proves that the launch argument changes the running dependency set in Debug,
# and that Release ignores it. Reads the app's own runtime log line, so the
# result comes from the running app, not from the build settings.
#
# Usage: verify-runtime-mode.sh <Debug AeroDJ.app> <Release AeroDJ.app> <simulator UDID>
set -euo pipefail

DEBUG_APP="$1"
RELEASE_APP="$2"
UDID="$3"
BUNDLE_ID="com.aerodj.app"

# Install and launch an app, then return the runtime mode it logged during this launch.
runtime_mode() {
  local app="$1"; shift
  local since
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$app"
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@" >/dev/null
  sleep 6
  xcrun simctl spawn "$UDID" log show --style compact --start "$since" \
    --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"runtime\"" \
    | grep -o 'runtime mode: [a-zA-Z]*' | tail -1 || true
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

expect() {
  local label="$1" want="$2" got="$3"
  echo "$label: got '${got:-<no runtime log line>}', want '$want'"
  [ "$got" = "$want" ] || { echo "FAILED: $label"; exit 1; }
}

expect "Debug, no argument" "runtime mode: live" "$(runtime_mode "$DEBUG_APP")"
expect "Debug, -AeroDJTestStation YES" "runtime mode: testStation" \
  "$(runtime_mode "$DEBUG_APP" -AeroDJTestStation YES)"
expect "Release, -AeroDJTestStation YES" "runtime mode: live" \
  "$(runtime_mode "$RELEASE_APP" -AeroDJTestStation YES)"
echo "PASS: the argument switches dependencies in Debug and is ignored in Release."
