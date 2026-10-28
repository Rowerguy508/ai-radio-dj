#!/usr/bin/env bash
# Release AeroDJ must not contain PlayingScreenPreviewLoader or a FixtureAlbum
# asset. Debug must contain the loader symbol, so a missing binary cannot pass.
# Station.mockStations is intentionally still in Release and is not scanned.
#
# Asset scan: loose *FixtureAlbum* paths, plus that name inside Assets.car.
# Symbol scan: `strings -a` on the configuration's .o files, plus `strings -a`
# and `nm -a` on the linked Mach-O. The preview loader is unused by the running
# app, so the linker can drop it from AeroDJ while the Debug object file still
# has the name. Release must have it in neither place.
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

# Object files for the same configuration as the .app, plus the linked binary.
symbol_hits() {
  local app="$1" name="$2"
  local app_dir config build from_objects from_strings from_nm
  app_dir="$(dirname "$app")"
  config="$(basename "$app_dir")"
  build="$(dirname "$(dirname "$app_dir")")"
  from_objects=""
  if [ -d "$build/Intermediates.noindex" ]; then
    from_objects="$(find "$build/Intermediates.noindex" -path "*${config}*" -name '*.o' -exec strings -a {} + 2>/dev/null | grep -F "$name" || true)"
  fi
  from_strings="$(strings -a "$app/AeroDJ" | grep -F "$name" || true)"
  from_nm="$(nm -a "$app/AeroDJ" 2>/dev/null | grep -F "$name" || true)"
  printf '%s\n%s\n%s\n' "$from_objects" "$from_strings" "$from_nm" | grep -F "$name" || true
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
  echo "FAIL: $LOADER not found in Debug object files or the Debug binary (strings -a / nm -a)."
  echo "The Release symbol check would be vacuous without this control."
  exit 1
fi
hits="$(symbol_hits "$(binary "$RELEASE_APP")" "$LOADER")"
if [ -n "$hits" ]; then
  echo "FAIL: $LOADER is in the Release binary."
  echo "$hits"
  exit 1
fi
echo "OK: $LOADER is in the Debug build and absent from the Release build."
