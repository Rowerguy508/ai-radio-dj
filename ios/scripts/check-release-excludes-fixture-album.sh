#!/usr/bin/env bash
# FixtureAlbum is a debug capture picture on this branch. It must be inside
# the Debug app and absent from the Release app, both as a loose file and as
# an asset-catalog name. The Debug hit is the positive control.
#
# PlayingScreenPreviewLoader is gated on #83, against integration/device-duo.
# Station.mockStations stays in Release. This script does not scan either name.
#
# Usage: check-release-excludes-fixture-album.sh <Debug AeroDJ.app> <Release AeroDJ.app>
set -euo pipefail

DEBUG_APP="${1:?Debug AeroDJ.app}"
RELEASE_APP="${2:?Release AeroDJ.app}"

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

if [ ! -d "$DEBUG_APP" ] || [ ! -d "$RELEASE_APP" ]; then
  echo "FAIL: missing app bundle."
  echo "Debug: $DEBUG_APP"
  echo "Release: $RELEASE_APP"
  exit 1
fi

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
echo "OK: Debug app contains FixtureAlbum; Release app does not."
