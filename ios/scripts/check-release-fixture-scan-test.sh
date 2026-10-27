#!/usr/bin/env bash
# Fake-binary checks for the fixture byte scan.
# A token that merely shares a source file's name fails.
# A token that appears only as "/<name>.swift" in the raw bytes passes.
# A token that appears only after Swift demangles a word-substituted symbol fails.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MATCH="$SCRIPT_DIR/fixture-scan-match.py"
DENYLIST="$SCRIPT_DIR/release-fixture-denylist.txt"
BUNDLE="$SCRIPT_DIR/check-release-bundle-fixtures.sh"
# shellcheck source=fixture-scan-symbols.sh
source "$SCRIPT_DIR/fixture-scan-symbols.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf 'PlaybackFixtures' > "$tmp/bare"
bare_hits=$(python3 "$MATCH" "$DENYLIST" "$tmp/bare")
grep -q -x -F -- 'PlaybackFixtures' <<< "$bare_hits" || fail "bare PlaybackFixtures did not fail the scan"

printf 'PlaybackFixtures.swift' > "$tmp/noslash"
noslash_hits=$(python3 "$MATCH" "$DENYLIST" "$tmp/noslash")
grep -q -x -F -- 'PlaybackFixtures' <<< "$noslash_hits" || fail "PlaybackFixtures.swift without a slash did not fail"

printf '/src/AeroDJCore/Playback/PlaybackFixtures.swift' > "$tmp/path"
path_hits=$(python3 "$MATCH" "$DENYLIST" "$tmp/path")
[[ -z "$path_hits" ]] || fail "path form should pass, got: $path_hits"

printf '/src/PlaybackFixtures.swift\nPlaybackFixtures' > "$tmp/both"
both_hits=$(python3 "$MATCH" "$DENYLIST" "$tmp/both")
grep -q -x -F -- 'PlaybackFixtures' <<< "$both_hits" || fail "path plus a bare token should fail"

make_app() {
  local dest=$1 payload=$2
  mkdir -p "$dest/PlugIns/AeroDJShare.appex"
  # No Info.plist here, so the script uses the bundle name AeroDJ.
  printf '%s' "$payload" > "$dest/AeroDJ"
  printf 'share' > "$dest/PlugIns/AeroDJShare.appex/AeroDJShare"
}

make_app "$tmp/debug/AeroDJ.app" 'PlayingScreenPreviewLoader PlaybackFixtures'
make_app "$tmp/release-path/AeroDJ.app" '/src/AeroDJCore/Playback/PlaybackFixtures.swift'
"$BUNDLE" "$tmp/debug/AeroDJ.app" "$tmp/release-path/AeroDJ.app" >/dev/null || fail "bundle scan should pass when Release has only the path form"

make_app "$tmp/release-bare/AeroDJ.app" 'PlaybackFixtures'
set +e
bundle_out=$("$BUNDLE" "$tmp/debug/AeroDJ.app" "$tmp/release-bare/AeroDJ.app" 2>&1)
bundle_code=$?
set -e
[[ "$bundle_code" -eq 1 ]] || fail "bundle scan should fail on a bare PlaybackFixtures, got $bundle_code"
grep -q -F -- 'PlaybackFixtures' <<< "$bundle_out" || fail "bundle failure did not name PlaybackFixtures"

# Word substitution: the second "Preview"/"Loader" words are back-references.
# The raw mangled bytes do not contain PlayingScreenPreviewLoader.
# `swift demangle` reconstructs it. The path exemption does not apply to that text.
command -v swift >/dev/null 2>&1 || fail "swift demangle is required"
mangled='$s4Test07Playing6Screen7Preview6Loader0V'
printf '%s' "$mangled" > "$tmp/mangled-only"
if grep -a -q -F -- 'PlayingScreenPreviewLoader' "$tmp/mangled-only"; then
  fail "planted mangled symbol contains PlayingScreenPreviewLoader as raw bytes"
fi
printf '%s\n' "$mangled" | swift demangle > "$tmp/demangled-only"
grep -q -F -- 'PlayingScreenPreviewLoader' "$tmp/demangled-only" || fail "swift demangle did not reveal PlayingScreenPreviewLoader"
demangled_hits=$(python3 "$MATCH" "$DENYLIST" "$tmp/mangled-only" "AeroDJ" "$tmp/demangled-only")
grep -q -x -F -- 'PlayingScreenPreviewLoader' <<< "$demangled_hits" || fail "demangled-only token did not fail the scan"
raw_only_hits=$(python3 "$MATCH" "$DENYLIST" "$tmp/mangled-only")
[[ -z "$raw_only_hits" ]] || fail "raw mangled bytes should not match, got: $raw_only_hits"

# A demangled path is still a symbol match. The raw-byte exemption does not apply.
printf 'x' > "$tmp/blank"
printf '%s' '/src/PlayingScreenPreviewLoader.swift' > "$tmp/demangled-path"
path_demangled_hits=$(python3 "$MATCH" "$DENYLIST" "$tmp/blank" "AeroDJ" "$tmp/demangled-path")
grep -q -x -F -- 'PlayingScreenPreviewLoader' <<< "$path_demangled_hits" || fail "demangled path form should fail"
raw_path_hits=$(python3 "$MATCH" "$DENYLIST" "$tmp/path" "AeroDJ" "$tmp/blank")
[[ -z "$raw_path_hits" ]] || fail "raw path form should still pass when demangled text has no token, got: $raw_path_hits"

# GNU nm reads this object. macOS nm does not, so the object check runs only there.
# The demangle assertion above is the required check on every host.
if as --version 2>/dev/null | grep -q 'GNU assembler'; then
  cat > "$tmp/sym.s" << 'EOF'
.globl $s4Test07Playing6Screen7Preview6Loader0V
$s4Test07Playing6Screen7Preview6Loader0V:
    ret
EOF
  as -o "$tmp/sym.o" "$tmp/sym.s"
  if grep -a -q -F -- 'PlayingScreenPreviewLoader' "$tmp/sym.o"; then
    fail "assembled object contains PlayingScreenPreviewLoader as raw bytes"
  fi
  fixture_nm_demangle "$tmp/sym.o" "$tmp/sym-demangled"
  grep -q -F -- 'PlayingScreenPreviewLoader' "$tmp/sym-demangled" || fail "nm | swift demangle missed PlayingScreenPreviewLoader"
  object_hits=$(python3 "$MATCH" "$DENYLIST" "$tmp/sym.o" "AeroDJ" "$tmp/sym-demangled")
  grep -q -x -F -- 'PlayingScreenPreviewLoader' <<< "$object_hits" || fail "object with only a demangled token did not fail"
fi

echo "OK: fixture scan script tests"
