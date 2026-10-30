#!/usr/bin/env python3
"""Fail if a target's PrivacyInfo.xcprivacy is missing, does not parse, or drifts from
onairly.app/privacy (docs/site/privacy.md): no tracking, no tracking domains, no collected
data, and only the required-reason categories and codes reviewed in #333."""
import plistlib
import sys
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
EXPECTED = {
    "AeroDJ": {
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
    },
    "AeroDJShare": {
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
    },
}

errors = []
for target, apis in EXPECTED.items():
    path = IOS / target / "PrivacyInfo.xcprivacy"
    try:
        with path.open("rb") as f:
            manifest = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException) as exc:
        errors.append(f"{path}: {exc}")
        continue
    if manifest.get("NSPrivacyTracking") is not False:
        errors.append(f"{path}: NSPrivacyTracking must be false")
    if manifest.get("NSPrivacyTrackingDomains") != []:
        errors.append(f"{path}: NSPrivacyTrackingDomains must be empty")
    if manifest.get("NSPrivacyCollectedDataTypes") != []:
        errors.append(f"{path}: NSPrivacyCollectedDataTypes must be empty (privacy policy: no data collected)")
    declared = {
        entry.get("NSPrivacyAccessedAPIType"): sorted(entry.get("NSPrivacyAccessedAPITypeReasons", []))
        for entry in manifest.get("NSPrivacyAccessedAPITypes", [])
    }
    if declared != {k: sorted(v) for k, v in apis.items()}:
        errors.append(f"{path}: accessed API types {declared} != reviewed {apis}")

for e in errors:
    print(f"error: {e}", file=sys.stderr)
if errors:
    sys.exit(1)
print("privacy manifests OK: " + ", ".join(EXPECTED))
