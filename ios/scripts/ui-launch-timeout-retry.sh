#!/usr/bin/env bash
# Run one UI-test xcodebuild. If it fails only because the app launch timed out,
# boot the simulator again and rerun just those tests once.
# An assertion failure, or any other test failure, is not retried.
#
#   ui-launch-timeout-retry.sh --udid UDID -- xcodebuild test-without-building ...
#   ui-launch-timeout-retry.sh --decide path/to/xcodebuild.log
set -euo pipefail

LAUNCH_TIMEOUT='Timed out while launching application'

usage() {
  echo "usage: ui-launch-timeout-retry.sh [--udid UDID] -- command..." >&2
  echo "       ui-launch-timeout-retry.sh --decide LOG" >&2
  exit 2
}

# Prints -only-testing identifiers, one per line. Exit 0 when a retry is allowed.
# A retry is allowed only when every failed test's error is a launch timeout.
decide() {
  awk -v launch="$LAUNCH_TIMEOUT" '
    function testid(objc,    class, method, n, i, parts, target, rest) {
      class = objc
      sub(/ .*/, "", class)
      method = objc
      sub(/.* /, "", method)
      n = split(class, parts, "[.]")
      target = parts[1]
      rest = parts[2]
      for (i = 3; i <= n; i++) rest = rest "." parts[i]
      return target "/" rest "/" method
    }
    BEGIN { other = 0; timeouts = ""; failed = "" }
    {
      if ($0 ~ /error: -\[[^]]+\] : /) {
        line = $0
        sub(/^.*error: -\[/, "", line)
        objc = line
        sub(/\].*/, "", objc)
        msg = line
        sub(/^[^]]*\] : /, "", msg)
        if (index(msg, launch) && index(msg, "XCTAssert") == 0) {
          timeouts = timeouts testid(objc) "\n"
        } else {
          other = 1
        }
        next
      }
      if ($0 ~ /Test Case '"'"'-\[[^]]+\]'"'"' failed/) {
        line = $0
        sub(/^.*Test Case '"'"'-\[/, "", line)
        objc = line
        sub(/\].*/, "", objc)
        failed = failed testid(objc) "\n"
      }
    }
    END {
      if (other || timeouts == "" || failed == "") exit 1
      n = split(failed, f, "\n")
      for (i = 1; i <= n; i++) {
        if (f[i] == "") continue
        if (index("\n" timeouts, "\n" f[i] "\n") == 0) exit 1
      }
      seen = ""
      n = split(timeouts, t, "\n")
      for (i = 1; i <= n; i++) {
        if (t[i] == "") continue
        if (index("\n" seen, "\n" t[i] "\n") == 0) {
          print t[i]
          seen = seen t[i] "\n"
        }
      }
    }
  ' "$1"
}

if [[ ${1:-} == --decide ]]; then
  [[ $# -eq 2 && -f $2 ]] || usage
  decide "$2"
  exit $?
fi

udid=
if [[ ${1:-} == --udid ]]; then
  [[ $# -ge 2 ]] || usage
  udid=$2
  shift 2
fi
if [[ ${1:-} == -- ]]; then
  shift
fi
[[ $# -gt 0 ]] || usage

log=$(mktemp)
trap 'rm -f "$log"' EXIT

set +e
set +o pipefail
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -o pipefail
set -e
if [[ $status -eq 0 ]]; then
  exit 0
fi

set +e
ids=$(decide "$log")
decide_status=$?
set -e
if [[ $decide_status -ne 0 || -z $ids ]]; then
  exit "$status"
fi

warning=
while IFS= read -r id; do
  [[ -n $id ]] || continue
  if [[ -z $warning ]]; then warning=$id; else warning="$warning, $id"; fi
done <<< "$ids"
echo "::warning::Retrying UI tests after a simulator launch timeout: ${warning}"

if [[ -n $udid ]]; then
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b
fi

args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  if [[ ${args[$i]} == -resultBundlePath && $((i + 1)) -lt ${#args[@]} ]]; then
    bundle=${args[$((i + 1))]}
    case $bundle in
      *.xcresult) rm -rf "$bundle" ;;
    esac
  fi
  i=$((i + 1))
done

only_args=()
while IFS= read -r id; do
  [[ -n $id ]] || continue
  only_args+=("-only-testing:${id}")
done <<< "$ids"
if [[ ${#only_args[@]} -eq 0 ]]; then
  exit "$status"
fi

set +e
set +o pipefail
"$@" "${only_args[@]}" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -o pipefail
set -e
exit "$status"
