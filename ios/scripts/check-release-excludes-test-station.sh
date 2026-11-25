#!/usr/bin/env bash
# Fails if debug-only fixture code is compiled into a Release build of AeroDJCore:
# the test station (FixtureContextSource, TestStationFixtures, fixture:synthetic/) and
# fixture playback (PlaybackFixtures; re-lands #99 e79738b / #79, -Atlas; -Fry).
# Positive control: every needle must be found in the Debug build, so the check can't pass vacuously.
# Matching is shared with the app scan (fixture-needles.sh), which ignores a needle's own file
# name (PlaybackFixtures.swift / .o) in Release objects.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fixture-needles.sh
source "$SCRIPT_DIR/fixture-needles.sh"
cd "$SCRIPT_DIR/../AeroDJCore"
needles=(FixtureContextSource TestStationFixtures fixture:synthetic/ PlaybackFixtures)
# Library objects for one configuration; works with both SwiftPM build-directory layouts.
objects() { find .build -name '*.o' -ipath "*/$1*" -path '*AeroDJCore*' ! -path '*Tests*' ! -path '*/owner-ab/*'; }

swift build -c debug
debug_objects=(); while IFS= read -r f; do debug_objects+=("$f"); done < <(objects debug)  # no mapfile: macOS bash 3.2
[ "${#debug_objects[@]}" -gt 0 ] || { echo "FAIL: control: no Debug AeroDJCore objects"; exit 1; }
for needle in "${needles[@]}"; do
  [ "$(fixture_needle_count "$needle" "${debug_objects[@]}")" -gt 0 ] \
    || { echo "FAIL: control: $needle not found in Debug objects"; exit 1; }
done

swift build -c release
release_objects=(); while IFS= read -r f; do release_objects+=("$f"); done < <(objects release)
[ "${#release_objects[@]}" -gt 0 ] || { echo "FAIL: no Release AeroDJCore objects to scan"; exit 1; }
for needle in "${needles[@]}"; do
  if [ "$(fixture_needle_count "$needle" "${release_objects[@]}")" -gt 0 ]; then
    echo "FAIL: $needle found in Release build"
    fixture_needle_files "$needle" "${release_objects[@]}"
    exit 1
  fi
done
echo "OK: Release build excludes ${needles[*]} (each present in Debug)"
