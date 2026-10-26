#!/usr/bin/env bash
# Release AeroDJ must not contain PlayingScreenPreviewLoader or a FixtureAlbum
# asset. Debug must contain the loader symbol, so a missing binary cannot pass.
# Station.mockStations is intentionally still in Release and is not scanned.
#
# Asset scan: loose *FixtureAlbum* paths, plus that name inside Assets.car.
# Symbol scan: `strings -a` and `nm -a` on the app Mach-O.
#
# Usage: check-release-excludes-preview-fixtures.sh <Debug AeroDJ.app> <Release AeroDJ.app>
set -euo pipefail

DEBUG_APP="${1:?Debug AeroDJ.app}"
RELEASE_APP="${2:?Release AeroDJ.app}"
LOADER=PlayingScreenPreviewLoader

binary() { echo "$1/AeroDJ"; }

contains_fixture_asset() {
  local app="$1"
  if find "$app" -iname '*FixtureAlbum*' -print -quit | grep -q .; then
    return 0
  fi
  if [ -f "$app/Assets.car" ] && strings -a "$app/Assets.car" | grep -F 'FixtureAlbum' >/dev/null; then
    return 0
  fi
  return 1
}

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
echo "Release bundle files named Assets.car, png, or Fixture:"
find "$RELEASE_APP" \( -name 'Assets.car' -o -iname '*Fixture*' -o -iname '*.png' \) -print

if contains_fixture_asset "$RELEASE_APP"; then
  echo "FAIL: FixtureAlbum is in the Release app ($RELEASE_APP)."
  find "$RELEASE_APP" -iname '*FixtureAlbum*' -print || true
  exit 1
fi
echo "OK: Release app has no FixtureAlbum asset."

if [ -z "$(symbol_hits "$(binary "$DEBUG_APP")" "$LOADER")" ]; then
  echo "FAIL: $LOADER not found in Debug binary via strings -a or nm -a."
  echo "The Release symbol check would be vacuous without this control."
  exit 1
fi
hits="$(symbol_hits "$(binary "$RELEASE_APP")" "$LOADER")"
if [ -n "$hits" ]; then
  echo "FAIL: $LOADER is in the Release binary."
  echo "$hits"
  exit 1
fi
echo "OK: $LOADER is in the Debug binary and absent from the Release binary."
