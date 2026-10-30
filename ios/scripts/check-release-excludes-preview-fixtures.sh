#!/usr/bin/env bash
# Release AeroDJ must not contain fixture playback code or a FixtureAlbum asset. Debug must
# contain every needle, so a missing binary or a broken scan cannot pass.
# Station.defaultStations (formerly mockStations) is intentionally still in Release and is not scanned.
#
# Needles (one loop, matcher shared with the AeroDJCore scan in fixture-needles.sh):
# - PlayingScreenPreviewLoader: the SwiftUI preview host in the app target.
# - PlaybackFixtures: the Debug-only fixture snapshots (re-lands #99 e79738b and #79's
#   linked-binary scan, -Atlas; -Fry). Its own file name (PlaybackFixtures.swift / .o) in a
#   Release object's DWARF or the linked image's debug map is not fixture code and is ignored.
#
# Asset scan: loose *FixtureAlbum* paths, plus that name inside Assets.car.
# Symbol scan, per configuration: raw bytes of that configuration's .o files, of the linked
# Mach-O (AeroDJ, plus AeroDJ.debug.dylib when Xcode splits Debug), and their `nm -a` output,
# demangled when swift-demangle is available. The linker can drop an unused preview from the
# linked image while the Debug object file still has the name; Release must have it nowhere.
#
# Usage: check-release-excludes-preview-fixtures.sh <Debug AeroDJ.app> <Release AeroDJ.app>
set -euo pipefail

DEBUG_APP="${1:?Debug AeroDJ.app}"
RELEASE_APP="${2:?Release AeroDJ.app}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fixture-needles.sh
source "$SCRIPT_DIR/fixture-needles.sh"
NEEDLES=(PlayingScreenPreviewLoader PlaybackFixtures)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

binary() { echo "$1/AeroDJ"; }

contains_fixture_asset() {
  local app="$1"
  if find "$app" -iname '*FixtureAlbum*' -print -quit | grep -q .; then
    return 0
  fi
  if [ -f "$app/Assets.car" ] && LC_ALL=C grep -a -F 'FixtureAlbum' "$app/Assets.car" >/dev/null; then
    return 0
  fi
  return 1
}

demangle() {
  if command -v xcrun >/dev/null 2>&1 && xcrun --find swift-demangle >/dev/null 2>&1; then
    xcrun swift-demangle
  elif command -v swift-demangle >/dev/null 2>&1; then
    swift-demangle
  else
    cat
  fi
}

# Prints the files to scan for one configuration's .app, one per line.
scan_inputs() {
  local app="$1" label="$2"
  local app_dir config build image nmout
  app_dir="$(dirname "$app")"
  config="$(basename "$app_dir")"
  build="$(dirname "$(dirname "$app_dir")")"
  if [ -d "$build/Intermediates.noindex" ]; then
    find "$build/Intermediates.noindex" -path "*${config}*" -name '*.o'
  fi
  for image in "$app/AeroDJ" "$app/AeroDJ.debug.dylib"; do
    [ -f "$image" ] || continue
    echo "$image"
    nmout="$WORK/$label-$(basename "$image").nm.txt"
    { nm -a "$image" 2>/dev/null || true; } | demangle > "$nmout"
    echo "$nmout"
  done
}

if [ ! -f "$(binary "$DEBUG_APP")" ] || [ ! -f "$(binary "$RELEASE_APP")" ]; then
  echo "FAIL: missing app binary."
  echo "Debug: $(binary "$DEBUG_APP")"
  echo "Release: $(binary "$RELEASE_APP")"
  exit 1
fi

echo "Debug binary: $(binary "$DEBUG_APP")"
echo "Release binary: $(binary "$RELEASE_APP")"
echo "Release bundle files named Assets.car, png, or Fixture:"
find "$RELEASE_APP" \( -name 'Assets.car' -o -iname '*Fixture*' -o -iname '*.png' \) -print

if contains_fixture_asset "$RELEASE_APP"; then
  echo "FAIL: FixtureAlbum is in the Release app ($RELEASE_APP)."
  find "$RELEASE_APP" -iname '*FixtureAlbum*' -print || true
  exit 1
fi
echo "OK: Release app has no FixtureAlbum asset."

# No mapfile: macOS runners may run bash 3.2.
debug_inputs=(); while IFS= read -r f; do debug_inputs+=("$f"); done < <(scan_inputs "$DEBUG_APP" debug)
release_inputs=(); while IFS= read -r f; do release_inputs+=("$f"); done < <(scan_inputs "$RELEASE_APP" release)
echo "Scanning ${#debug_inputs[@]} Debug and ${#release_inputs[@]} Release files."
[ "${#debug_inputs[@]}" -gt 0 ] && [ "${#release_inputs[@]}" -gt 0 ] || { echo "FAIL: nothing to scan"; exit 1; }

for needle in "${NEEDLES[@]}"; do
  if [ "$(fixture_needle_count "$needle" "${debug_inputs[@]}")" -eq 0 ]; then
    echo "FAIL: control: $needle not found in Debug object files or the Debug binary (raw bytes / nm -a)."
    echo "The Release symbol check would be vacuous without this control."
    printf '  %s\n' "${debug_inputs[@]}" | head -20
    exit 1
  fi
done
for needle in "${NEEDLES[@]}"; do
  if [ "$(fixture_needle_count "$needle" "${release_inputs[@]}")" -gt 0 ]; then
    echo "FAIL: $needle is in the Release build."
    fixture_needle_files "$needle" "${release_inputs[@]}"
    exit 1
  fi
done
echo "OK: ${NEEDLES[*]} are in the Debug build and absent from the Release build."
