#!/usr/bin/env bash
# Fails if a Release SwiftPM build of AeroDJCore contains a token from
# ios/scripts/release-fixture-denylist.txt.
# Positive control: Debug objects must contain FixtureContextSource, so the check
# cannot pass when the scan is broken or the denylist was emptied.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DENYLIST="$SCRIPT_DIR/release-fixture-denylist.txt"
cd "$SCRIPT_DIR/../AeroDJCore"

PATFILE=$(mktemp)
HITS=$(mktemp)
trap 'rm -f "$PATFILE" "$HITS"' EXIT
grep -E -v '^[[:space:]]*(#|$)' "$DENYLIST" > "$PATFILE"
[[ -s "$PATFILE" ]] || { echo "FAIL: denylist is empty: $DENYLIST"; exit 1; }
grep -q -x -F -- 'FixtureContextSource' "$PATFILE" || {
  echo "FAIL: denylist is missing FixtureContextSource"
  exit 1
}

# Library objects for one configuration; works with both SwiftPM build-directory layouts.
objects() { find .build -name '*.o' -ipath "*/$1*" -path '*AeroDJCore*' ! -path '*Tests*'; }

swift build -c debug
control=0
while IFS= read -r obj; do
  if grep -a -q -F -- 'FixtureContextSource' "$obj"; then
    control=1
    break
  fi
done < <(objects debug)
[[ "$control" -eq 1 ]] || { echo "FAIL: control: FixtureContextSource not found in Debug objects"; exit 1; }

swift build -c release
if [[ -z "$(objects release)" ]]; then
  echo "FAIL: no Release objects were produced"
  exit 1
fi
while IFS= read -r obj; do
  while IFS= read -r pat; do
    if grep -a -q -F -- "$pat" "$obj"; then
      printf 'symbol %s %s\n' "$obj" "$pat"
    fi
  done < "$PATFILE"
done < <(objects release) | sort -u > "$HITS"

if [[ -s "$HITS" ]]; then
  echo "FAIL: fixture patterns in Release SwiftPM objects"
  cat "$HITS"
  exit 1
fi
echo "OK: Release SwiftPM objects exclude the fixture denylist"
