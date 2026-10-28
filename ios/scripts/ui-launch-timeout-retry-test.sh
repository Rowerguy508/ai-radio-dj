#!/usr/bin/env bash
# A launch-timeout log may be retried. An assertion failure may not,
# including when a launch timeout is in the same log.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RETRY="$SCRIPT_DIR/ui-launch-timeout-retry.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Shape copied from iOS run 40417687802 (iPad Studio UI), including later passes.
cat > "$tmp/timeout.log" << 'EOF'
Test Case '-[AeroDJUITests.StudioScreenTests testAX5DarkAppearance]' started.
<unknown>:0: error: -[AeroDJUITests.StudioScreenTests testAX5DarkAppearance] : Failed to launch <XCUIApplicationImpl: 0x600001754dc0 com.aerodj.app at /Users/runner/work/ai-radio-dj/ai-radio-dj/ios/build/DerivedData-ui/Build/Products/Debug-iphonesimulator/AeroDJ.app> via Xcode: Timed out while launching application via Xcode.
Test Case '-[AeroDJUITests.StudioScreenTests testAX5DarkAppearance]' failed (85.018 seconds).
Test Case '-[AeroDJUITests.StudioScreenTests testAX5LightAppearance]' started.
<unknown>:0: error: -[AeroDJUITests.StudioScreenTests testAX5LightAppearance] : Failed to launch <XCUIApplicationImpl: 0x600001754dc0 com.aerodj.app at /Users/runner/work/ai-radio-dj/ai-radio-dj/ios/build/DerivedData-ui/Build/Products/Debug-iphonesimulator/AeroDJ.app> via Xcode: Timed out while launching application via Xcode.
Test Case '-[AeroDJUITests.StudioScreenTests testAX5LightAppearance]' failed (61.072 seconds).
Test Case '-[AeroDJUITests.StudioScreenTests testOpenDuoIsTwoZoneControlRoom]' passed (10.266 seconds).
2026-10-27 00:04:21.019 xcodebuild[14338:87053]  IDELaunchReport: Finished with error: Failed to send signal 19 to process 26113: 3
Testing failed:
** TEST EXECUTE FAILED **
EOF

timeout_ids=$("$RETRY" --decide "$tmp/timeout.log") || fail "launch-timeout log should be retried"
expected=$'AeroDJUITests/StudioScreenTests/testAX5DarkAppearance\nAeroDJUITests/StudioScreenTests/testAX5LightAppearance'
[[ $timeout_ids == "$expected" ]] || fail "retry ids were:
$timeout_ids"

# The phrase appears, but the failure is an assertion. Must not retry.
cat > "$tmp/assert.log" << 'EOF'
Test Case '-[AeroDJUITests.StudioScreenTests testOpenDuoIsTwoZoneControlRoom]' started.
note: Timed out while launching application via Xcode
/Users/runner/StudioScreenTests.swift:72: error: -[AeroDJUITests.StudioScreenTests testOpenDuoIsTwoZoneControlRoom] : XCTAssertLessThanOrEqual failed: ("678.5") is greater than ("436.0") - Zones do not overlap
Test Case '-[AeroDJUITests.StudioScreenTests testOpenDuoIsTwoZoneControlRoom]' failed (8.813 seconds).
** TEST EXECUTE FAILED **
EOF

set +e
assert_ids=$("$RETRY" --decide "$tmp/assert.log" 2>"$tmp/assert.err")
assert_code=$?
set -e
[[ $assert_code -ne 0 ]] || fail "assertion-failure log was retried: $assert_ids"
[[ -z $assert_ids ]] || fail "assertion-failure log printed retry ids: $assert_ids"

cat > "$tmp/mixed.log" << 'EOF'
Test Case '-[AeroDJUITests.StudioScreenTests testAX5DarkAppearance]' started.
<unknown>:0: error: -[AeroDJUITests.StudioScreenTests testAX5DarkAppearance] : Failed to launch com.aerodj.app via Xcode: Timed out while launching application via Xcode.
Test Case '-[AeroDJUITests.StudioScreenTests testAX5DarkAppearance]' failed (85.018 seconds).
Test Case '-[AeroDJUITests.StudioScreenTests testOpenDuoIsTwoZoneControlRoom]' started.
/Users/runner/StudioScreenTests.swift:72: error: -[AeroDJUITests.StudioScreenTests testOpenDuoIsTwoZoneControlRoom] : XCTAssertLessThanOrEqual failed: ("678.5") is greater than ("436.0")
Test Case '-[AeroDJUITests.StudioScreenTests testOpenDuoIsTwoZoneControlRoom]' failed (8.813 seconds).
EOF

set +e
mixed_ids=$("$RETRY" --decide "$tmp/mixed.log")
mixed_code=$?
set -e
[[ $mixed_code -ne 0 ]] || fail "assertion plus launch timeout was retried: $mixed_ids"
[[ -z $mixed_ids ]] || fail "mixed log printed retry ids: $mixed_ids"

# A failed test with no launch-timeout error blocks the retry.
cat > "$tmp/other.log" << 'EOF'
<unknown>:0: error: -[AeroDJUITests.StudioScreenTests testAX5DarkAppearance] : Failed to launch com.aerodj.app via Xcode: Timed out while launching application via Xcode.
Test Case '-[AeroDJUITests.StudioScreenTests testAX5DarkAppearance]' failed (85.018 seconds).
Test Case '-[AeroDJUITests.StudioScreenTests testReadyStateShowsNoBreakText]' failed (2.000 seconds).
EOF

set +e
other_ids=$("$RETRY" --decide "$tmp/other.log")
other_code=$?
set -e
[[ $other_code -ne 0 ]] || fail "unclassified failure was retried: $other_ids"
[[ -z $other_ids ]] || fail "unclassified failure printed retry ids: $other_ids"

cat > "$tmp/fake-xcodebuild" << 'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >> "$CALLS"
echo >> "$CALLS"
echo x >> "$COUNT"
n=$(( $(wc -l < "$COUNT") ))
if [[ ${MODE:-} == always ]]; then
  cat "$FIXTURE"
  exit 65
fi
if [[ $n -eq 1 ]]; then
  mkdir -p "$BUNDLE"
  cat "$FIXTURE"
  exit 65
fi
printf '%s\n' "$@" | grep -q -- '-only-testing:AeroDJUITests/StudioScreenTests/testAX5DarkAppearance'
printf '%s\n' "$@" | grep -q -- '-only-testing:AeroDJUITests/StudioScreenTests/testAX5LightAppearance'
[[ ! -d $BUNDLE ]]
exit 0
EOF
chmod +x "$tmp/fake-xcodebuild"

: > "$tmp/count"
: > "$tmp/calls"
out=$("$RETRY" -- \
  env MODE=retry FIXTURE="$tmp/timeout.log" COUNT="$tmp/count" CALLS="$tmp/calls" BUNDLE="$tmp/phone.xcresult" \
  "$tmp/fake-xcodebuild" -resultBundlePath "$tmp/phone.xcresult" CODE_SIGNING_ALLOWED=NO)
[[ $out == *'::warning::Retrying UI tests after a simulator launch timeout: AeroDJUITests/StudioScreenTests/testAX5DarkAppearance, AeroDJUITests/StudioScreenTests/testAX5LightAppearance'* ]] \
  || fail "missing retry warning:
$out"
[[ $(wc -l < "$tmp/count") -eq 2 ]] || fail "timeout run was not retried exactly once"

: > "$tmp/count"
set +e
assert_out=$("$RETRY" -- \
  env MODE=always FIXTURE="$tmp/assert.log" COUNT="$tmp/count" CALLS="$tmp/calls" BUNDLE="$tmp/unused.xcresult" \
  "$tmp/fake-xcodebuild" -resultBundlePath "$tmp/unused.xcresult")
assert_run=$?
set -e
[[ $assert_run -eq 65 ]] || fail "assertion run exited $assert_run, want the original status"
[[ $assert_out != *'::warning::'* ]] || fail "assertion run printed a retry warning"
[[ $(wc -l < "$tmp/count") -eq 1 ]] || fail "assertion run was retried"

: > "$tmp/count"
set +e
always_out=$("$RETRY" -- \
  env MODE=always FIXTURE="$tmp/timeout.log" COUNT="$tmp/count" CALLS="$tmp/calls" BUNDLE="$tmp/again.xcresult" \
  "$tmp/fake-xcodebuild" -resultBundlePath "$tmp/again.xcresult")
always_run=$?
set -e
[[ $always_run -eq 65 ]] || fail "second timeout exited $always_run"
[[ $(wc -l < "$tmp/count") -eq 2 ]] || fail "launch timeout was retried more than once"
[[ $always_out == *'::warning::'* ]] || fail "second-timeout run did not warn"

echo "OK: UI launch-timeout retry script tests"
