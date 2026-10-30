#!/usr/bin/env bash
# Turn off keyboard autocorrection, spell checking and predictions on a booted simulator, so
# typed text in UI-test screenshots (e.g. "violet" in iphone-landscape) never shows a
# transient autocorrect or spelling underline. Simulator-only; the app is not changed.
# CaptureMotionFreeze (-AERODJ_UITEST_DISABLE_ANIMATIONS) hides the caret. -Atlas
#   settle-simulator-keyboard.sh UDID
set -euo pipefail
udid="${1:?usage: settle-simulator-keyboard.sh UDID}"
for key in KeyboardAutocorrection KeyboardCheckSpelling KeyboardPrediction KeyboardShowPredictionBar; do
  xcrun simctl spawn "$udid" defaults write com.apple.Preferences "$key" -bool NO
done
