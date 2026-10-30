#!/usr/bin/env python3
"""Privacy manifest check for a built AeroDJ.app and its share extension (ITMS-91053).

Usage: check-privacy-manifests.py <path/to/AeroDJ.app> [--label CONFIG]

For the app and every PlugIns/*.appex it fails (exit 1, ::error:: lines) when:
  - PrivacyInfo.xcprivacy is missing or doesn't parse;
  - it declares tracking, a tracking domain or a tracking data type;
  - an NSPrivacyAccessedAPITypes entry has an unknown category, a duplicate category, no
    reasons, or a reason code that isn't a first-party code for that category;
  - the bundle's executable (or its Debug <exe>.debug.dylib) references a required-reason
    API whose category the manifest doesn't declare. Apple scans each bundle's binary, so
    code statically linked from AeroDJCore counts for the extension too;
  - UserDefaults(suiteName:) is referenced without 1C8F.1 (App Group defaults).
The app manifest must also keep exactly one Device ID row (#277 installId): not linked,
not tracking, App Functionality only.

Reason codes: developer.apple.com/documentation/bundleresources/app-privacy-configuration/
nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons. Third-party-SDK-only codes
(0A2A.1, C56D.1) are not allowed here. -Sentinel
"""
import os
import plistlib
import sys

# First-party reason codes per category (Apple's NSPrivacyAccessedAPITypeReasons list).
ALLOWED = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "AC6B.1"},
}

# Byte strings in a compiled binary (ObjC class/selector names, imported symbols) that mean
# the bundle uses an API in that category. The stat() family is left out: too generic to
# grep reliably in a Mach-O.
NEEDLES = {
    "NSPrivacyAccessedAPICategoryUserDefaults": [b"NSUserDefaults"],
    "NSPrivacyAccessedAPICategoryFileTimestamp": [
        b"attributesOfItemAtPath", b"NSFileModificationDate", b"NSFileCreationDate",
        b"NSURLContentModificationDateKey", b"NSURLCreationDateKey", b"getattrlist",
    ],
    "NSPrivacyAccessedAPICategorySystemBootTime": [b"systemUptime", b"mach_absolute_time"],
    "NSPrivacyAccessedAPICategoryDiskSpace": [
        b"NSURLVolumeAvailableCapacity", b"NSURLVolumeTotalCapacityKey", b"NSFileSystemFreeSize",
        b"NSFileSystemSize", b"statfs", b"statvfs",
    ],
    "NSPrivacyAccessedAPICategoryActiveKeyboards": [b"activeInputModes"],
}
APP_GROUP_DEFAULTS = b"initWithSuiteName"

errors = []


def err(msg):
    errors.append(msg)
    print(f"::error::{msg}")


def binaries(bundle):
    info_path = os.path.join(bundle, "Info.plist")
    with open(info_path, "rb") as f:
        exe = plistlib.load(f)["CFBundleExecutable"]
    paths = [os.path.join(bundle, exe)]
    debug = os.path.join(bundle, exe + ".debug.dylib")  # Xcode Debug builds (ENABLE_DEBUG_DYLIB)
    if os.path.exists(debug):
        paths.append(debug)
    return paths


def check_bundle(bundle, label, is_app):
    name = os.path.basename(bundle.rstrip("/"))
    where = f"{label}: {name}"
    path = os.path.join(bundle, "PrivacyInfo.xcprivacy")
    if not os.path.isfile(path):
        err(f"{where}: PrivacyInfo.xcprivacy missing")
        return
    try:
        with open(path, "rb") as f:
            m = plistlib.load(f)
    except Exception as e:  # noqa: BLE001
        err(f"{where}: PrivacyInfo.xcprivacy does not parse ({e})")
        return

    if m.get("NSPrivacyTracking") is not False:
        err(f"{where}: NSPrivacyTracking must be false")
    if m.get("NSPrivacyTrackingDomains", []) != []:
        err(f"{where}: lists a tracking domain")
    collected = m.get("NSPrivacyCollectedDataTypes", [])
    if any(t.get("NSPrivacyCollectedDataTypeTracking") is not False for t in collected):
        err(f"{where}: a collected data type is tracking (or missing the Tracking key)")

    declared = {}
    for entry in m.get("NSPrivacyAccessedAPITypes", []):
        cat = entry.get("NSPrivacyAccessedAPIType")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        if cat not in ALLOWED:
            err(f"{where}: unknown required-reason category {cat!r}")
            continue
        if cat in declared:
            err(f"{where}: {cat} declared twice")
        if not isinstance(reasons, list) or not reasons:
            err(f"{where}: {cat} has no reasons")
            reasons = []
        bad = [r for r in reasons if r not in ALLOWED[cat]]
        if bad:
            err(f"{where}: {cat} has reason codes not valid for this category: {bad}")
        declared[cat] = set(reasons)

    blob = b""
    for b in binaries(bundle):
        if not os.path.isfile(b):
            err(f"{where}: executable {os.path.basename(b)} missing")
            continue
        with open(b, "rb") as f:
            blob += f.read()
    for cat, needles in NEEDLES.items():
        hits = [n.decode() for n in needles if n in blob]
        if hits and cat not in declared:
            err(f"{where}: binary references {', '.join(hits)} but the manifest doesn't declare {cat}")
        elif hits:
            print(f"{where}: {cat} {sorted(declared[cat])} (binary references {', '.join(hits)})")
        elif cat in declared:
            print(f"{where}: {cat} declared, no reference found in the binary (over-declaring is allowed)")
    if APP_GROUP_DEFAULTS in blob and "1C8F.1" not in declared.get("NSPrivacyAccessedAPICategoryUserDefaults", set()):
        err(f"{where}: binary references UserDefaults(suiteName:) (App Group defaults) without 1C8F.1")

    if is_app:
        dev = [t for t in collected if t.get("NSPrivacyCollectedDataType") == "NSPrivacyCollectedDataTypeDeviceID"]
        if not (len(dev) == 1 and dev[0].get("NSPrivacyCollectedDataTypeLinked") is False
                and dev[0].get("NSPrivacyCollectedDataTypeTracking") is False
                and dev[0].get("NSPrivacyCollectedDataTypePurposes") == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]):
            err(f"{where}: must declare Device ID (#277 installId) once: not linked, not tracking, App Functionality")


def main(argv):
    args = argv[1:]
    label = "build"
    if "--label" in args:
        i = args.index("--label")
        label = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        print(__doc__)
        return 2
    app = args[0]
    check_bundle(app, label, is_app=True)
    plugins = os.path.join(app, "PlugIns")
    appexes = sorted(p for p in os.listdir(plugins) if p.endswith(".appex")) if os.path.isdir(plugins) else []
    if "AeroDJShare.appex" not in appexes:
        err(f"{label}: PlugIns/AeroDJShare.appex missing")
    for p in appexes:
        check_bundle(os.path.join(plugins, p), label, is_app=False)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
