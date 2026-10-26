#!/usr/bin/env bash
# Scan a built AeroDJ.app and its embedded share extension for fixture tokens.
#
# Usage: check-release-bundle-fixtures.sh <Debug AeroDJ.app> <Release AeroDJ.app>
#
# Tokens: ios/scripts/release-fixture-denylist.txt
# Mach-O executables are read with nm (demangled when swift-demangle is present)
# and strings. Every other file in the bundle, including compiled asset catalogs
# and Info.plists, is an asset: its path and its strings are checked.
# The Debug app executable is the positive control. Release must have no hits.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <Debug AeroDJ.app> <Release AeroDJ.app>" >&2
  exit 2
fi

DEBUG_APP=$1
RELEASE_APP=$2
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DENYLIST="$SCRIPT_DIR/release-fixture-denylist.txt"
PATFILE=$(mktemp)
HITS=$(mktemp)
debug_hits=$(mktemp)
release_hits=$(mktemp)
trap 'rm -f "$PATFILE" "$HITS" "$debug_hits" "$release_hits"' EXIT

grep -E -v '^[[:space:]]*(#|$)' "$DENYLIST" > "$PATFILE"
[[ -s "$PATFILE" ]] || { echo "FAIL: denylist is empty: $DENYLIST"; exit 1; }
for required in FixtureContextSource PlayingScreenPreviewLoader mockStations; do
  grep -q -x -F -- "$required" "$PATFILE" || { echo "FAIL: denylist is missing $required"; exit 1; }
done

demangle() {
  if command -v xcrun >/dev/null 2>&1 && xcrun --find swift-demangle >/dev/null 2>&1; then
    xcrun swift-demangle
  elif command -v swift >/dev/null 2>&1; then
    swift demangle
  else
    cat
  fi
}

is_macho() {
  file "$1" 2>/dev/null | grep -q 'Mach-O'
}

# Bundle-relative executable name from Info.plist, else the bundle's own name.
executable_rel() {
  local bundle=$1 plist name
  plist=$bundle/Info.plist
  if [[ -f "$plist" && -x /usr/libexec/PlistBuddy ]]; then
    name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)
    if [[ -n "$name" ]]; then
      printf '%s\n' "$name"
      return
    fi
  fi
  name=$(basename "$bundle")
  name=${name%.app}
  name=${name%.appex}
  printf '%s\n' "$name"
}

appex_dirs() {
  local app=$1
  [[ -d "$app/PlugIns" ]] || return 0
  find "$app/PlugIns" -name '*.appex' -type d
}

record_file() {
  local root=$1 file=$2 kind=$3 rel text pat
  rel=${file#"$root"/}
  text=$(mktemp)
  if is_macho "$file"; then
    { nm -a "$file" 2>/dev/null || true; } | demangle >> "$text" || true
  fi
  { strings -a "$file" 2>/dev/null || true; } >> "$text" || true
  while IFS= read -r pat; do
    if grep -q -F -- "$pat" "$text" || [[ "$rel" == *"$pat"* ]]; then
      printf '%s %s %s\n' "$kind" "$rel" "$pat" >> "$HITS"
    fi
  done < "$PATFILE"
  rm -f "$text"
}

scan_bundle() {
  local app=$1 label=$2
  local -a exes=()
  local exe appex appex_exe file skip known
  [[ -d "$app" ]] || { echo "FAIL: $label app not found: $app"; exit 1; }
  exe=$app/$(executable_rel "$app")
  # An appex fallback above returns the .appex directory name. Prefer Info.plist.
  if [[ ! -f "$exe" && -f "$app/$(basename "$app" .app)" ]]; then
    exe=$app/$(basename "$app" .app)
  fi
  [[ -f "$exe" ]] || { echo "FAIL: $label executable not found: $exe"; exit 1; }
  exes+=("$exe")

  if [[ -z "$(appex_dirs "$app")" ]]; then
    echo "FAIL: $label app has no embedded share extension (.appex)"
    exit 1
  fi
  while IFS= read -r appex; do
    appex_exe=$appex/$(executable_rel "$appex")
    if [[ ! -f "$appex_exe" ]]; then
      appex_exe=$appex/$(basename "$appex" .appex)
    fi
    [[ -f "$appex_exe" ]] || { echo "FAIL: $label share executable not found: $appex_exe"; exit 1; }
    exes+=("$appex_exe")
  done < <(appex_dirs "$app")

  for exe in "${exes[@]}"; do
    record_file "$app" "$exe" symbol
  done
  while IFS= read -r file; do
    skip=0
    for known in "${exes[@]}"; do
      [[ "$file" == "$known" ]] && skip=1
    done
    [[ "$skip" -eq 1 ]] && continue
    record_file "$app" "$file" asset
  done < <(find "$app" -type f)
}

scan_into() {
  local dest=$1
  : > "$HITS"
  scan_bundle "$2" "$3"
  sort -u "$HITS" > "$dest"
}

scan_into "$debug_hits" "$DEBUG_APP" Debug
debug_rel=$(executable_rel "$DEBUG_APP")
missing=
for required in PlayingScreenPreviewLoader mockStations; do
  if ! grep -q -x -F -- "symbol ${debug_rel} ${required}" "$debug_hits"; then
    missing="$missing $required"
  fi
done
if [[ -n "$missing" ]]; then
  echo "FAIL: control: Debug app executable is missing:$missing"
  echo "The scan cannot pass until those symbols are visible in the Debug build."
  cat "$debug_hits"
  exit 1
fi

scan_into "$release_hits" "$RELEASE_APP" Release
if [[ -s "$release_hits" ]]; then
  echo "FAIL: Release bundle contains fixture symbols or assets"
  cat "$release_hits"
  exit 1
fi

echo "OK: Release app and share extension exclude the fixture denylist"
