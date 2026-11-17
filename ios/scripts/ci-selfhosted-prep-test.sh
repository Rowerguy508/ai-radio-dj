#!/usr/bin/env bash
# The self-hosted prep step fails closed under 8 GiB, and the error is runner
# infrastructure rather than a product failure. Capture failures in the iOS
# workflows use the same RUNNER INFRA wording.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PREP="$SCRIPT_DIR/ci-selfhosted-prep.sh"
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/df" << 'EOF'
#!/usr/bin/env bash
# Available is field 4, same column ci-selfhosted-prep.sh reads from `df -k`.
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
printf '/dev/disk1 %s 0 %s 50%% %s\n' "${FAKE_FREE_KB:?}" "${FAKE_FREE_KB:?}" "${FAKE_HOME:-/}"
EOF
chmod +x "$tmp/df"

run_check() {
  FAKE_FREE_KB=$1 PATH="$tmp:$PATH" HOME="$tmp/home" "$PREP" --check-disk >"$tmp/out" 2>"$tmp/err"
}

mkdir -p "$tmp/home"

set +e
run_check $((7 * 1024 * 1024))
code=$?
set -e
[[ $code -ne 0 ]] || fail "7 GiB free should fail"
grep -q '^::error::RUNNER INFRA:' "$tmp/out" || fail "7 GiB error should start with RUNNER INFRA: $(cat "$tmp/out")"
grep -q 'This is not a code failure' "$tmp/out" || fail "7 GiB error should say it is not a code failure: $(cat "$tmp/out")"
grep -q 'Free disk space or re-run on a clean runner' "$tmp/out" || fail "7 GiB error should say what to do: $(cat "$tmp/out")"
grep -q 'do not change product code' "$tmp/out" || fail "7 GiB error should say not to change product code: $(cat "$tmp/out")"
grep -q '::warning::' "$tmp/out" && fail "low disk must not warn"

set +e
run_check $((8 * 1024 * 1024 - 1))
code=$?
set -e
[[ $code -ne 0 ]] || fail "just under 8 GiB should fail"

run_check $((8 * 1024 * 1024))
grep -q 'Internal disk free: 8 GiB' "$tmp/out" || fail "exactly 8 GiB should pass: $(cat "$tmp/out")"
grep -q 'RUNNER INFRA' "$tmp/out" && fail "exactly 8 GiB should not be infra: $(cat "$tmp/out")"

run_check $((9 * 1024 * 1024))
grep -q 'Internal disk free: 9 GiB' "$tmp/out" || fail "9 GiB should pass: $(cat "$tmp/out")"

cat > "$tmp/df" << 'EOF'
#!/usr/bin/env bash
echo "not a df table"
EOF
chmod +x "$tmp/df"
set +e
FAKE_FREE_KB=0 PATH="$tmp:$PATH" HOME="$tmp/home" "$PREP" --check-disk >"$tmp/out" 2>"$tmp/err"
code=$?
set -e
[[ $code -ne 0 ]] || fail "unreadable df should fail"
grep -q '^::error::RUNNER INFRA:' "$tmp/out" || fail "unreadable df should be RUNNER INFRA: $(cat "$tmp/out")"
grep -q 'This is not a code failure' "$tmp/out" || fail "unreadable df should say it is not a code failure"

# Restore a low-disk df and prove the full prep path fails before linking DerivedData.
cat > "$tmp/df" << 'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
printf '/dev/disk1 %s 0 %s 50%% %s\n' "${FAKE_FREE_KB:?}" "${FAKE_FREE_KB:?}" "${FAKE_HOME:-/}"
EOF
chmod +x "$tmp/df"
ws="$tmp/ws"
mkdir -p "$ws"
dd="$ws/ios/build/DerivedData-runtime"
set +e
FAKE_FREE_KB=$((3 * 1024 * 1024)) PATH="$tmp:$PATH" HOME="$tmp/home" \
  GITHUB_WORKSPACE="$ws" DERIVED_DATA="$dd" \
  "$PREP" runtime-mode >"$tmp/out" 2>"$tmp/err"
code=$?
set -e
[[ $code -ne 0 ]] || fail "full prep should fail under 8 GiB"
grep -q 'only 3 GiB free' "$tmp/out" || fail "full prep should report the shortfall: $(cat "$tmp/out")"
[[ ! -L "$dd" ]] || fail "full prep linked DerivedData after a low-disk failure"

FAKE_FREE_KB=$((20 * 1024 * 1024)) PATH="$tmp:$PATH" HOME="$tmp/home" \
  GITHUB_WORKSPACE="$ws" DERIVED_DATA="$dd" \
  "$PREP" runtime-mode >"$tmp/out"
[[ -L "$dd" ]] || fail "full prep should link DerivedData when disk is fine"
grep -q 'Internal disk free: 20 GiB' "$tmp/out" || fail "full prep should print free space: $(cat "$tmp/out")"

ios_yml="$REPO_ROOT/.github/workflows/ios.yml"
ipad_yml="$REPO_ROOT/.github/workflows/ios-ipad.yml"
grep -q 'ci-selfhosted-prep.sh --check-disk' "$ios_yml" || fail "ios.yml should disk-check self-hosted jobs that do not relocate DerivedData"
grep -q 'ci-selfhosted-prep.sh --check-disk' "$ipad_yml" || fail "ios-ipad.yml should disk-check a self-hosted runner"
grep -q 'ci-selfhosted-prep.sh runtime-mode' "$ios_yml" || fail "runtime-mode should still call prep"
grep -q 'ci-selfhosted-prep.sh studio-screenshots' "$ios_yml" || fail "studio-screenshots should still call prep"
grep -q 'RUNNER INFRA: walkthrough-closed.mp4 is missing or empty' "$ios_yml" || fail "empty mp4 should be RUNNER INFRA"
grep -q 'RUNNER INFRA: simctl recordVideo exited' "$ios_yml" || fail "dead recorder should be RUNNER INFRA"
grep -q 'RUNNER INFRA: could not copy walkthrough-closed.mp4' "$ios_yml" || fail "mp4 copy failure should be RUNNER INFRA"
if grep -n 'Less than 8 GiB' "$PREP" "$ios_yml" "$ipad_yml"; then
  fail "disk check still warns"
fi

echo "ok"
