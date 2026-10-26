#!/usr/bin/env bash
# Fails if the debug-only test station is compiled into a Release build of AeroDJCore.
# Positive control: the same pattern must be found in the Debug build, so the check can't pass vacuously.
set -euo pipefail
cd "$(dirname "$0")/../AeroDJCore"
pattern='FixtureContextSource|TestStationFixtures|fixture:synthetic/'
# Library objects for one configuration; works with both SwiftPM build-directory layouts.
objects() { find .build -name '*.o' -ipath "*/$1*" -path '*AeroDJCore*' ! -path '*Tests*'; }

swift build -c debug
objects debug | xargs grep -laE "$pattern" >/dev/null || { echo "FAIL: control: pattern not found in Debug objects"; exit 1; }

swift build -c release
if objects release | xargs grep -laE "$pattern"; then
  echo "FAIL: test station found in Release build"; exit 1
fi
echo "OK: Release build excludes the test station"
