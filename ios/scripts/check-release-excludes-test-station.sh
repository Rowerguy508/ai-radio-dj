#!/usr/bin/env bash
# Fails if a dead-stripped Release executable linked against AeroDJCore contains
# a token from ios/scripts/release-fixture-denylist.txt.
#
# Object files are not scanned. SwiftPM's Release link keeps the objects the
# linker cannot drop (--gc-sections on Linux, the platform dead-strip on
# Apple) and drops the rest. The host calls AppRuntimeMode.resolve, the same
# AeroDJCore rule the app uses, so the binary is a real link of the library
# and not an empty stub.
#
# Raw bytes are scanned. A token immediately preceded by "/" and immediately
# followed by ".swift" is a source path left in the linked image (the file
# name survives after the type is compiled out). That form is exempt in the
# raw bytes only. Demangled `nm -a` output is a separate input: Swift word
# substitution can hide a name from the raw symbol, and a token there fails
# even when the text looks like a path.
#
# Positive control: the Debug executable must still contain FixtureContextSource
# as a real match, so a broken scan or an empty denylist cannot pass.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DENYLIST="$SCRIPT_DIR/release-fixture-denylist.txt"
MATCH="$SCRIPT_DIR/fixture-scan-match.py"
# shellcheck source=fixture-scan-symbols.sh
source "$SCRIPT_DIR/fixture-scan-symbols.sh"
CORE=$(cd "$SCRIPT_DIR/../AeroDJCore" && pwd)

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required to scan fixture bytes"; exit 1; }
command -v nm >/dev/null 2>&1 || { echo "FAIL: nm is required to scan the linked executable"; exit 1; }
[[ -f "$MATCH" ]] || { echo "FAIL: matcher missing: $MATCH"; exit 1; }

grep -E -v '^[[:space:]]*(#|$)' "$DENYLIST" | grep -q . || { echo "FAIL: denylist is empty: $DENYLIST"; exit 1; }
grep -E -v '^[[:space:]]*(#|$)' "$DENYLIST" | grep -q -x -F -- 'FixtureContextSource' || {
  echo "FAIL: denylist is missing FixtureContextSource"
  exit 1
}

host=$(mktemp -d)
trap 'rm -rf "$host"' EXIT
mkdir -p "$host/Sources/AeroDJCoreReleaseLink"
cat > "$host/Package.swift" << EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AeroDJCoreReleaseLink",
    dependencies: [
        .package(path: "$CORE"),
    ],
    targets: [
        .executableTarget(
            name: "AeroDJCoreReleaseLink",
            dependencies: [
                .product(name: "AeroDJCore", package: "AeroDJCore"),
            ]
        ),
    ]
)
EOF
cat > "$host/Sources/AeroDJCoreReleaseLink/main.swift" << 'EOF'
import AeroDJCore

@main
enum AeroDJCoreReleaseLink {
    static func main() {
        let mode = AppRuntimeMode.resolve(testStationFlag: false, allowsTestStation: false)
        print(mode.rawValue)
    }
}
EOF

swift build -c debug --package-path "$host" >/dev/null
debug_bin=$(swift build -c debug --package-path "$host" --show-bin-path)
debug_exe="$debug_bin/AeroDJCoreReleaseLink"
[[ -f "$debug_exe" ]] || { echo "FAIL: Debug linked executable not found: $debug_exe"; exit 1; }
debug_symbols="$host/debug-symbols.txt"
if ! fixture_nm_demangle "$debug_exe" "$debug_symbols"; then
  echo "FAIL: could not demangle the Debug linked executable"
  exit 1
fi
[[ -s "$debug_symbols" ]] || { echo "FAIL: Debug linked executable has no symbols"; exit 1; }
debug_hits=$(python3 "$MATCH" "$DENYLIST" "$debug_exe" "$(basename "$debug_exe")" "$debug_symbols")
if ! grep -q -x -F -- 'FixtureContextSource' <<< "$debug_hits"; then
  echo "FAIL: control: FixtureContextSource not found in the Debug linked executable"
  printf '%s\n' "$debug_hits"
  exit 1
fi

swift build -c release --package-path "$host" >/dev/null
release_bin=$(swift build -c release --package-path "$host" --show-bin-path)
release_exe="$release_bin/AeroDJCoreReleaseLink"
[[ -f "$release_exe" ]] || { echo "FAIL: Release linked executable not found: $release_exe"; exit 1; }
# AppRuntimeMode is not on the denylist. Its presence proves AeroDJCore was linked.
if ! grep -a -q -F -- 'AppRuntimeMode' "$release_exe"; then
  echo "FAIL: control: Release executable does not contain AeroDJCore (AppRuntimeMode)"
  exit 1
fi
release_symbols="$host/release-symbols.txt"
if ! fixture_nm_demangle "$release_exe" "$release_symbols"; then
  echo "FAIL: could not demangle the Release linked executable"
  exit 1
fi
[[ -s "$release_symbols" ]] || { echo "FAIL: Release linked executable has no symbols"; exit 1; }

release_hits=$(python3 "$MATCH" "$DENYLIST" "$release_exe" "$(basename "$release_exe")" "$release_symbols")
if [[ -n "$release_hits" ]]; then
  echo "FAIL: fixture patterns in the Release linked executable"
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    printf 'symbol %s %s\n' "$release_exe" "$token"
  done <<< "$release_hits"
  exit 1
fi
echo "OK: Release linked executable excludes the fixture denylist"
