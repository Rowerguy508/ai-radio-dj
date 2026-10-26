#!/usr/bin/env bash
# FixtureAlbum is a debug capture picture. It must be inside the Debug app and
# absent from the Release app, both as a loose file and as an asset-catalog name.
# The Debug hit is the positive control so an empty product cannot pass.
#
# Usage: check-release-excludes-fixture-album.sh <Debug AeroDJ.app> <Release AeroDJ.app>
set -euo pipefail

DEBUG_APP="${1:?Debug AeroDJ.app}"
RELEASE_APP="${2:?Release AeroDJ.app}"

contains_fixture() {
  local app="$1"
  if find "$app" -iname '*FixtureAlbum*' -print -quit | grep -q .; then
    return 0
  fi
  if [ -f "$app/Assets.car" ] && strings "$app/Assets.car" | grep -q 'FixtureAlbum'; then
    return 0
  fi
  return 1
}

if ! contains_fixture "$DEBUG_APP"; then
  echo "FAIL: FixtureAlbum not found in Debug app ($DEBUG_APP)."
  echo "The Release check would be vacuous without this control."
  find "$DEBUG_APP" -iname '*.car' -o -iname '*.png' | head
  exit 1
fi

if contains_fixture "$RELEASE_APP"; then
  echo "FAIL: FixtureAlbum is in the Release app ($RELEASE_APP)."
  find "$RELEASE_APP" -iname '*FixtureAlbum*' || true
  exit 1
fi

echo "OK: Debug app contains FixtureAlbum; Release app does not."
