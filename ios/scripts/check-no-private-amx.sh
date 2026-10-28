#!/usr/bin/env bash
# Fails if any Mach-O in an app contains Apple's private AMX coprocessor
# instructions, i.e. a __text word w with (w & 0xFFFFFC00) == 0x00201000.
# App Store processing rejects these with ITMS-90755 (build 12, PhononCore gemm).
#
# Usage: check-no-private-amx.sh <AeroDJ.app> [positive-control.a]
# With a positive control, it must have at least one hit, so the scan cannot pass vacuously.
set -euo pipefail

APP="${1:?AeroDJ.app}"
CONTROL="${2:-}"

amx_hits() {
  # otool -t -X: __text as 32-bit hex words, no addresses or headers.
  otool -t -X "$1" 2>/dev/null | python3 -c '
import re, sys
n = 0
for tok in re.findall(r"\b[0-9a-fA-F]{8}\b", sys.stdin.read()):
    if int(tok, 16) & 0xFFFFFC00 == 0x00201000:
        n += 1
print(n)'
}

test -x "$APP/AeroDJ" || { echo "::error::$APP/AeroDJ missing"; exit 1; }

scanned=0
bad=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  scanned=$((scanned + 1))
  n="$(amx_hits "$f")"
  if [ "$n" -gt 0 ]; then
    echo "::error::$n private AMX instruction(s) in ${f#"$APP/"}"
    bad=1
  fi
done < <(find "$APP" -type f -print0)

[ "$scanned" -gt 0 ] || { echo "::error::no Mach-O files found in $APP"; exit 1; }
[ "$bad" -eq 0 ] || exit 1
echo "OK: $scanned Mach-O file(s) in $(basename "$APP") have no private AMX instructions."

if [ -n "$CONTROL" ]; then
  n="$(amx_hits "$CONTROL")"
  [ "$n" -gt 0 ] || { echo "::error::positive control $CONTROL had 0 AMX hits; the scan is broken"; exit 1; }
  echo "OK: positive control $(basename "$CONTROL") has $n AMX hit(s)."
fi
