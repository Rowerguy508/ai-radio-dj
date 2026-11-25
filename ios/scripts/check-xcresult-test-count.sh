#!/usr/bin/env bash
# Fails unless one test bundle actually executed at least MIN tests (Sentinel's #391 N2).
# xcodebuild exits 0 when a filter or a broken target runs 0 tests, so a green test step alone
# does not prove the StoreKit tests ran.
#
#   check-xcresult-test-count.sh --bundle NAME --min N [--xcresult PATH] [--log PATH]
#
# Executed = Passed + Failed + Expected Failure. Skipped tests do not count.
# 1. --xcresult: `xcrun xcresulttool get test-results tests --path PATH` (Xcode 16+, incl. 26),
#    counting the "Test Case" nodes under the "Unit test bundle" / "UI test bundle" named NAME.
# 2. Fallback, only when 1 is unavailable: --log, the xcodebuild output. The last
#    "Test Suite 'NAME.xctest' passed|failed" line followed by "Executed N tests, with S tests
#    skipped ..." gives N - S.
# Neither source readable, the bundle absent, or fewer than MIN executed: ::error:: and exit 1.
# -Fry
set -euo pipefail

BUNDLE= MIN= XCRESULT= LOG=
while [ $# -gt 0 ]; do
  case $1 in
    --bundle) BUNDLE=$2; shift 2 ;;
    --min) MIN=$2; shift 2 ;;
    --xcresult) XCRESULT=$2; shift 2 ;;
    --log) LOG=$2; shift 2 ;;
    *) echo "::error::check-xcresult-test-count.sh: unknown argument $1"; exit 2 ;;
  esac
done
if [ -z "$BUNDLE" ] || ! [[ $MIN =~ ^[0-9]+$ ]] || [ "$MIN" -lt 1 ]; then
  echo "::error::check-xcresult-test-count.sh: need --bundle NAME and --min N (N >= 1)"
  exit 2
fi

summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$1" >> "$GITHUB_STEP_SUMMARY"; }

EXECUTED= SKIPPED= SOURCE=
if [ -n "$XCRESULT" ] && [ -d "$XCRESULT" ]; then
  if JSON=$(xcrun xcresulttool get test-results tests --path "$XCRESULT" 2>"${TMPDIR:-/tmp}/xcresulttool.err.$$"); then
    COUNTS=$(jq -r --arg b "$BUNDLE" '
      [.testNodes[]? | .. | objects
        | select((.nodeType == "Unit test bundle" or .nodeType == "UI test bundle")
                 and (.name == $b or .name == ($b + ".xctest")))]
      | if length == 0 then "absent"
        else [.[] | .. | objects | select(.nodeType == "Test Case") | .result // "unknown"]
          | "\(map(select(. == "Passed" or . == "Failed" or . == "Expected Failure")) | length) \(map(select(. == "Skipped")) | length) \(length)"
        end' <<<"$JSON") || COUNTS=
    if [ "$COUNTS" = "absent" ]; then
      echo "::error::$BUNDLE did not run: no '$BUNDLE' test bundle in $XCRESULT (0 tests executed)"
      summary "**$BUNDLE: 0 tests executed (bundle absent from the result bundle)**"
      exit 1
    elif [ -n "$COUNTS" ]; then
      read -r EXECUTED SKIPPED TOTAL <<<"$COUNTS"
      SOURCE="xcresult ($TOTAL test cases)"
    else
      echo "::warning::Could not parse xcresulttool output for $XCRESULT; falling back to the log"
    fi
  else
    echo "::warning::xcresulttool could not read $XCRESULT; falling back to the log"
    cat "${TMPDIR:-/tmp}/xcresulttool.err.$$" || true
  fi
  rm -f "${TMPDIR:-/tmp}/xcresulttool.err.$$"
elif [ -n "$XCRESULT" ]; then
  echo "::warning::No result bundle at $XCRESULT; falling back to the log"
fi

if [ -z "$EXECUTED" ] && [ -n "$LOG" ] && [ -f "$LOG" ]; then
  # The line after the bundle's closing "Test Suite '<NAME>.xctest' passed|failed at ..." line.
  LINE=$(awk -v s="Test Suite '$BUNDLE.xctest' " '
    found { if ($0 ~ /Executed [0-9]+ tests?/) { last = $0 } ; found = 0 }
    index($0, s) && ($0 ~ / (passed|failed) at /) { found = 1 }
    END { print last }' "$LOG")
  if [ -n "$LINE" ]; then
    N=$(sed -E 's/.*Executed ([0-9]+) tests?.*/\1/' <<<"$LINE")
    S=0
    if [[ $LINE =~ with\ ([0-9]+)\ tests?\ skipped ]]; then S=${BASH_REMATCH[1]}; fi
    EXECUTED=$((N - S)); SKIPPED=$S
    SOURCE="xcodebuild log"
  fi
fi

if [ -z "$EXECUTED" ]; then
  echo "::error::Could not count $BUNDLE tests: no readable result bundle${XCRESULT:+ ($XCRESULT)} and no '$BUNDLE.xctest' summary in the log${LOG:+ ($LOG)}. Treating as 0 tests executed."
  summary "**$BUNDLE: test count unavailable (treated as 0)**"
  exit 1
fi

echo "$BUNDLE: $EXECUTED executed, $SKIPPED skipped (minimum $MIN; source: $SOURCE)"
if [ "$EXECUTED" -lt "$MIN" ]; then
  echo "::error::$BUNDLE executed $EXECUTED tests ($SKIPPED skipped), fewer than the required $MIN. A test step that runs 0 tests must not pass."
  summary "**$BUNDLE: $EXECUTED executed, $SKIPPED skipped, minimum $MIN: FAILED**"
  exit 1
fi
summary "$BUNDLE: $EXECUTED executed, $SKIPPED skipped (minimum $MIN, $SOURCE)"
