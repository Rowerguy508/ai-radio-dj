#!/usr/bin/env bash
# Fake-binary checks for the fixture byte scan.
# A token that merely shares a source file's name fails.
# A token that appears only as "/<name>.swift" passes.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MATCH="$SCRIPT_DIR/fixture-scan-match.py"
DENYLIST="$SCRIPT_DIR/release-fixture-denylist.txt"
BUNDLE="$SCRIPT_DIR/check-release-bundle-fixtures.sh"

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

make_app "$tmp/debug/AeroDJ.app" 'PlayingScreenPreviewLoader mockStations'
make_app "$tmp/release-path/AeroDJ.app" '/src/AeroDJCore/Playback/PlaybackFixtures.swift'
"$BUNDLE" "$tmp/debug/AeroDJ.app" "$tmp/release-path/AeroDJ.app" >/dev/null || fail "bundle scan should pass when Release has only the path form"

make_app "$tmp/release-bare/AeroDJ.app" 'PlaybackFixtures'
set +e
bundle_out=$("$BUNDLE" "$tmp/debug/AeroDJ.app" "$tmp/release-bare/AeroDJ.app" 2>&1)
bundle_code=$?
set -e
[[ "$bundle_code" -eq 1 ]] || fail "bundle scan should fail on a bare PlaybackFixtures, got $bundle_code"
grep -q -F -- 'PlaybackFixtures' <<< "$bundle_out" || fail "bundle failure did not name PlaybackFixtures"

echo "OK: fixture scan script tests"
