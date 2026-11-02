#!/usr/bin/env bash
# Sourced by the Release fixture scans (check-release-excludes-test-station.sh for AeroDJCore,
# check-release-excludes-preview-fixtures.sh for the linked app). One needle loop for both. -Fry
#
# fixture_needle_count NEEDLE FILE... prints how often NEEDLE occurs in the files' raw bytes,
# not counting a build-artifact file name (NEEDLE.swift, NEEDLE.o, NEEDLE.d, ...). A Release
# object for a file that is entirely `#if DEBUG` still carries its own file name in DWARF, and a
# linked image can name it in a debug-map (OSO) entry; neither is fixture code. Any other form
# counts: a mangled symbol (`16PlaybackFixturesO`), the type-descriptor name, demangled `nm`
# text (`AeroDJCore.PlaybackFixtures.station`), or a string. Swift symbols never contain ".".
FIXTURE_PATH_EXTS='swift|o|d|dia|swiftdeps|swiftsourceinfo|swiftdoc|swiftmodule|swiftinterface|swiftconstvalues|bc|json'
fixture_needle_count() {
  local needle=${1:?needle}
  shift
  if [ "$#" -eq 0 ]; then echo 0; return 0; fi
  perl -0777 -ne '
    BEGIN { $n = shift @ARGV; $x = shift @ARGV }
    $c += () = /\Q$n\E(?!\.(?:$x)\b)/g;
    END { print(($c // 0) + 0, "\n") }' "$needle" "$FIXTURE_PATH_EXTS" "$@"
}

# fixture_needle_files NEEDLE FILE... lists the files that count (for failure output).
fixture_needle_files() {
  local needle=${1:?needle} f
  shift
  for f in "$@"; do
    [ "$(fixture_needle_count "$needle" "$f")" -gt 0 ] && echo "  $f"
  done
  return 0
}
