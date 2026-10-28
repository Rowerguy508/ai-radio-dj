#!/bin/bash
# Fail a device .app that contains Apple AMX coprocessor instruction words
# (w & 0xFFFFFC00) == 0x00201000 in __TEXT,__text. Those words are what
# ITMS-90755 called "prohibited instructions" in AeroDJPhonon.
#
# The same step scans the pinned PhononCore.xcframework v0.5.0 ios-arm64
# static library and requires at least one hit, so a broken scanner cannot
# pass an empty app by accident.
set -euo pipefail

# Checksum of PhononCore.xcframework.zip from xn-ptts v0.5.0 Package.swift binaryTarget.
export AMX_PIN="${AMX_PIN:-d91096a18650d4ffd23f211e2ea534c3bc251a7b66859497b56e1c89f3e92ca9}"
export AMX_URL="${AMX_URL:-https://github.com/gradium-ai/xn-ptts/releases/download/v0.5.0/PhononCore.xcframework.zip}"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 AeroDJ.app [AeroDJ.app ...]" >&2
  exit 2
fi

python3 - "$@" <<'PY'
import hashlib, os, shutil, subprocess, sys, tempfile, urllib.request, zipfile

MASK = 0xFFFFFC00
HIT = 0x00201000
PIN = os.environ.get("AMX_PIN", "")
URL = os.environ.get("AMX_URL", "")

def hits_in_words(tokens):
    n = 0
    words = 0
    for token in tokens:
        if len(token) != 8:
            continue
        try:
            word = int(token, 16)
        except ValueError:
            continue
        words += 1
        if (word & MASK) == HIT:
            n += 1
    return n, words

def self_test():
    sample = "0000000100004000 00201000 002013fc fd7bbfa9 00201400".split()
    n, words = hits_in_words(sample)
    if n != 2 or words != 4:
        raise SystemExit(f"mask self-test failed: hits={n} words={words}")
    print("mask self-test ok: 0x00201000 and 0x002013fc caught; 0x00201400 and a normal word ignored")

def otool_text(path):
    cmd = ["otool", "-t", "-arch", "arm64", path]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        proc = subprocess.run(["otool", "-t", path], capture_output=True, text=True)
        if proc.returncode != 0:
            raise SystemExit(f"otool failed for {path}: {proc.stderr.strip()}")
    tokens = []
    for line in proc.stdout.splitlines():
        tokens.extend(line.split())
    return hits_in_words(tokens)

def is_macho(path):
    if not os.path.isfile(path) or os.path.islink(path):
        return False
    proc = subprocess.run(["file", "-b", path], capture_output=True, text=True)
    return "Mach-O" in proc.stdout

def machos_in_app(app):
    name = os.path.splitext(os.path.basename(app))[0]
    found = []
    main = os.path.join(app, name)
    if not is_macho(main):
        raise SystemExit(f"main binary is not Mach-O: {main}")
    found.append(main)
    for folder in ("Frameworks", "PlugIns"):
        root = os.path.join(app, folder)
        if not os.path.isdir(root):
            continue
        for dirpath, _, names in os.walk(root):
            for filename in names:
                path = os.path.join(dirpath, filename)
                if is_macho(path):
                    found.append(path)
    return found

def scan(path):
    n, words = otool_text(path)
    print(f"scan {path} words={words} hits={n}")
    if words == 0:
        raise SystemExit(f"no __text words from {path}; scanner did not see the section")
    return n

self_test()

apps = sys.argv[1:]
for app in apps:
    phonon = os.path.join(app, "Frameworks", "AeroDJPhonon.framework")
    if os.path.exists(phonon):
        raise SystemExit(f"AeroDJPhonon.framework is embedded in {app}")
    total = 0
    for path in machos_in_app(app):
        total += scan(path)
    if total != 0:
        raise SystemExit(f"{app} contains {total} prohibited AMX instruction words")
    print(f"app clean: {app}")

if not PIN or not URL:
    raise SystemExit("AMX_PIN and AMX_URL are required")
tmp = tempfile.mkdtemp(prefix="phonon-amx-")
try:
    archive = os.path.join(tmp, "PhononCore.xcframework.zip")
    urllib.request.urlretrieve(URL, archive)
    digest = hashlib.sha256(open(archive, "rb").read()).hexdigest()
    print(f"phonon xcframework sha256={digest}")
    if digest != PIN:
        raise SystemExit(f"xcframework sha256 mismatch: {digest} != {PIN}")
    with zipfile.ZipFile(archive) as zf:
        zf.extractall(tmp)
    library = os.path.join(tmp, "PhononCore.xcframework", "ios-arm64", "libptts_ffi.a")
    if not os.path.isfile(library):
        raise SystemExit(f"pinned library missing: {library}")
    control = scan(library)
    if control < 1:
        raise SystemExit("positive control failed: pinned libptts_ffi.a has no AMX words")
    print(f"positive control ok: {control} AMX words in ios-arm64/libptts_ffi.a")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PY
