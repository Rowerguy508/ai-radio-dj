#!/usr/bin/env python3
"""Parse each PrivacyInfo.xcprivacy and assert that required-reason API
categories found in that target's sources are declared.

Tracking must be false, tracking domains empty. The app's collected-data
types must match the reviewed 2.0 set; extensions must declare none.

Extra declared reasons are allowed (so 1C8F.1 can land ahead of #485).
Uses plistlib, so it runs on Linux without plutil.

Usage:
  python3 ios/scripts/check-privacy-manifests.py
  python3 ios/scripts/check-privacy-manifests.py --self-test
"""
from __future__ import annotations

import argparse
import plistlib
import re
import shutil
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve()
IOS = SCRIPT.parent.parent

USERDEFAULTS = "NSPrivacyAccessedAPICategoryUserDefaults"
FILE_TIMESTAMP = "NSPrivacyAccessedAPICategoryFileTimestamp"
BOOT_TIME = "NSPrivacyAccessedAPICategorySystemBootTime"
DISK_SPACE = "NSPrivacyAccessedAPICategoryDiskSpace"
KEYBOARDS = "NSPrivacyAccessedAPICategoryActiveKeyboards"

# Minimum reasons that must be present even if a branch has not yet grown
# the matching call (widgets / app-group defaults land with #485).
PINNED_REASONS = {
    "AeroDJ": {
        USERDEFAULTS: {"CA92.1", "1C8F.1"},
        FILE_TIMESTAMP: {"C617.1"},
        BOOT_TIME: {"35F9.1"},
    },
    "AeroDJShare": {
        USERDEFAULTS: {"CA92.1"},
        FILE_TIMESTAMP: {"C617.1"},
    },
    "AeroDJWidgets": {
        USERDEFAULTS: {"1C8F.1"},
    },
}

# Source roots scanned for required-reason API use. The share extension
# links AeroDJCore, so Core is included there. Widgets are scanned alone:
# they only read NowPlayingDisplayStore (once #485 lands).
SCAN_ROOTS = {
    "AeroDJ": ["AeroDJ", "AeroDJCore/Sources"],
    "AeroDJShare": ["AeroDJShare", "AeroDJCore/Sources"],
    "AeroDJWidgets": ["AeroDJWidgets"],
}

SKIP_DIR_NAMES = {"Tests", "AeroDJCoreTests", "AeroDJUITests", "AeroDJStoreKitTests"}

APP_COLLECTED = [
    ("NSPrivacyCollectedDataTypeCoarseLocation", False),
    ("NSPrivacyCollectedDataTypeEmailsOrTextMessages", True),
    ("NSPrivacyCollectedDataTypeOtherUserContent", True),
    ("NSPrivacyCollectedDataTypeDeviceID", False),
    ("NSPrivacyCollectedDataTypeProductInteraction", True),
]

COMMENT_LINE = re.compile(r"//.*?$", re.MULTILINE)
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)

SUITE_GROUP = re.compile(
    r"UserDefaults\s*\(\s*suiteName:\s*(?:NowPlayingDisplayStore\.appGroupID|"
    r"\"group\.[^\"]+\"|[A-Za-z0-9_.]*appGroupID)",
    re.MULTILINE,
)


def strip_comments(src: str) -> str:
    return COMMENT_LINE.sub("", BLOCK_COMMENT.sub("", src))


def swift_files(root: Path) -> list[Path]:
    if not root.exists():
        return []
    files = []
    for path in root.rglob("*.swift"):
        if any(part in SKIP_DIR_NAMES for part in path.parts):
            continue
        if path.name.endswith("Tests.swift") or path.name.endswith("Test.swift"):
            continue
        files.append(path)
    return files


def scan_categories(roots: list[Path]) -> dict[str, set[str]]:
    """Map accessed API category -> reasons implied by the source."""
    found: dict[str, set[str]] = {}
    text = ""
    for root in roots:
        for path in swift_files(root):
            text += "\n" + strip_comments(path.read_text(encoding="utf-8", errors="replace"))

    def add(category: str, reason: str) -> None:
        found.setdefault(category, set()).add(reason)

    if re.search(r"\bUserDefaults\b|@AppStorage\b", text):
        add(USERDEFAULTS, "CA92.1")
    if SUITE_GROUP.search(text) or re.search(
        r"suiteName:\s*NowPlayingDisplayStore\.appGroupID", text
    ):
        add(USERDEFAULTS, "1C8F.1")
    if re.search(
        r"\battributesOfItem\b|contentModificationDateKey|creationDateKey|"
        r"contentModificationDate|fileModificationDate|"
        r"NSURLContentModificationDateKey|NSURLCreationDateKey",
        text,
    ):
        add(FILE_TIMESTAMP, "C617.1")
    if re.search(r"ProcessInfo[^\n]{0,40}systemUptime|\bmach_absolute_time\b|\bkern\.boottime\b", text):
        add(BOOT_TIME, "35F9.1")
    if re.search(
        r"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|"
        r"NSURLVolumeAvailableCapacity|\bstatfs\s*\(|\bstatvfs\s*\(",
        text,
    ):
        add(DISK_SPACE, "E174.1")  # placeholder; a hit must be reviewed before shipping
    if re.search(r"\bactiveInputModes\b|\bUITextInputMode\b", text):
        add(KEYBOARDS, "54BD.1")  # placeholder; a hit must be reviewed before shipping
    return found


def load_manifest(path: Path) -> dict:
    with path.open("rb") as fh:
        return plistlib.load(fh)


def declared_reasons(manifest: dict) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for entry in manifest.get("NSPrivacyAccessedAPITypes") or []:
        category = entry.get("NSPrivacyAccessedAPIType")
        reasons = set(entry.get("NSPrivacyAccessedAPITypeReasons") or [])
        if category:
            out[category] = reasons
    return out


def collected_tuples(manifest: dict) -> list[tuple[str, bool, bool, list[str]]]:
    rows = []
    for entry in manifest.get("NSPrivacyCollectedDataTypes") or []:
        rows.append(
            (
                entry.get("NSPrivacyCollectedDataType"),
                bool(entry.get("NSPrivacyCollectedDataTypeLinked")),
                bool(entry.get("NSPrivacyCollectedDataTypeTracking")),
                list(entry.get("NSPrivacyCollectedDataTypePurposes") or []),
            )
        )
    return rows


def check_target(target: str, ios: Path, errors: list[str]) -> None:
    path = ios / target / "PrivacyInfo.xcprivacy"
    try:
        manifest = load_manifest(path)
    except (OSError, plistlib.InvalidFileException) as exc:
        errors.append(f"{path}: {exc}")
        return

    if manifest.get("NSPrivacyTracking") is not False:
        errors.append(f"{path}: NSPrivacyTracking must be false")
    if manifest.get("NSPrivacyTrackingDomains") not in ([], None):
        errors.append(f"{path}: NSPrivacyTrackingDomains must be empty")

    declared = declared_reasons(manifest)
    pinned = PINNED_REASONS[target]
    for category, reasons in pinned.items():
        have = declared.get(category, set())
        missing = reasons - have
        if missing:
            errors.append(f"{path}: {category} missing reasons {sorted(missing)} (have {sorted(have)})")

    roots = [ios / rel for rel in SCAN_ROOTS[target]]
    scanned = scan_categories(roots)
    for category, reasons in scanned.items():
        have = declared.get(category, set())
        missing = reasons - have
        if missing:
            errors.append(
                f"{path}: grep found {category} reasons {sorted(reasons)} but the manifest has {sorted(have)}"
            )

    collected = collected_tuples(manifest)
    if target == "AeroDJ":
        expected = [
            (name, linked, False, ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
            for name, linked in APP_COLLECTED
        ]
        if collected != expected:
            errors.append(f"{path}: collected data types {collected} != reviewed {expected}")
    elif collected:
        errors.append(f"{path}: NSPrivacyCollectedDataTypes must be empty (extension does not collect)")


def run(ios: Path) -> list[str]:
    errors: list[str] = []
    for target in PINNED_REASONS:
        check_target(target, ios, errors)
    return errors


def self_test(ios: Path) -> list[str]:
    """Copy the tree's manifests, drop CA92.1 from the app, and expect a failure."""
    errors: list[str] = []
    baseline = run(ios)
    if baseline:
        errors.append("self-test: baseline check failed, not mutating:\n  " + "\n  ".join(baseline))
        return errors
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "ios"
        shutil.copytree(ios, dest, ignore=shutil.ignore_patterns(".build", "*.xcodeproj"))
        path = dest / "AeroDJ" / "PrivacyInfo.xcprivacy"
        manifest = load_manifest(path)
        for entry in manifest.get("NSPrivacyAccessedAPITypes") or []:
            if entry.get("NSPrivacyAccessedAPIType") == USERDEFAULTS:
                entry["NSPrivacyAccessedAPITypeReasons"] = ["1C8F.1"]
        with path.open("wb") as fh:
            plistlib.dump(manifest, fh)
        mutated = run(dest)
        if not any("CA92.1" in item for item in mutated):
            errors.append(
                "self-test: expected a CA92.1 failure after removing it from the app manifest, got: "
                + (repr(mutated) if mutated else "no errors")
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--ios-root", type=Path, default=IOS)
    args = parser.parse_args()
    ios = args.ios_root.resolve()
    errors = self_test(ios) if args.self_test else run(ios)
    for item in errors:
        print(f"error: {item}", file=sys.stderr)
    if errors:
        return 1
    if args.self_test:
        print("privacy manifest self-test OK")
    else:
        print("privacy manifests OK: " + ", ".join(PINNED_REASONS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
