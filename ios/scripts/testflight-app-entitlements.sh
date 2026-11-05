#!/usr/bin/env bash
# Prints the CODE_SIGN_ENTITLEMENTS path (relative to ios/) for the AeroDJ app target of a
# TestFlight archive (#378, -Atlas). Same inputs and the same strict rule as
# testflight-swift-conditions.sh, which it calls so the two can never disagree: the tester
# file (App Attest entitlement) only when that script emits AERODJ_TESTER_VOICE, i.e. a
# workflow_dispatch run with TESTER_VOICE exactly "true". Every other build (push, normal
# Release, owner A/B, P0 diag) keeps the shared AeroDJ.entitlements, which never carries the
# App Attest key, so it signs with the current app profile unchanged.
set -euo pipefail
conds="$("$(dirname "$0")/testflight-swift-conditions.sh")"
case " $conds " in
  *" AERODJ_TESTER_VOICE "*) printf '%s\n' "AeroDJ/AeroDJ-TesterVoice.entitlements" ;;
  *) printf '%s\n' "AeroDJ/AeroDJ.entitlements" ;;
esac
