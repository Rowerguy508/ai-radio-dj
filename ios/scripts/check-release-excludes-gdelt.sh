#!/usr/bin/env bash
# #200 (-Echo): GDELT local news is TESTERS ONLY. The Release build without AERODJ_TESTER_VOICE (and
# the owner A/B build) must not contain the GDELT host; the tester-voice build must (positive control).
set -euo pipefail
cd "$(dirname "$0")/../AeroDJCore"
host="api.gdeltproject.org"
objects() { find "$1" -name '*.o' -ipath '*release*' -path '*AeroDJCore*' ! -path '*Tests*' "${@:2}"; }

swift build -c release
[ -n "$(objects .build ! -path "*/owner-ab/*" ! -path "*/tester-voice/*")" ] || { echo "FAIL: no Release AeroDJCore objects to scan"; exit 1; }
if objects .build ! -path "*/owner-ab/*" ! -path "*/tester-voice/*" | xargs grep -la "$host"; then
  echo "FAIL: GDELT host in a non-tester Release build"; exit 1
fi

owner=".build/owner-ab"
swift build -c release --scratch-path "$owner" -Xswiftc -DAERODJ_OWNER_AB
if objects "$owner" | xargs grep -la "$host"; then
  echo "FAIL: GDELT host in the owner A/B Release build"; exit 1
fi

# Outside .build so the other release scripts' plain-.build scans never see it.
both="${TMPDIR:-/tmp}/aerodj-owner-ab-tester-$$"
swift build -c release --scratch-path "$both" -Xswiftc -DAERODJ_OWNER_AB -Xswiftc -DAERODJ_TESTER_VOICE
if objects "$both" | xargs grep -la "$host"; then
  echo "FAIL: GDELT host in an owner A/B build that also sets the tester flag"; exit 1
fi

tester=".build/tester-voice"
swift build -c release --scratch-path "$tester" -Xswiftc -DAERODJ_TESTER_VOICE
objects "$tester" | xargs grep -la "$host" >/dev/null \
  || { echo "FAIL: positive control: GDELT host missing from the tester-voice Release build"; exit 1; }
rm -rf "$both"
echo "OK: GDELT only in the tester-voice build"
