#!/usr/bin/env bash
# Publish the public name of one iOS job. GitHub does not treat a skipped
# job as success, so a path-filter skip has to be turned into an explicit
# success or a required check stays pending. A failed or cancelled heavy
# job stays a failure. GATE is the paths-filter output: "true" or "false".
set -euo pipefail

: "${JOB_NAME:?JOB_NAME is required}"

if [ "${CHANGES_RESULT:-}" != "success" ]; then
  echo "::error::${JOB_NAME} did not run because the iOS changes job result is ${CHANGES_RESULT:-missing}. Re-run the iOS workflow. Do not merge."
  exit 1
fi

if [ "${GATE:-}" = "false" ]; then
  echo "${JOB_NAME}: path filter skipped this job. Reporting success so the required check is not left pending."
  exit 0
fi

if [ "${GATE:-}" != "true" ]; then
  echo "::error::${JOB_NAME}: path filter output is '${GATE:-empty}', not true or false. Refusing to report success. Do not merge."
  exit 1
fi

if [ "${JOB_RESULT:-}" = "success" ]; then
  echo "${JOB_NAME}: success"
  exit 0
fi

echo "::error::${JOB_NAME} result is ${JOB_RESULT:-missing}. Fix that iOS job at this sha and re-run. Do not merge."
exit 1
