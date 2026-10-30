#!/usr/bin/env bash
# Tests for check-release-excludes-preview-fixtures.sh on fake DerivedData (runs on Linux or macOS).
# The scan must fail closed: a needle missing from Debug fails the control, any code form of a
# needle in Release fails, and only a needle's own file name (DWARF / debug map) is ignored. -Fry
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCAN="$SCRIPT_DIR/check-release-excludes-preview-fixtures.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# make CASE CONFIG BINARY_TEXT OBJECT_TEXT [DYLIB_TEXT]
make() {
  local dd="$tmp/$1" config=$2
  mkdir -p "$dd/Build/Products/$config-iphonesimulator/AeroDJ.app" \
    "$dd/Build/Intermediates.noindex/AeroDJ.build/$config-iphonesimulator/AeroDJ.build/Objects-normal/arm64"
  printf '%b' "$3" > "$dd/Build/Products/$config-iphonesimulator/AeroDJ.app/AeroDJ"
  printf '%b' "$4" > "$dd/Build/Intermediates.noindex/AeroDJ.build/$config-iphonesimulator/AeroDJ.build/Objects-normal/arm64/X.o"
  [ -z "${5:-}" ] || printf '%b' "$5" > "$dd/Build/Products/$config-iphonesimulator/AeroDJ.app/AeroDJ.debug.dylib"
}
app() { echo "$tmp/$1/Build/Products/$2-iphonesimulator/AeroDJ.app"; }

pass=0
# run NAME WANT(0|1) DEBUG_CASE RELEASE_CASE [MESSAGE]
run() {
  local name=$1 want=$2 got=0 log="$tmp/log"
  bash "$SCAN" "$(app "$3" Debug)" "$(app "$4" Release)" > "$log" 2>&1 || got=1
  if [ "$got" != "$want" ]; then echo "FAIL: $name (exit $got, wanted $want)" >&2; cat "$log" >&2; exit 1; fi
  if [ -n "${5:-}" ] && ! grep -qF -- "$5" "$log"; then echo "FAIL: $name: missing '$5'" >&2; cat "$log" >&2; exit 1; fi
  pass=$((pass + 1))
}

DEBUG_CODE='\x00$s10AeroDJCore16PlaybackFixturesO7stationAA10StationRefVvpZ\x00PlaybackFixtures\x00$s6AeroDJ26PlayingScreenPreviewLoaderV\x00'
make dbg Debug 'stub' "$DEBUG_CODE"
make dbgdylib Debug 'stub' 'nothing' "$DEBUG_CODE"
make dbg-no-fixtures Debug 'stub' '\x00$s6AeroDJ26PlayingScreenPreviewLoaderV\x00'
make rel-clean Release '\x00$s6AeroDJ6PlayerV\x00' '\x00/src/AeroDJCore/Playback/PlaybackFixtures.swift\x00PlaybackFixtures.o\x00'
make rel-symbol Release '\x00$s10AeroDJCore16PlaybackFixturesO5songsSayAA9TrackInfoVGvpZ\x00' 'x'
make rel-descriptor Release 'x' '\x00PlaybackFixtures\x00'
make rel-demangled Release 'x\x00AeroDJCore.PlaybackFixtures.station\x00' 'x'
make rel-loader Release '\x00$s6AeroDJ26PlayingScreenPreviewLoaderV\x00' 'x'
make rel-asset Release 'x' 'x'
touch "$(app rel-asset Release)/FixtureAlbum.png"

run "clean Release passes; file-name-only forms are ignored" 0 dbg rel-clean "OK: PlayingScreenPreviewLoader PlaybackFixtures"
run "Debug code in AeroDJ.debug.dylib satisfies the control" 0 dbgdylib rel-clean "OK:"
run "control: PlaybackFixtures missing from Debug fails" 1 dbg-no-fixtures rel-clean "FAIL: control: PlaybackFixtures"
run "mangled PlaybackFixtures symbol in Release fails" 1 dbg rel-symbol "FAIL: PlaybackFixtures is in the Release build"
run "PlaybackFixtures type name in a Release object fails" 1 dbg rel-descriptor "FAIL: PlaybackFixtures is in the Release build"
run "demangled PlaybackFixtures member in Release fails" 1 dbg rel-demangled "FAIL: PlaybackFixtures is in the Release build"
run "preview loader in Release fails" 1 dbg rel-loader "FAIL: PlayingScreenPreviewLoader is in the Release build"
run "FixtureAlbum asset in Release fails" 1 dbg rel-asset "FAIL: FixtureAlbum"
run "missing Release binary fails" 1 dbg does-not-exist "FAIL: missing app binary"
# Both Release scans must keep the PlaybackFixtures needle (a dropped needle passes vacuously).
grep -qE '^NEEDLES=\(.*[( ]PlaybackFixtures( .*)?\)$' "$SCAN" || { echo "FAIL: app scan lost the PlaybackFixtures needle" >&2; exit 1; }
grep -qE '^needles=\(.*[( ]PlaybackFixtures( .*)?\)$' "$SCRIPT_DIR/check-release-excludes-test-station.sh" \
  || { echo "FAIL: AeroDJCore scan lost the PlaybackFixtures needle" >&2; exit 1; }
pass=$((pass + 1))
echo "OK: $pass preview-fixture scan cases"
