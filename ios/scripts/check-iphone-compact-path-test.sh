#!/usr/bin/env bash
# Mutation tests for check-iphone-compact-path.sh (Linux or macOS). Each mutant edits a temp
# copy of ios/ the way a careless iPad change could move the iPhone layout; the guard must
# fail on every one and pass on the untouched copy. -Nova
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
IOS=$(cd "$SCRIPT_DIR/.." && pwd)
GUARD="$SCRIPT_DIR/check-iphone-compact-path.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; bad=0

fresh() {
  rm -rf "$tmp/ios"; mkdir -p "$tmp/ios/AeroDJCore"
  cp -R "$IOS/AeroDJ" "$tmp/ios/"; cp -R "$IOS/AeroDJCore/Sources" "$tmp/ios/AeroDJCore/"
}
# mutant NAME FILE PERL-SUBSTITUTION: the substitution must change the file.
mutant() {
  fresh
  local f="$tmp/ios/$2"; cp "$f" "$tmp/before"
  perl -0pi -e "$3" "$f"
  if cmp -s "$f" "$tmp/before"; then echo "BROKEN TEST: $1 did not change $2"; bad=$((bad+1)); return; fi
  if bash "$GUARD" "$tmp/ios" >"$tmp/out" 2>&1; then
    echo "SURVIVED: $1"; bad=$((bad+1))
  else
    echo "killed: $1 ($(grep -m1 '::error::' "$tmp/out" | cut -c1-110))"; pass=$((pass+1))
  fi
}

fresh
if bash "$GUARD" "$tmp/ios" >"$tmp/out" 2>&1; then echo "control passes"; pass=$((pass+1)); else cat "$tmp/out"; echo "control FAILED"; bad=$((bad+1)); fi

# Compact-path values.
mutant "FoldedStyle.contentInset 32->24"        AeroDJ/FoldedPlayer.swift          's/static let contentInset: CGFloat = 32/static let contentInset: CGFloat = 24/'
mutant "scrubber thumb 12->14"                  AeroDJ/PlaybackComponents.swift    's/static let thumbSize: CGFloat = 12/static let thumbSize: CGFloat = 14/'
mutant "StudioLayoutMetrics.edgeInset 16->20"   AeroDJCore/Sources/AeroDJCore/Studio/StudioScreenPresentation.swift 's/static let edgeInset: Double = 16/static let edgeInset: Double = 20/'
mutant "FoldedColumnLayout.columnMaxWidth 560->640" AeroDJCore/Sources/AeroDJCore/Studio/FoldedColumnLayout.swift 's/columnMaxWidth: Double = 560/columnMaxWidth: Double = 640/'
mutant "token removed"                          AeroDJ/FoldedPlayer.swift          's/    static let artMinSide: CGFloat = 140\n//'
mutant "iPhone body edited"                     AeroDJ/StudioLayout.swift          's/(private var phoneBody: some View \{\n        ScrollView \{\n            VStack\(spacing: 0\) \{\n)/$1                Color.clear.frame(height: 0)\n/'
mutant "iPhone body padding 12->16"             AeroDJ/StudioLayout.swift          's/(private var phoneBody[\s\S]*?)\.padding\(\.bottom, 12\)/$1.padding(.bottom, 16)/'
# Gates.
mutant "size-class gate removed (core)"         AeroDJCore/Sources/AeroDJCore/Studio/LayoutMetrics.swift 's/idiom == \.pad && widthClass == \.regular/idiom == .pad/'
mutant "idiom gate removed (core)"              AeroDJCore/Sources/AeroDJCore/Studio/LayoutMetrics.swift 's/idiom == \.pad && widthClass == \.regular/widthClass == .regular/'
mutant "gate || instead of &&"                  AeroDJCore/Sources/AeroDJCore/Studio/LayoutMetrics.swift 's/idiom == \.pad && widthClass == \.regular/idiom == .pad || widthClass == .regular/'
mutant "value off the gate"                     AeroDJCore/Sources/AeroDJCore/Studio/LayoutMetrics.swift 's/iPadRegular \? Self\.iPadReadableMaxWidth : nil/Self.iPadReadableMaxWidth/'
mutant "every device is an iPad"                AeroDJ/IPadLayout.swift            's/== \.pad \? \.pad : \.phone/!= .mac ? .pad : .phone/'
mutant "nil size class counts as regular"       AeroDJ/IPadLayout.swift            's/default: self = \.unspecified/default: self = .regular/'
mutant "compact counts as regular"              AeroDJ/IPadLayout.swift            's/case \.compact: self = \.compact/case .compact: self = .regular/'
mutant "idiom hard-coded to .pad"               AeroDJ/IPadLayout.swift            's/idiom: \.current\)/idiom: .pad)/'
mutant "view gate bypassed"                     AeroDJ/StudioLayout.swift          's/        if let readableWidth = LayoutMetrics\(horizontalSizeClass\)\.readableMaxWidth \{\n            iPadBody\(readableWidth: CGFloat\(readableWidth\)\)\n        \} else \{\n            phoneBody\n        \}/        iPadBody(readableWidth: 640)/'
mutant "view else branch swapped"               AeroDJ/StudioLayout.swift          's/        \} else \{\n            phoneBody\n/        } else {\n            iPadBody(readableWidth: 640)\n/'
mutant "ungated iPad value in a view"           AeroDJ/PlayingScreen.swift         's/(\.accessibilityIdentifier\("layout\.compact"\))/$1\n                .frame(maxWidth: LayoutMetrics(horizontalSizeClass).readableMaxWidth.map { CGFloat(\$0) } ?? .infinity)/'
mutant "Studio routing loses the regular gate"  AeroDJ/PlayingScreen.swift         's/hasRegularWidth: horizontalSizeClass == \.regular,/hasRegularWidth: horizontalSizeClass != .compact,/'
mutant "station list compact rule changed"      AeroDJ/StationListView.swift       's/horizontalSizeClass != \.regular/horizontalSizeClass == .compact/'

echo "check-iphone-compact-path-test: $pass ok, $bad failed"
[ "$bad" = 0 ]
