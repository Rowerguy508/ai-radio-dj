#!/usr/bin/env bash
# Tests for check-owner-ab-build-settings.sh against a fake xcodebuild on PATH (runs on Linux or macOS).
# The gate must fail closed: an empty, failed or wrong-target settings read fails, and only the
# expected flag state passes. Also guards the SIGPIPE flake from iOS run 40926834267 (#215). -Atlas
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GATE="$SCRIPT_DIR/check-owner-ab-build-settings.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/xcodebuild" << 'XC'
#!/usr/bin/env bash
# Fake: prints $FAKE_OUT (a file), optionally followed by ~3 MB of filler, and exits $FAKE_EXIT.
[ -z "${FAKE_OUT:-}" ] || cat "$FAKE_OUT"
if [ "${FAKE_BIG:-0}" = 1 ]; then
  yes "    FILLER_SETTING = xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" | head -c 3000000 || true
fi
exit "${FAKE_EXIT:-0}"
XC
chmod +x "$tmp/bin/xcodebuild"

pass=0
# run NAME WANT(0|1) EXPECT OUTFILE BIG EXIT [MSG]
run() {
  local name=$1 want=$2 expect=$3 out=$4 big=$5 code=$6 msg=${7:-} log="$tmp/log" got=0
  PATH="$tmp/bin:$PATH" FAKE_OUT="$out" FAKE_BIG="$big" FAKE_EXIT="$code" \
    bash "$GATE" "$expect" > "$log" 2>&1 || got=1
  if [ "$got" != "$want" ]; then echo "FAIL: $name (exit status $got, wanted $want)" >&2; cat "$log" >&2; exit 1; fi
  if [ -n "$msg" ] && ! grep -qF -- "$msg" "$log"; then echo "FAIL: $name (missing '$msg')" >&2; cat "$log" >&2; exit 1; fi
  pass=$((pass+1))
}

head_ok=$'    CONFIGURATION = Release\n    TARGET_NAME = AeroDJ'
printf '%s\n' "$head_ok" > "$tmp/plain"                                          # no conditions line
printf '%s\n    SWIFT_ACTIVE_COMPILATION_CONDITIONS = RELEASE_X\n' "$head_ok" > "$tmp/other"
printf '%s\n    SWIFT_ACTIVE_COMPILATION_CONDITIONS = RELEASE_X AERODJ_OWNER_AB\n' "$head_ok" > "$tmp/flag"
: > "$tmp/empty"
printf '    CONFIGURATION = Release\n    TARGET_NAME = AeroDJShare\n    SWIFT_ACTIVE_COMPILATION_CONDITIONS = AERODJ_OWNER_AB\n' > "$tmp/wrongtarget"
printf '    CONFIGURATION = Debug\n    TARGET_NAME = AeroDJ\n' > "$tmp/debug"
printf '    SWIFT_ACTIVE_COMPILATION_CONDITIONS = AERODJ_OWNER_AB_X\n%s\n' "$head_ok" > "$tmp/lookalike"

# Fails closed on an unusable read, for both expectations.
for e in absent present; do
  run "empty read ($e)"            1 $e "$tmp/empty"       0 0 "could not read the AeroDJ Release build settings"
  run "empty read, big ($e)"       1 $e "$tmp/empty"       1 0 "could not read the AeroDJ Release build settings"
  run "xcodebuild fails ($e)"      1 $e "$tmp/flag"        0 65 "xcodebuild -showBuildSettings failed"
  run "wrong target ($e)"          1 $e "$tmp/wrongtarget" 0 0 "could not read the AeroDJ Release build settings"
  run "Debug, not Release ($e)"    1 $e "$tmp/debug"       0 0 "could not read the AeroDJ Release build settings"
done
run "bad expectation"              1 maybe "$tmp/plain"    0 0 "usage:"

# Flag state.
run "no conditions -> absent"      0 absent  "$tmp/plain"  0 0 "OK: AERODJ_OWNER_AB absent"
run "no conditions, want present"  1 present "$tmp/plain"  0 0 "is absent"
run "other conditions -> absent"   0 absent  "$tmp/other"  0 0 "OK: AERODJ_OWNER_AB absent"
run "flag set -> present"          0 present "$tmp/flag"   0 0 "OK: AERODJ_OWNER_AB present"
run "flag set, want absent"        1 absent  "$tmp/flag"   0 0 "is present"
run "lookalike is not the flag"    0 absent  "$tmp/lookalike" 0 0 "OK: AERODJ_OWNER_AB absent"

# Large output after the matches (the SIGPIPE flake); repeated, since it was intermittent on CI.
for i in 1 2 3 4 5; do
  run "big, flag set -> present #$i" 0 present "$tmp/flag"  1 0 "OK: AERODJ_OWNER_AB present"
  run "big, no flag -> absent #$i"   0 absent  "$tmp/plain" 1 0 "OK: AERODJ_OWNER_AB absent"
  run "big, flag set, want absent #$i" 1 absent "$tmp/flag" 1 0 "is present"
done

echo "OK: $pass check-owner-ab-build-settings cases"
