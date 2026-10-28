#!/usr/bin/env bash
# Release needle: fails if a Release build of AeroDJCore can enable paid (ElevenLabs) voices.
# 1. Runs the core tests in Release, where PremiumVoicePickerTests.testReleaseNeverEnablesPaidProviders
#    asserts OwnerVoiceTrial is off even with the owner default set.
# 2. Positive control: the DEBUG-only defaults key must be in Debug objects and absent from Release.
set -euo pipefail
cd "$(dirname "$0")/../AeroDJCore"
pattern='AeroDJPaidProvidersEnabled'
objects() { find .build -name '*.o' -ipath "*/$1*" -path '*AeroDJCore*' ! -path '*Tests*'; }

swift build -c debug
objects debug | xargs grep -laE "$pattern" >/dev/null || { echo "FAIL: control: pattern not found in Debug objects"; exit 1; }

swift build -c release
if objects release | xargs grep -laE "$pattern"; then
  echo "FAIL: paid-voice owner gate found in Release build"; exit 1
fi
swift test -c release -Xswiftc -enable-testing --filter PremiumVoicePickerTests
echo "OK: Release build cannot enable paid voices"
