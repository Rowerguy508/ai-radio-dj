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
# On iOS 27 sims (esp. right after first boot / data migration), App.init notice
# lines can miss `log show --start`. Stream during launch and poll --last as fallback.
runtime_mode() {
  local app="$1"; shift
  local stream spid mode i
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$app"
  stream=$(mktemp)
  xcrun simctl spawn "$UDID" log stream --level default --style compact \
    --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"runtime\"" \
    >"$stream" 2>/dev/null &
  spid=$!
  # Let log stream attach before App.init runs.
  sleep 2
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@" >/dev/null
  mode=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    mode=$(grep -o 'runtime mode: [a-zA-Z]*' "$stream" 2>/dev/null | tail -1 || true)
    if [ -n "$mode" ]; then
      break
    fi
    mode=$(xcrun simctl spawn "$UDID" log show --style compact --last 60s \
      --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"runtime\"" 2>/dev/null \
      | grep -o 'runtime mode: [a-zA-Z]*' | tail -1 || true)
    if [ -n "$mode" ]; then
      break
    fi
    mode=$(xcrun simctl spawn "$UDID" log show --style compact --last 60s \
      --predicate 'process == "AeroDJ"' 2>/dev/null \
      | grep -o 'runtime mode: [a-zA-Z]*' | tail -1 || true)
    if [ -n "$mode" ]; then
      break
    fi
  done
  kill "$spid" >/dev/null 2>&1 || true
  wait "$spid" 2>/dev/null || true
  rm -f "$stream"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  printf '%s' "$mode"
}

expect() {
  local label="$1" want="$2" got="$3"
  echo "$label: got '${got:-<no runtime log line>}', want '$want'"
  if [ "$got" != "$want" ]; then
    echo "FAILED: $label"
    echo "--- app-process log lines from the last 5 minutes (diagnostic):"
    xcrun simctl spawn "$UDID" log show --style compact --last 5m \
      --predicate 'process == "AeroDJ"' | tail -40 || true
    exit 1
  fi
}

expect "Debug, no argument" "runtime mode: live" "$(runtime_mode "$DEBUG_APP")"
expect "Debug, -AeroDJTestStation YES" "runtime mode: testStation" \
  "$(runtime_mode "$DEBUG_APP" -AeroDJTestStation YES)"
expect "Release, -AeroDJTestStation YES" "runtime mode: live" \
  "$(runtime_mode "$RELEASE_APP" -AeroDJTestStation YES)"
echo "PASS: the argument switches dependencies in Debug and is ignored in Release."
