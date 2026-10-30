#!/usr/bin/env bash
# Give a screenshot capture a clean simulator: shut it down, erase it (apps, app containers,
# the group.com.aerodj container, saved state, defaults) and boot it again. Run before each
# compared iPhone capture so no state carries over from an earlier capture or run, e.g. the
# 'violet' search text typed by the head's UI tests showing up in the baseline's
# closed-state-empty and closed-queue-sheet (#289, iOS 41000805007). Erasing also clears the
# status-bar override and keyboard settings, so callers apply those again after this. -Atlas
#   reset-simulator-app-state.sh UDID
set -euo pipefail
udid="${1:?usage: reset-simulator-app-state.sh UDID}"
xcrun simctl shutdown "$udid" 2>/dev/null || true
xcrun simctl erase "$udid"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
if xcrun simctl get_app_container "$udid" com.aerodj.app >/dev/null 2>&1; then
  echo "::error::com.aerodj.app is still installed on $udid after erase"
  exit 1
fi
echo "Simulator $udid erased and booted; com.aerodj.app not installed"
