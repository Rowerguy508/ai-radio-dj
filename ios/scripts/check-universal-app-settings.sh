#!/usr/bin/env bash
# Static iPad-support check of the sources of truth (runs on Linux or macOS, no Xcode).
# The AeroDJ app is universal: TARGETED_DEVICE_FAMILY "1,2" in project.yml, all four iPad
# orientations, no UIRequiresFullScreen opt-out (Split View / Slide Over stay available), and
# a single-size universal 1024 icon. CI also checks the built Info.plist (simulator-build).
# Usage: ios/scripts/check-universal-app-settings.sh [ios dir]   -Nova
set -euo pipefail
IOS="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
YML="$IOS/project.yml"
PLIST="$IOS/AeroDJ/Info.plist"
ICON="$IOS/AeroDJ/Assets.xcassets/AppIcon.appiconset/Contents.json"
fail=0
err() { echo "::error::$*"; fail=1; }

# The AeroDJ target block: from "  AeroDJ:" to the next two-space-indented target name.
app="$(awk '/^  AeroDJ:$/{on=1; next} on && /^  [A-Za-z][A-Za-z0-9_]*:$/{on=0} on' "$YML")"
[ -n "$app" ] || err "no AeroDJ target in $YML"

fam="$(grep -E '^[[:space:]]+TARGETED_DEVICE_FAMILY:' <<<"$app" || true)"
[ "$(grep -c . <<<"$fam")" = 1 ] || err "AeroDJ must set TARGETED_DEVICE_FAMILY exactly once (found: ${fam:-none})"
grep -qE '^[[:space:]]+TARGETED_DEVICE_FAMILY:[[:space:]]*"1,2"[[:space:]]*(#.*)?$' <<<"$fam" \
  || err "AeroDJ TARGETED_DEVICE_FAMILY must be \"1,2\" (found: ${fam:-none})"
# No per-config override anywhere in the project (base must be what every config gets).
if grep -nE 'TARGETED_DEVICE_FAMILY' "$YML" | grep -vE '^[0-9]+:[[:space:]]+TARGETED_DEVICE_FAMILY:[[:space:]]*"1,2"' >/dev/null; then
  err "another TARGETED_DEVICE_FAMILY in $YML: $(grep -nE 'TARGETED_DEVICE_FAMILY' "$YML" | tr '\n' ' ')"
fi
for f in "$IOS"/Config/*.xcconfig; do
  [ -e "$f" ] || continue
  grep -q 'TARGETED_DEVICE_FAMILY' "$f" && err "$f overrides TARGETED_DEVICE_FAMILY"
done

ipad="$(grep -E '^[[:space:]]+INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad:' <<<"$app" || true)"
for o in Portrait PortraitUpsideDown LandscapeLeft LandscapeRight; do
  grep -qw "UIInterfaceOrientation$o" <<<"$ipad" || err "iPad orientations miss UIInterfaceOrientation$o"
done

grep -q 'UIRequiresFullScreen' "$PLIST" && err "UIRequiresFullScreen in $PLIST (iPad multitasking must stay on)"
grep -q 'UIRequiresFullScreen' <<<"$app" && err "UIRequiresFullScreen set in project.yml"

grep -q '"idiom"[[:space:]]*:[[:space:]]*"universal"' "$ICON" && grep -q '"size"[[:space:]]*:[[:space:]]*"1024x1024"' "$ICON" \
  || err "AppIcon is not a universal 1024x1024 icon"

[ "$fail" = 0 ] && echo "universal app settings OK (TARGETED_DEVICE_FAMILY 1,2; 4 iPad orientations; multitasking on; universal icon)"
exit "$fail"
