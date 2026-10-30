#!/usr/bin/env bash
# Paid-voice needle: the owner A/B gate (ElevenLabs picker) exists only with AERODJ_OWNER_AB.
# 1. Release without the flag: no gate marker in AeroDJCore objects, and the Release-config
#    test asserts OwnerVoiceTrial.paidProvidersEnabled == false.
# 2. Positive control, Release with -DAERODJ_OWNER_AB (separate scratch dir): marker present
#    and the flagged test asserts the gate is on, so step 1 cannot pass vacuously.
# The owner trial access (`ownerTrial`, Pro gate bypass, Sentinel B1 on #244) gets the same
# treatment: absent from Release objects without the flag, present with it. -Fry
# Paid-route split (-Echo, #174 blocker 9), same steps, more needles:
# - gate 1: the owner proxy credential code (`OwnerProxyAuth`, Keychain service name) is owner-only;
# - gate 2: the public paid route is compiled OFF until #233 PRs 3-4 (AERODJ_PUBLIC_PAID_ROUTE,
#   which nothing sets); the flagged build sets it as well, as the positive control.
# One loop checks every needle in both builds (absent without the flags, present with them).
set -euo pipefail
cd "$(dirname "$0")/../AeroDJCore"
marker='AERODJ_OWNER_AB_VOICE_TRIAL_BUILD'
needles=(ownerTrial com.aerodj.owner-ab.tts-proxy AERODJ_PUBLIC_PAID_ROUTE_BUILD)
flagged=.build/owner-ab  # inside the ignored .build/, excluded from the plain scan
# -ipath: SwiftPM's layout varies (.build/release vs .build/out/Products/Release-*).
objects() { find "$1" -name '*.o' -ipath '*release*' -path '*AeroDJCore*' ! -path '*Tests*' "${@:2}"; }

swift build -c release
[ -n "$(objects .build ! -path "*/owner-ab/*")" ] || { echo "FAIL: no Release AeroDJCore objects to scan"; exit 1; }
if objects .build ! -path "*/owner-ab/*" | xargs grep -la "$marker"; then
  echo "FAIL: owner A/B gate found in a Release build without AERODJ_OWNER_AB"; exit 1
fi
for needle in "${needles[@]}"; do
  if objects .build ! -path "*/owner-ab/*" | xargs grep -laF "$needle"; then
    echo "FAIL: $needle found in a Release build without AERODJ_OWNER_AB / AERODJ_PUBLIC_PAID_ROUTE"; exit 1
  fi
done
swift test -c release -Xswiftc -enable-testing --filter 'PremiumVoicePickerTests|PaidVoiceRouteSplitTests|OwnerTrialIsFlagOnlyTests'

swift build -c release --scratch-path "$flagged" -Xswiftc -DAERODJ_OWNER_AB -Xswiftc -DAERODJ_PUBLIC_PAID_ROUTE
objects "$flagged" | xargs grep -la "$marker" >/dev/null \
  || { echo "FAIL: control: marker missing from the AERODJ_OWNER_AB build"; exit 1; }
for needle in "${needles[@]}"; do
  objects "$flagged" | xargs grep -laF "$needle" >/dev/null \
    || { echo "FAIL: control: $needle missing from the flagged build"; exit 1; }
done
swift test -c release --scratch-path "$flagged" -Xswiftc -enable-testing -Xswiftc -DAERODJ_OWNER_AB \
  -Xswiftc -DAERODJ_PUBLIC_PAID_ROUTE \
  --filter 'PremiumVoicePickerTests.testOwnerABBuildEnablesGate|PaidVoiceRouteSplitTests.testFlaggedBuildCompilesThePublicRouteIn|OwnerTrialIsFlagOnlyTests'
echo "OK: paid voices are off without AERODJ_OWNER_AB and on only with it"
