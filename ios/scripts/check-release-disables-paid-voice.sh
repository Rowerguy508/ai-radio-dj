#!/usr/bin/env bash
# Paid-voice needle: the owner A/B gate (ElevenLabs picker) exists only with AERODJ_OWNER_AB.
# 1. Release without the flag: no gate marker in AeroDJCore objects, and the Release-config
#    test asserts OwnerVoiceTrial.paidProvidersEnabled == false.
# 2. Positive control, Release with -DAERODJ_OWNER_AB (separate scratch dir): marker present
#    and the flagged test asserts the gate is on, so step 1 cannot pass vacuously.
# The owner trial access (`ownerTrial`, Pro gate bypass, Sentinel B1 on #244) gets the same
# treatment: absent from Release objects without the flag, present with it.
set -euo pipefail
cd "$(dirname "$0")/../AeroDJCore"
marker='AERODJ_OWNER_AB_VOICE_TRIAL_BUILD'
owner_trial='ownerTrial'
flagged=.build/owner-ab  # inside the ignored .build/, excluded from the plain scan
# -ipath: SwiftPM's layout varies (.build/release vs .build/out/Products/Release-*).
objects() { find "$1" -name '*.o' -ipath '*release*' -path '*AeroDJCore*' ! -path '*Tests*' "${@:2}"; }

swift build -c release
[ -n "$(objects .build ! -path "*/owner-ab/*")" ] || { echo "FAIL: no Release AeroDJCore objects to scan"; exit 1; }
if objects .build ! -path "*/owner-ab/*" | xargs grep -la "$marker"; then
  echo "FAIL: owner A/B gate found in a Release build without AERODJ_OWNER_AB"; exit 1
fi
if objects .build ! -path "*/owner-ab/*" | xargs grep -la "$owner_trial"; then
  echo "FAIL: ownerTrial (Pro gate bypass) found in a Release build without AERODJ_OWNER_AB"; exit 1
fi
swift test -c release -Xswiftc -enable-testing --filter 'PremiumVoicePickerTests|OwnerTrialIsFlagOnlyTests'

swift build -c release --scratch-path "$flagged" -Xswiftc -DAERODJ_OWNER_AB
objects "$flagged" | xargs grep -la "$marker" >/dev/null \
  || { echo "FAIL: control: marker missing from the AERODJ_OWNER_AB build"; exit 1; }
objects "$flagged" | xargs grep -la "$owner_trial" >/dev/null \
  || { echo "FAIL: control: ownerTrial missing from the AERODJ_OWNER_AB build"; exit 1; }
swift test -c release --scratch-path "$flagged" -Xswiftc -enable-testing -Xswiftc -DAERODJ_OWNER_AB \
  --filter 'PremiumVoicePickerTests.testOwnerABBuildEnablesGate|OwnerTrialIsFlagOnlyTests'
echo "OK: paid voices are off without AERODJ_OWNER_AB and on only with it"
