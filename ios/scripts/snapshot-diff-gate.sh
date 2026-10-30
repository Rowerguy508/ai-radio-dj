#!/usr/bin/env bash
# Run the masked iPhone screenshot compare and fail on a change, unless the PR
# carries the label snapshot-change-approved. With the label the compare still
# runs and writes its report, the job is not failed, and the bypass is logged.
#   snapshot-diff-gate.sh BASE_DIR HEAD_DIR REPORT
# Env: SNAPSHOT_LABELS = the PR's current label names, one per line.
# Writes bypassed=true|false to $GITHUB_OUTPUT when that is set. -Atlas
set -uo pipefail
base="${1:?usage: snapshot-diff-gate.sh BASE_DIR HEAD_DIR REPORT}"
head="${2:?usage: snapshot-diff-gate.sh BASE_DIR HEAD_DIR REPORT}"
report="${3:?usage: snapshot-diff-gate.sh BASE_DIR HEAD_DIR REPORT}"
label="snapshot-change-approved"
here="$(cd "$(dirname "$0")" && pwd)"

python3 "$here/compare-iphone-screenshots.py" "$base" "$head" --report "$report"
rc=$?

approved=false
if printf '%s\n' "${SNAPSHOT_LABELS:-}" | grep -Fxq -- "$label"; then
  approved=true
fi

bypassed=false
if [ "$rc" -eq 0 ]; then
  if [ "$approved" = true ]; then
    echo "::notice::Label $label is set, but no iPhone screenshot changed outside the status bar; nothing was bypassed."
  fi
elif [ "$approved" = true ]; then
  bypassed=true
  msg="BYPASSED BY LABEL $label: iPhone screenshots changed outside the status bar (compare exit $rc). The job is not failed; review iphone-compare.txt and the base-screenshots artifact."
  echo "::warning::$msg"
  printf '%s\n' "$msg" >> "$report"
else
  echo "::error::iPhone screenshots changed outside the status bar (see iphone-compare.txt and the base-screenshots artifact). If the change is intended, add the label $label and re-run this job."
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "bypassed=$bypassed" >> "$GITHUB_OUTPUT"
fi
if [ "$bypassed" = true ]; then
  exit 0
fi
exit "$rc"
