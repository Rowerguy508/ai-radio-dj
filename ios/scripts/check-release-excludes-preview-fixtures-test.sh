#!/usr/bin/env bash
# Tests for check-release-excludes-preview-fixtures.sh on fake DerivedData (runs on Linux or macOS).
# The scan must fail closed: a needle missing from Debug fails the control, any code form of a
# needle in Release fails, and only a needle's own file name (DWARF / debug map) is ignored. -Fry
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCAN="$SCRIPT_DIR/check-release-excludes-preview-fixtures.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# SDK is the platform suffix: iphonesimulator (runtime-mode job) or iphoneos (device-build job).
SDK=iphonesimulator

# make CASE CONFIG BINARY_TEXT OBJECT_TEXT [DYLIB_TEXT]
make() {
  local dd="$tmp/$1" config=$2
  mkdir -p "$dd/Build/Products/$config-$SDK/AeroDJ.app" \
    "$dd/Build/Intermediates.noindex/AeroDJ.build/$config-$SDK/AeroDJ.build/Objects-normal/arm64"
  printf '%b' "$3" > "$dd/Build/Products/$config-$SDK/AeroDJ.app/AeroDJ"
  printf '%b' "$4" > "$dd/Build/Intermediates.noindex/AeroDJ.build/$config-$SDK/AeroDJ.build/Objects-normal/arm64/X.o"
  [ -z "${5:-}" ] || printf '%b' "$5" > "$dd/Build/Products/$config-$SDK/AeroDJ.app/AeroDJ.debug.dylib"
}
app() { echo "$tmp/$1/Build/Products/$2-$SDK/AeroDJ.app"; }

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

# Device (iphoneos) layout, as scanned by the device-build job: same pass/fail. -Fry
SDK=iphoneos
make dev-dbg Debug 'stub' "$DEBUG_CODE"
make dev-rel-clean Release '\x00$s6AeroDJ6PlayerV\x00' '\x00PlaybackFixtures.o\x00'
make dev-rel-symbol Release '\x00$s10AeroDJCore16PlaybackFixturesO5songsSayAA9TrackInfoVGvpZ\x00' 'x'
make dev-rel-object Release 'x' '\x00$s6AeroDJ26PlayingScreenPreviewLoaderV\x00'
make dev-rel-nobin Release 'x' 'x'
rm "$(app dev-rel-nobin Release)/AeroDJ"
run "device: clean Release passes" 0 dev-dbg dev-rel-clean "OK: PlayingScreenPreviewLoader PlaybackFixtures"
run "device: PlaybackFixtures in the Release binary fails" 1 dev-dbg dev-rel-symbol "FAIL: PlaybackFixtures is in the Release build"
run "device: preview loader in a Release object fails" 1 dev-dbg dev-rel-object "FAIL: PlayingScreenPreviewLoader is in the Release build"
run "device: .app without its binary fails" 1 dev-dbg dev-rel-nobin "FAIL: missing app binary"
run "device: missing Release .app fails" 1 dev-dbg does-not-exist "FAIL: missing app binary"
# Both Release scans must keep the PlaybackFixtures needle (a dropped needle passes vacuously).
grep -qE '^NEEDLES=\(.*[( ]PlaybackFixtures( .*)?\)$' "$SCAN" || { echo "FAIL: app scan lost the PlaybackFixtures needle" >&2; exit 1; }
grep -qE '^needles=\(.*[( ]PlaybackFixtures( .*)?\)$' "$SCRIPT_DIR/check-release-excludes-test-station.sh" \
  || { echo "FAIL: AeroDJCore scan lost the PlaybackFixtures needle" >&2; exit 1; }
# The app scan must stay wired to both the Release simulator and the Release device builds.
WF="$SCRIPT_DIR/../../.github/workflows/ios.yml"
if [ -f "$WF" ]; then
  for sdk in iphonesimulator iphoneos; do
    if ! grep -B3 -F "\"\$DERIVED_DATA/Build/Products/Release-$sdk/AeroDJ.app\"" "$WF" \
        | grep -qF 'check-release-excludes-preview-fixtures.sh'; then
      echo "FAIL: ios.yml no longer runs the app scan on the Release $sdk build" >&2; exit 1
    fi
  done
fi
pass=$((pass + 1))
echo "OK: $pass preview-fixture scan cases"
