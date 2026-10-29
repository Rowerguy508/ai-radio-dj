#!/usr/bin/env bash
# Usage: check-owner-ab-build-settings.sh absent|present [extra xcodebuild settings...]
# Reads the real Release build settings (xcodebuild -showBuildSettings, macOS only) with
# the given extra settings and checks AERODJ_OWNER_AB in SWIFT_ACTIVE_COMPILATION_CONDITIONS.
# Run from the repo root (testflight.yml runs a copy taken before it checks out `ref`).
set -euo pipefail
expect="$1"; shift
case "$expect" in absent|present) ;; *) echo "usage: $0 absent|present [settings...]" >&2; exit 2 ;; esac
# Keep xcodebuild's stderr so a failed read is visible instead of looking like "no flag".
if ! all="$(xcodebuild -showBuildSettings \
  -project ios/AeroDJ.xcodeproj -scheme AeroDJ -configuration Release \
  -destination 'generic/platform=iOS' "$@" 2>&1)"; then
  printf '%s\n' "$all" | tail -40 >&2
  echo "::error::xcodebuild -showBuildSettings failed for Release"; exit 1
fi
# Positive control: we really read the AeroDJ app target's Release settings.
printf '%s\n' "$all" | grep -qE '^[[:space:]]*CONFIGURATION = Release$' \
  && printf '%s\n' "$all" | grep -qE '^[[:space:]]*TARGET_NAME = AeroDJ$' \
  || { printf '%s\n' "$all" | tail -40 >&2; echo "::error::could not read the AeroDJ Release build settings"; exit 1; }
# A plain Release sets no compilation conditions, and xcodebuild omits an empty setting,
# so a missing line means "no conditions" (absent). `present` still needs the flag itself.
settings="$(printf '%s\n' "$all" | grep -E '^[[:space:]]*SWIFT_ACTIVE_COMPILATION_CONDITIONS =' || true)"
[ -n "$settings" ] || settings="SWIFT_ACTIVE_COMPILATION_CONDITIONS = (not set)"
echo "Release SWIFT_ACTIVE_COMPILATION_CONDITIONS:"; printf '%s\n' "$settings" | sort -u
if printf '%s\n' "$settings" | grep -qw AERODJ_OWNER_AB; then found=present; else found=absent; fi
if [ "$found" != "$expect" ]; then
  echo "::error::AERODJ_OWNER_AB is $found in Release build settings (expected $expect)"; exit 1
fi
echo "OK: AERODJ_OWNER_AB $expect"
