#!/usr/bin/env bash
# Usage: check-owner-ab-build-settings.sh absent|present [extra xcodebuild settings...]
# Reads the real Release build settings (xcodebuild -showBuildSettings, macOS only) with
# the given extra settings and checks AERODJ_OWNER_AB in SWIFT_ACTIVE_COMPILATION_CONDITIONS.
# Run from the repo root (testflight.yml runs a copy taken before it checks out `ref`).
set -euo pipefail
expect="$1"; shift
case "$expect" in absent|present) ;; *) echo "usage: $0 absent|present [settings...]" >&2; exit 2 ;; esac
settings="$(xcodebuild -showBuildSettings \
  -project ios/AeroDJ.xcodeproj -scheme AeroDJ -configuration Release \
  -destination 'generic/platform=iOS' "$@" 2>/dev/null \
  | grep -E '^[[:space:]]*SWIFT_ACTIVE_COMPILATION_CONDITIONS = ' || true)"
[ -n "$settings" ] || { echo "::error::no SWIFT_ACTIVE_COMPILATION_CONDITIONS in Release build settings"; exit 1; }
echo "Release SWIFT_ACTIVE_COMPILATION_CONDITIONS:"; printf '%s\n' "$settings" | sort -u
if printf '%s\n' "$settings" | grep -qw AERODJ_OWNER_AB; then found=present; else found=absent; fi
if [ "$found" != "$expect" ]; then
  echo "::error::AERODJ_OWNER_AB is $found in Release build settings (expected $expect)"; exit 1
fi
echo "OK: AERODJ_OWNER_AB $expect"
