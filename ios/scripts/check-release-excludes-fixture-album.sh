#!/usr/bin/env bash
# Release AeroDJ must not contain the debug capture picture or the two fixture
# symbols that used to ship in the app target. Debug is the positive control:
# the same names must be present there, or this check could pass on an empty
# product.
#
# Asset: loose *FixtureAlbum* paths, plus the imageset name inside Assets.car.
# Symbols: `strings -a` and `nm -a` on the app Mach-O for
# PlayingScreenPreviewLoader and mockStations.
#
# Usage: check-release-excludes-fixture-album.sh <Debug AeroDJ.app> <Release AeroDJ.app>
set -euo pipefail

DEBUG_APP="${1:?Debug AeroDJ.app}"
RELEASE_APP="${2:?Release AeroDJ.app}"
NAMES=(PlayingScreenPreviewLoader mockStations)

binary() { echo "$1/AeroDJ"; }

contains_fixture_asset() {
  local app="$1"
  # find stops after one hit, so this pipe does not SIGPIPE under pipefail.
  if find "$app" -iname '*FixtureAlbum*' -print -quit | grep -q .; then
    return 0
  fi
  if [ -f "$app/Assets.car" ] && strings -a "$app/Assets.car" | grep -F 'FixtureAlbum' >/dev/null; then
    return 0
  fi
  return 1
}

# Prints matching lines. Always returns 0 so a miss is an empty string, not a
# failed pipeline. grep reads the whole input so pipefail does not see SIGPIPE.
symbol_hits() {
  local bin="$1" name="$2" from_strings from_nm
  from_strings="$(strings -a "$bin" | grep -F "$name" || true)"
  from_nm="$(nm -a "$bin" 2>/dev/null | grep -F "$name" || true)"
  printf '%s\n%s\n' "$from_strings" "$from_nm" | grep -F "$name" || true
  return 0
}

if [ ! -f "$(binary "$DEBUG_APP")" ] || [ ! -f "$(binary "$RELEASE_APP")" ]; then
  echo "FAIL: missing app binary."
  echo "Debug: $(binary "$DEBUG_APP")"
  echo "Release: $(binary "$RELEASE_APP")"
  exit 1
fi

echo "Debug binary: $(binary "$DEBUG_APP")"
echo "Release binary: $(binary "$RELEASE_APP")"

if ! contains_fixture_asset "$DEBUG_APP"; then
  echo "FAIL: FixtureAlbum not found in Debug app ($DEBUG_APP)."
  echo "The Release asset check would be vacuous without this control."
  find "$DEBUG_APP" \( -name 'Assets.car' -o -iname '*.png' \) -print | head
  exit 1
fi

if contains_fixture_asset "$RELEASE_APP"; then
  echo "FAIL: FixtureAlbum is in the Release app ($RELEASE_APP)."
  find "$RELEASE_APP" -iname '*FixtureAlbum*' -print || true
  exit 1
fi

echo "Release bundle files named Assets.car, png, or Fixture:"
find "$RELEASE_APP" \( -name 'Assets.car' -o -iname '*Fixture*' -o -iname '*.png' \) -print

for name in "${NAMES[@]}"; do
  if [ -z "$(symbol_hits "$(binary "$DEBUG_APP")" "$name")" ]; then
    echo "FAIL: $name not found in Debug binary via strings -a or nm -a."
    echo "The Release symbol check would be vacuous without this control."
    exit 1
  fi
  hits="$(symbol_hits "$(binary "$RELEASE_APP")" "$name")"
  if [ -n "$hits" ]; then
    echo "FAIL: $name is in the Release binary."
    echo "$hits"
    exit 1
  fi
  echo "OK: $name is in the Debug binary and absent from the Release binary."
done

echo "OK: Debug app contains FixtureAlbum; Release app does not."
echo "OK: Release binary has neither PlayingScreenPreviewLoader nor mockStations."
