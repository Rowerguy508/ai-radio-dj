#!/usr/bin/env bash
# Tests for check-xcresult-test-count.sh with a fake xcrun (runs on Linux or macOS; needs jq).
# The guard must fail closed: 0 executed, skipped-only, a missing bundle, fewer than --min, or no
# readable source all fail; only enough executed tests in the named bundle pass. -Fry
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CHECK="$SCRIPT_DIR/check-xcresult-test-count.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Fake xcrun: `xcrun xcresulttool get test-results tests --path P` prints P/tests.json, or fails
# when P/fail exists (an unreadable or pre-Xcode-16 result bundle).
mkdir -p "$tmp/bin"
cat > "$tmp/bin/xcrun" << 'FAKE'
#!/usr/bin/env bash
[ "$1 $2 $3 $4 $5" = "xcresulttool get test-results tests --path" ] || { echo "fake xcrun: $*" >&2; exit 64; }
[ ! -e "$6/fail" ] || { echo "Error: unrecognized result bundle" >&2; exit 1; }
cat "$6/tests.json"
FAKE
chmod +x "$tmp/bin/xcrun"
export PATH="$tmp/bin:$PATH"
unset GITHUB_STEP_SUMMARY

# case NAME + test-case results for the StoreKit bundle, e.g. "Passed Passed Skipped".
# Shape follows `xcresulttool get test-results tests` (Test Plan > bundle > suite > case), plus a
# Core bundle that must not be counted for StoreKit.
bundle() {
  local dir="$tmp/$1"; shift
  mkdir -p "$dir"
  local cases="" r i=0
  for r in "$@"; do
    i=$((i + 1))
    cases+="${cases:+,}{\"nodeType\":\"Test Case\",\"name\":\"test$i()\",\"result\":\"$r\",\"children\":[{\"nodeType\":\"Failure Message\",\"name\":\"x\"}]}"
  done
  cat > "$dir/tests.json" << JSON
{"testPlanConfigurations":[{"configurationId":"1","configurationName":"Test Scheme Action"}],
 "devices":[{"deviceName":"iPad (A16)","architecture":"arm64","modelName":"iPad (A16)","osVersion":"26.2"}],
 "testNodes":[{"nodeType":"Test Plan","name":"AeroDJ","result":"Passed","children":[
   {"nodeType":"Unit test bundle","name":"AeroDJCoreTests","result":"Passed","children":[
     {"nodeType":"Test Suite","name":"CoreSuite","children":[
       {"nodeType":"Test Case","name":"a()","result":"Passed"},{"nodeType":"Test Case","name":"b()","result":"Passed"},
       {"nodeType":"Test Case","name":"c()","result":"Passed"},{"nodeType":"Test Case","name":"d()","result":"Passed"},
       {"nodeType":"Test Case","name":"e()","result":"Passed"},{"nodeType":"Test Case","name":"f()","result":"Passed"},
       {"nodeType":"Test Case","name":"g()","result":"Passed"},{"nodeType":"Test Case","name":"h()","result":"Passed"},
       {"nodeType":"Test Case","name":"i()","result":"Passed"},{"nodeType":"Test Case","name":"j()","result":"Passed"},
       {"nodeType":"Test Case","name":"k()","result":"Passed"},{"nodeType":"Test Case","name":"l()","result":"Passed"}]}]}
   ,{"nodeType":"Unit test bundle","name":"AeroDJStoreKitTests","children":[
     {"nodeType":"Test Suite","name":"ProSubscriptionStoreKitTests","children":[$cases]}]}
 ]}]}
JSON
  jq -e . "$dir/tests.json" > /dev/null
}

# log NAME CONTENT: an xcodebuild log (shape copied from iPad run 41618228659).
log() { printf '%s\n' "$2" > "$tmp/$1.log"; }
skl() {  # skl EXECUTED_LINE: the StoreKit bundle's closing lines
  printf "Test Suite 'ProSubscriptionStoreKitTests' passed at 2026-11-03 10:50:36.055.\n\t %s\nTest Suite 'AeroDJStoreKitTests.xctest' passed at 2026-11-03 10:50:36.055.\n\t %s\nTest Suite 'All tests' passed at 2026-11-03 10:50:36.055.\n\t Executed 40 tests, with 0 failures (0 unexpected) in 11.291 (11.296) seconds\n** TEST EXECUTE SUCCEEDED **" "$1" "$1"
}

pass=0
# run NAME WANT(0|1) MESSAGE ARGS...
run() {
  local name=$1 want=$2 msg=$3 got=0; shift 3
  bash "$CHECK" --bundle AeroDJStoreKitTests --min 11 "$@" > "$tmp/out" 2>&1 || got=1
  if [ "$got" != "$want" ]; then echo "FAIL: $name (exit $got, wanted $want)" >&2; cat "$tmp/out" >&2; exit 1; fi
  if ! grep -qF -- "$msg" "$tmp/out"; then echo "FAIL: $name: missing '$msg'" >&2; cat "$tmp/out" >&2; exit 1; fi
  pass=$((pass + 1))
}

P11=(Passed Passed Passed Passed Passed Passed Passed Passed Passed Passed Passed)
bundle ok "${P11[@]}"
bundle more "${P11[@]}" Passed
bundle failed Passed Passed Passed Passed Passed Passed Passed Passed Passed Failed "Expected Failure"
bundle skipped Passed Passed Passed Passed Passed Passed Passed Passed Passed Skipped Skipped
bundle allskipped Skipped Skipped Skipped Skipped Skipped Skipped Skipped Skipped Skipped Skipped Skipped
bundle empty
mkdir -p "$tmp/absent" # no StoreKit bundle at all (Core's 12 tests must not count)
jq '.testNodes[0].children |= map(select(.name != "AeroDJStoreKitTests"))' "$tmp/ok/tests.json" > "$tmp/absent/tests.json"
bundle xctest "${P11[@]}"
sed -i.bak 's/"name":"AeroDJStoreKitTests"/"name":"AeroDJStoreKitTests.xctest"/' "$tmp/xctest/tests.json"
bundle broken "${P11[@]}"; touch "$tmp/broken/fail"
mkdir -p "$tmp/garbage"; echo 'not json' > "$tmp/garbage/tests.json"

log good "$(skl 'Executed 11 tests, with 0 failures (0 unexpected) in 11.291 (11.296) seconds')"
log zero "$(skl 'Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds')"
log skips "$(skl 'Executed 11 tests, with 2 tests skipped and 0 failures (0 unexpected) in 9.0 (9.0) seconds')"
log failing "$(skl 'Executed 11 tests, with 1 failure (1 unexpected) in 11.0 (11.0) seconds' | sed 's/xctest. passed/xctest'"'"' failed/')"
log other "Test Suite 'AeroDJCoreTests.xctest' passed at 2026-11-03 10:37:20.1.
	 Executed 120 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds"

run "xcresult: 11 passed"                0 "11 executed, 0 skipped"             --xcresult "$tmp/ok"
run "xcresult: 12 passed"                0 "12 executed"                        --xcresult "$tmp/more"
run "xcresult: failures still executed"  0 "11 executed"                        --xcresult "$tmp/failed"
run "xcresult: .xctest bundle name"      0 "11 executed"                        --xcresult "$tmp/xctest"
run "xcresult: skips do not count"       1 "executed 9 tests (2 skipped), fewer than the required 11" --xcresult "$tmp/skipped"
run "xcresult: all skipped"              1 "executed 0 tests (11 skipped)"      --xcresult "$tmp/allskipped"
run "xcresult: bundle with 0 cases"      1 "executed 0 tests (0 skipped)"       --xcresult "$tmp/empty"
run "xcresult: bundle absent"            1 "no 'AeroDJStoreKitTests' test bundle" --xcresult "$tmp/absent"
run "xcresult wins over the log"         1 "executed 9 tests"                   --xcresult "$tmp/skipped" --log "$tmp/good.log"
run "unreadable xcresult -> log"         0 "source: xcodebuild log"             --xcresult "$tmp/broken" --log "$tmp/good.log"
run "garbage xcresult -> log"            0 "11 executed"                        --xcresult "$tmp/garbage" --log "$tmp/good.log"
run "missing xcresult -> log"            0 "11 executed"                        --xcresult "$tmp/nope" --log "$tmp/good.log"
run "log: 0 tests"                       1 "executed 0 tests"                   --xcresult "$tmp/nope" --log "$tmp/zero.log"
run "log: skips subtracted"              1 "executed 9 tests (2 skipped)"       --log "$tmp/skips.log"
run "log: failed suite still counted"    0 "11 executed"                        --log "$tmp/failing.log"
run "log: other bundle only"             1 "Could not count AeroDJStoreKitTests tests" --log "$tmp/other.log"
run "no sources at all"                  1 "Treating as 0 tests executed"       --xcresult "$tmp/nope" --log "$tmp/nope.log"
run "broken xcresult and no log"         1 "Treating as 0 tests executed"       --xcresult "$tmp/broken"
run "bad --min"                          1 "need --bundle NAME and --min N"     --min 0 --xcresult "$tmp/ok"

echo "check-xcresult-test-count-test: $pass cases passed"
