#!/usr/bin/env bash
# iPhone guard for iPad support (runs on Linux or macOS, no Xcode). -Nova
# The owner's rule: no iPhone layout may change, and every iPad-only change sits behind an
# iPad + regular-width gate. The app's views can't build on Linux, so this pins, from source:
#   1. every numeric layout/motion token the iPhone path reads (ios/AeroDJ and
#      AeroDJCore/Studio), against iphone-compact-path.golden;
#   2. the iPhone bodies of gated views, byte for byte (sha256 of the pre-iPad body);
#   3. the gate itself: LayoutMetrics is iPad AND regular, SwiftUI's size class and the
#      device idiom map the safe way, and the app reads it only in the allowed gated forms;
#   4. the size-class routing lines the iPhone path depends on.
# A failure means an iPhone layout may have moved. Changing the golden needs the owner's OK:
#   ios/scripts/check-iphone-compact-path.sh --print > ios/scripts/iphone-compact-path.golden
# Usage: check-iphone-compact-path.sh [--print] [ios dir]
set -euo pipefail
print=0
if [ "${1:-}" = "--print" ]; then print=1; shift; fi
IOS="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
GOLDEN="$(cd "$(dirname "$0")" && pwd)/iphone-compact-path.golden"
cd "$IOS"
fail=0
err() { echo "::error::iPhone guard: $*"; fail=1; }

# 1. Tokens. "file name = value", sorted; line numbers left out so moving code is fine.
tokens() {
  grep -rnoE --include='*.swift' 'static let [A-Za-z_]+: (CGFloat|Double) = -?[0-9][0-9_.]*' \
    AeroDJ AeroDJCore/Sources/AeroDJCore/Studio \
    | grep -v '^AeroDJCore/Sources/AeroDJCore/Studio/LayoutMetrics.swift:' \
    | sed -E 's/^([^:]+):[0-9]+:static let ([A-Za-z_]+): [A-Za-z]+ = (.*)$/\1 \2 = \3/' | LC_ALL=C sort
}
# 2. Pinned bodies: "file|struct|body opener|sha256 of the lines inside it".
#    StudioStackedLayout.phoneBody is the body StudioStackedLayout had at 6307545.
bodies='AeroDJ/StudioLayout.swift|StudioStackedLayout|    private var phoneBody: some View {|a3d5275f04381d9f6fb6ec08e344fe9ac990bbd8594b1ad5497de768e8abe2b9'
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }
body_sha() { # file struct opener
  awk -v s="struct $2: View {" -v o="$3" '$0==s{on=1} on && $0==o{b=1; next} b && /^    \}$/{exit} b' "$1" | sha256 | cut -d' ' -f1
}

if [ "$print" = 1 ]; then tokens; exit 0; fi

[ -f "$GOLDEN" ] || { err "missing $GOLDEN"; exit 1; }
if ! diff -u <(grep -v '^#' "$GOLDEN") <(tokens) >/tmp/iphone-guard.diff.$$; then
  cat /tmp/iphone-guard.diff.$$; err "an iPhone layout token changed, appeared or went away (diff above)"
fi
rm -f /tmp/iphone-guard.diff.$$
n=$(grep -vc '^#' "$GOLDEN"); [ "$n" -ge 40 ] || err "golden has only $n tokens (expected the full set)"

while IFS='|' read -r file st opener want; do
  got=$(body_sha "$file" "$st" "$opener")
  [ "$got" = "$want" ] || err "$st iPhone body in $file changed (sha $got, want $want)"
done <<<"$bodies"

# 3. The gate. Exact lines, so a dropped condition fails here as well as in the core tests.
need() { # file fixed-string why
  grep -qF -- "$2" "$1" || err "$1: missing \`$2\` ($3)"
}
LM=AeroDJCore/Sources/AeroDJCore/Studio/LayoutMetrics.swift
need "$LM" 'let iPadRegular = idiom == .pad && widthClass == .regular' 'iPad AND regular width'
need "$LM" 'readableMaxWidth = iPadRegular ? Self.iPadReadableMaxWidth : nil' 'nil off iPad-regular'
need "$LM" 'public var usesIPadLayout: Bool { readableMaxWidth != nil }' 'one source of truth'
[ "$(grep -c 'readableMaxWidth = ' "$LM")" = 1 ] || err "$LM assigns readableMaxWidth more than once"
IP=AeroDJ/IPadLayout.swift
need "$IP" 'UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone' 'only an iPad is .pad'
need "$IP" 'case .regular: self = .regular' 'size class mapping'
need "$IP" 'case .compact: self = .compact' 'size class mapping'
need "$IP" 'default: self = .unspecified' 'nil size class is never regular'
[ "$(grep -c 'self = .regular' "$IP")" = 1 ] || err "$IP maps more than one size class to .regular"
need "$IP" 'self.init(widthClass: LayoutWidthClass(horizontalSizeClass), idiom: .current)' 'real idiom'
# The app may read the gate only as `if let x = LayoutMetrics(horizontalSizeClass).readableMaxWidth {`
# or `if LayoutMetrics(horizontalSizeClass).usesIPadLayout {`, so the else branch is the
# iPhone path. Any other use (a bare value, a ternary, `?? 0`) fails.
uses=$(grep -rnE --include='*.swift' 'LayoutMetrics\(|readableMaxWidth|usesIPadLayout|LayoutIdiom|iPadReadableMaxWidth' AeroDJ \
  | grep -v '^AeroDJ/IPadLayout.swift:' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*///' \
  | grep -vE ':[0-9]+:[[:space:]]+if let [A-Za-z]+ = LayoutMetrics\(horizontalSizeClass\)\.readableMaxWidth \{$' \
  | grep -vE ':[0-9]+:[[:space:]]+if LayoutMetrics\(horizontalSizeClass\)\.usesIPadLayout \{$' || true)
[ -z "$uses" ] || err "ungated iPad value in the app (use the if-let gate):
$uses"
# Every gated view's else branch must be its pinned iPhone body.
need AeroDJ/StudioLayout.swift '            phoneBody' 'StudioStackedLayout else branch'
sl=$(awk '$0=="struct StudioStackedLayout: View {"{on=1} on && $0=="    var body: some View {"{b=1; next} b && /^    \}$/{exit} b' AeroDJ/StudioLayout.swift)
want_sl='        if let readableWidth = LayoutMetrics(horizontalSizeClass).readableMaxWidth {
            iPadBody(readableWidth: CGFloat(readableWidth))
        } else {
            phoneBody
        }'
[ "$sl" = "$want_sl" ] || err "StudioStackedLayout.body is not the iPad gate with phoneBody as the else branch:
$sl"

# 4. Routing the iPhone path depends on (unchanged by iPad support).
need AeroDJ/PlayingScreen.swift 'StudioLayoutMode.resolve(hasRegularWidth: horizontalSizeClass == .regular,' 'Studio needs regular width'
need AeroDJ/StationListView.swift 'horizontalSizeClass != .regular' 'compact or nil size class is the phone carousel'

[ "$fail" = 0 ] && echo "iPhone compact path OK ($n tokens, $(grep -c . <<<"$bodies") pinned body, gate intact)"
exit "$fail"
