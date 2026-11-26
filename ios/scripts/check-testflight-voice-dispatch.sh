#!/usr/bin/env bash
# Refuse a TestFlight upload whose DJ falls back to on-device speech unless the
# dispatcher opted in. Build 49 was dispatched without -f tester_voice=true.
# tester_voice still defaults to false (testflight.yml); the old warning fired
# only when the flag was on, so the dangerous case was silent.
#
# The default stays false. Turning it on would compile AERODJ_TESTER_VOICE for
# every dispatch that omitted the flag, including owner_ab and p0_diag. Those
# builds must stay distinct: the voice renderer prefers AERODJ_OWNER_AB, but
# the entitlements selector follows TESTER_VOICE alone, so a default of true
# would sign owner A/B and P0 uploads with the App Attest profile. Outside
# owner A/B it would also compile the tester GDELT provider.
#
# testflight.yml runs this in the voice-gate job (ubuntu-latest, no signing
# environment) before the upload job is allowed to start. Only the exact string
# "true" counts, matching that workflow's env expressions. CONFIRM_DEVICE_VOICE
# does not add a Swift condition; testflight-swift-conditions.sh ignores it.
set -euo pipefail

tester="${TESTER_VOICE:-}"
confirm="${CONFIRM_DEVICE_VOICE:-}"

if [ "$tester" != "true" ] && [ "$confirm" != "true" ]; then
  echo "::error::Refusing TestFlight upload: tester_voice is false, so the DJ will fall back to on-device speech (build 49). Re-run with -f tester_voice=true, or -f confirm_device_voice=true if a device-speech build is intentional. An owner_ab or p0_diag build that must not compile the tester voice sets -f confirm_device_voice=true and leaves tester_voice false."
  exit 1
fi

if [ "$tester" = "true" ] && [ "$confirm" = "true" ]; then
  echo "::warning::confirm_device_voice is set, but tester_voice=true, so this is a tester cloud-voice build (AERODJ_TESTER_VOICE). confirm_device_voice does not apply."
elif [ "$tester" != "true" ]; then
  echo "::warning::Uploading a device-speech build because confirm_device_voice=true (AERODJ_TESTER_VOICE is off)."
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### TestFlight voice"
    if [ "$tester" = "true" ]; then
      echo "- Tester cloud voice (\`tester_voice=true\`, AERODJ_TESTER_VOICE)."
    else
      echo "- On-device speech (\`confirm_device_voice=true\`, AERODJ_TESTER_VOICE off)."
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
