#!/usr/bin/env bash
# App Attest entitlement split (#378, -Atlas). Default and Release builds must not carry
# com.apple.developer.devicecheck.appattest-environment, so they keep signing with the current
# app profile; only a tester_voice=true TestFlight build selects AeroDJ-TesterVoice.entitlements
# (which needs App Attest on the App ID and a regenerated profile, an owner portal step).
# 1. The shared AeroDJ.entitlements (and every other ios/ entitlements or build-config file
#    except the tester file) has no App Attest key.
# 2. The tester file is the shared file plus exactly that key (= production), nothing else.
# 3. project.yml and the xcconfigs never name the tester file; the app target signs with the
#    shared file in every configuration.
# 4. testflight-app-entitlements.sh picks the tester file only for workflow_dispatch with
#    TESTER_VOICE exactly "true", across the other inputs; testflight.yml goes through it.
# Linux and macOS: needs bash and python3 only, no Xcode.
set -euo pipefail
ios="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$ios/.." && pwd)"
key='com.apple.developer.devicecheck.appattest-environment'
shared='AeroDJ/AeroDJ.entitlements'
tester='AeroDJ/AeroDJ-TesterVoice.entitlements'

python3 - "$ios" "$repo" "$key" "$shared" "$tester" <<'PY'
import plistlib, re, sys
from pathlib import Path
ios, repo, key, shared, tester = Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:]
def fail(msg): sys.exit(f"FAIL: {msg}")
s = plistlib.loads((ios / shared).read_bytes())
t = plistlib.loads((ios / tester).read_bytes())
if key in s:
    fail(f"{shared} carries {key}; default and Release builds would need the App Attest profile")
for p in sorted(ios.rglob("*")):
    if not p.is_file() or ".build" in p.parts or p.suffix not in {".entitlements", ".xcconfig", ".yml", ".plist"}:
        continue
    rel = p.relative_to(ios).as_posix()
    if rel != tester and key in p.read_text(errors="ignore"):
        fail(f"{rel} names {key}; only {tester} may")
if t.get(key) != "production":
    fail(f"{tester} must set {key} = production")
if {k: v for k, v in t.items() if k != key} != s:
    fail(f"{tester} must equal {shared} plus {key} only (keys drifted)")
proj = (ios / "project.yml").read_text()
configs = [proj] + [p.read_text() for p in (ios / "Config").glob("*.xcconfig")] if (ios / "Config").is_dir() else [proj]
if any(Path(tester).name in c for c in configs):
    fail(f"project.yml or an xcconfig names {Path(tester).name}; it must only be selected by the TestFlight workflow")
app = re.search(r"^  AeroDJ:\n(?:(?:    .*|\s*)\n)*", proj, re.M)
if not app:
    fail("could not find the AeroDJ target in project.yml")
ents = re.findall(r"CODE_SIGN_ENTITLEMENTS:\s*(\S+)", app.group(0))
if ents != [shared]:
    fail(f"AeroDJ target entitlements are {ents}, expected exactly [{shared}] for every configuration")
wf = (repo / ".github/workflows/testflight.yml").read_text()
if Path(tester).name in wf:
    fail("testflight.yml names the tester file directly; it must go through testflight-app-entitlements.sh")
for needle in ('APP_ENTITLEMENTS=AeroDJ/AeroDJ.entitlements\n',
               'APP_ENTITLEMENTS="$(EVENT_NAME="$GITHUB_EVENT_NAME" "$RUNNER_TEMP/owner-ab/testflight-app-entitlements.sh")"\n',
               'app_ents = os.environ["APP_ENTITLEMENTS"]\n'):
    if wf.count(needle) != 1:
        fail(f"testflight.yml must select the app entitlements through testflight-app-entitlements.sh (missing: {needle.strip()})")
# CarPlay audio check sits after the App Attest signed-app check and is a no-op
# when the archived entitlements file does not request the key.
carplay = "com.apple.developer.carplay-audio"
if wf.find(f"PASS {carplay} skipped") < wf.find("App Attest entitlement is"):
    fail("testflight.yml CarPlay check must follow the App Attest signed-app check")
for needle in (
    f"PASS {carplay} skipped",
    f'echo "::error::FAIL {carplay} $1"',
    'carplay_fail "PROFILE_APP"',
    'carplay_fail "AeroDJ.app"',
    'carplay_fail "AeroDJShare.appex"',
    f'echo "PASS {carplay}"\n',
    "set +x",
    "security cms -D -i",
    "codesign -d --entitlements - --xml",
):
    if needle not in wf:
        fail(f"testflight.yml missing CarPlay profile check ({needle})")
PY

checked=0
for ev in workflow_dispatch push pull_request schedule ""; do
  for tv in true false "" TRUE True 1 yes " true" "true "; do
    for oa in true false; do
      for pd in true false; do
        got="$(EVENT_NAME="$ev" TESTER_VOICE="$tv" OWNER_AB="$oa" P0_DIAG="$pd" "$ios/scripts/testflight-app-entitlements.sh")"
        want="$shared"
        if [ "$ev" = workflow_dispatch ] && [ "$tv" = true ]; then want="$tester"; fi
        if [ "$got" != "$want" ]; then
          echo "FAIL: EVENT_NAME='$ev' TESTER_VOICE='$tv' OWNER_AB=$oa P0_DIAG=$pd -> '$got', expected '$want'"; exit 1
        fi
        checked=$((checked + 1))
      done
    done
  done
done
got="$(env -u EVENT_NAME -u TESTER_VOICE -u OWNER_AB -u P0_DIAG "$ios/scripts/testflight-app-entitlements.sh")"
[ "$got" = "$shared" ] || { echo "FAIL: no inputs -> '$got', expected '$shared'"; exit 1; }
echo "OK: App Attest entitlement only in $tester, selected only for tester_voice=true dispatch ($((checked + 1)) input cases)"
