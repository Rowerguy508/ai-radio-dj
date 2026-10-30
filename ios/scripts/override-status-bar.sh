#!/usr/bin/env bash
# Pin a booted simulator's status bar so screenshots don't change from run to run
# (clock, battery, signal). compare-iphone-screenshots.py also masks the status-bar
# strip on iPhone shots, as a second guard.
#   override-status-bar.sh UDID
set -euo pipefail
udid="${1:?usage: override-status-bar.sh UDID}"
xcrun simctl status_bar "$udid" override \
  --time "9:41" \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --operatorName "" \
  --batteryState charged --batteryLevel 100
