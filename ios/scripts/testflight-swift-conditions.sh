#!/usr/bin/env bash
# Prints the extra SWIFT_ACTIVE_COMPILATION_CONDITIONS for the TestFlight archive
# (empty for a normal Release). The one place testflight.yml composes them; ios.yml
# runs the same script so CI checks what the archive would really get.
# Inputs (env): EVENT_NAME, P0_DIAG, OWNER_AB, TESTER_VOICE. Only the exact string "true"
# counts, and AERODJ_OWNER_AB / AERODJ_TESTER_VOICE need a workflow_dispatch run: push or any
# other event, or an empty/missing/other input, never passes them. AERODJ_TESTER_VOICE (#378)
# is the App Attest tester voice for internal TestFlight; an owner A/B build keeps the owner
# path, which takes precedence in code even if both are set.
set -euo pipefail
conds=""
if [ "${P0_DIAG:-}" = "true" ]; then conds+=" AERODJ_P0_DIAG"; fi
if [ "${EVENT_NAME:-}" = "workflow_dispatch" ] && [ "${OWNER_AB:-}" = "true" ]; then
  conds+=" AERODJ_OWNER_AB"
fi
if [ "${EVENT_NAME:-}" = "workflow_dispatch" ] && [ "${TESTER_VOICE:-}" = "true" ]; then
  conds+=" AERODJ_TESTER_VOICE"
fi
printf '%s\n' "$conds"
