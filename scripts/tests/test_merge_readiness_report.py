"""Offline tests for scripts/merge_readiness_report.py (#556). No network: fetch is never called.
Run: python3 -m unittest discover -s scripts/tests -v   -Fry"""
import copy
import json
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
import merge_readiness_report as m  # noqa: E402

HEAD = "6d5a15054d340a344e47810e928e6ce617dc8ea6"


def fixture(name="pr_ready.json"):
    with open(os.path.join(HERE, "fixtures", name)) as f:
        return json.load(f)


class NoNetwork(unittest.TestCase):
    def setUp(self):
        p = mock.patch.object(m.subprocess, "run", side_effect=AssertionError("no network in tests"))
        p.start()
        self.addCleanup(p.stop)


class JobNames(NoNetwork):
    def test_names_ids_quotes_and_step_names(self):
        f = fixture()
        self.assertEqual(m.job_check_names(f["workflows"][0]["text"]),
                         ["changes", "AeroDJCore tests", "Release archive (Xcode 27.2, unsigned)"])
        self.assertEqual(m.job_check_names(f["workflows"][1]["text"]), ["checks"])

    def test_repo_workflows_give_10_ios_jobs_and_2_ci_jobs(self):
        with open(os.path.join(ROOT, ".github/workflows/ios.yml")) as f:
            ios = m.job_check_names(f.read())
        with open(os.path.join(ROOT, ".github/workflows/ci.yml")) as f:
            ci = m.job_check_names(f.read())
        # 10 since #653 added the dispatch-only system bars capture. job_check_names lists every
        # job (it is not hidden). The capture job is N/A on PR runs; see DispatchOnlyNA.
        self.assertEqual(len(ios), 10, ios)
        self.assertIn("Duo UI tests (Xcode 27.2, iOS 27.2)", ios)
        self.assertIn("Release archive (Xcode 27.2, unsigned)", ios)
        self.assertIn("changes", ios)
        self.assertIn("System vertical bars capture (Xcode 27.2, iPad iOS 27.2)", ios)
        self.assertEqual(ci, ["checks", "tts-proxy"])


IOS = ".github/workflows/ios.yml"
CI = ".github/workflows/ci.yml"
BARS = "System vertical bars capture (Xcode 27.2, iPad iOS 27.2)"

DISPATCH_AND_PR = """
name: iOS
on:
  pull_request:
  workflow_dispatch:
    inputs:
      capture_system_bars:
        type: boolean
jobs:
  changes:
    if: github.event_name != 'workflow_dispatch'
    runs-on: ubuntu-latest
  core-tests:
    name: AeroDJCore tests
    needs: changes
    if: needs.changes.outputs.core == 'true'
  capture:
    name: Capture shot
    if: github.event_name == 'workflow_dispatch' && inputs.capture_system_bars == true
"""

# A job that normally runs on PRs, plus one that never can.
class DispatchOnlyNA(NoNetwork):
    """Dispatch-only jobs are N/A on PR runs, never a missing required check (#653 / #556)."""

    def _report(self, workflows, check_runs=None):
        f = fixture()
        f["workflows"] = workflows
        f["check_runs"] = check_runs if check_runs is not None else f["check_runs"]
        return m.build_report(**f)

    def test_a_dispatch_only_job_is_na_on_a_pr_and_a_missing_pr_job_is_still_flagged(self):
        # Fail-first: before the fix, Capture shot is a missing required check.
        wf = [{"path": IOS, "text": DISPATCH_AND_PR}, fixture()["workflows"][1]]
        r = self._report(wf, check_runs=[])
        rendered = m.render(r)
        self.assertIn("Capture shot: N/A", rendered)
        self.assertIn("N/A (dispatch-only", rendered)
        bad = r["checks"]["bad"]
        self.assertFalse(any("Capture shot" in b for b in bad), bad)
        self.assertTrue(any("changes: missing" in b or "AeroDJCore tests: missing" in b for b in bad), bad)
        self.assertIn("required check(s) not green", " ".join(r["reasons"]))
        # The N/A job is listed, not hidden.
        self.assertTrue(any("Capture shot" in n and s.startswith("N/A") for n, s in r["checks"]["rows"]))

    def test_repo_system_bars_job_is_na_on_a_pr_and_is_not_hidden(self):
        with open(os.path.join(ROOT, ".github/workflows/ios.yml")) as f:
            ios = f.read()
        names = m.job_check_names(ios)
        self.assertIn(BARS, names)
        wf = [{"path": IOS, "text": ios}, fixture()["workflows"][1]]
        r = self._report(wf, check_runs=[])
        self.assertTrue(any(BARS in n and s.startswith("N/A") for n, s in r["checks"]["rows"]), r["checks"]["rows"])
        self.assertFalse(any(BARS in b for b in r["checks"]["bad"]), r["checks"]["bad"])
        # A job that normally runs on PRs is still flagged when missing.
        self.assertTrue(any("Duo UI tests" in b and "missing" in b for b in r["checks"]["bad"]), r["checks"]["bad"])

    def test_or_with_pull_request_is_still_required(self):
        text = """
name: iOS
on:
  pull_request:
  workflow_dispatch:
jobs:
  both:
    name: PR or dispatch
    if: github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch'
"""
        r = self._report([{"path": IOS, "text": text}], check_runs=[])
        self.assertTrue(any("PR or dispatch: missing" in b for b in r["checks"]["bad"]), r["checks"]["bad"])
        self.assertFalse(any(s.startswith("N/A") for _, s in r["checks"]["rows"]))

    def test_workflow_without_pull_request_is_na(self):
        text = """
name: Manual
on:
  workflow_dispatch:
jobs:
  only:
    name: Dispatch job
"""
        r = self._report([{"path": IOS, "text": text}], check_runs=[])
        self.assertTrue(any("Dispatch job" in n and s.startswith("N/A") for n, s in r["checks"]["rows"]))
        self.assertFalse(r["checks"]["bad"])

    def _assert_stays_required(self, if_expr, job_name):
        text = f"""
name: iOS
on:
  pull_request:
  workflow_dispatch:
jobs:
  j:
    name: {job_name}
    if: {if_expr}
"""
        r = self._report([{"path": IOS, "text": text}], check_runs=[])
        self.assertTrue(any(f"{job_name}: missing" in b for b in r["checks"]["bad"]),
                        (if_expr, r["checks"]["bad"], r["checks"]["rows"]))
        self.assertFalse(any(s.startswith("N/A") for _, s in r["checks"]["rows"]),
                         (if_expr, r["checks"]["rows"]))

    def test_negated_dispatch_comparisons_stay_required(self):
        """Sentinel B1: these run on every PR; a missing run must not be hidden as N/A."""
        self._assert_stays_required("${{ !(github.event_name == 'workflow_dispatch') }}",
                                    "Negated dispatch")
        self._assert_stays_required("github.event_name == 'workflow_dispatch' == false",
                                    "Chained false")

    def test_inequality_and_unparseable_if_stay_required(self):
        self._assert_stays_required("github.event_name != 'pull_request'", "Not equal pull_request")
        self._assert_stays_required(
            "github.event_name == 'workflow_dispatch' && (always())", "Unparseable parens")

    def _assert_on_stays_required(self, workflow, job_name):
        r = self._report([{"path": IOS, "text": workflow}], check_runs=[])
        self.assertTrue(any(f"{job_name}: missing" in b for b in r["checks"]["bad"]),
                        (workflow, r["checks"]))
        self.assertFalse(any(s.startswith("N/A") for _, s in r["checks"]["rows"]),
                         (workflow, r["checks"]["rows"]))

    def test_pull_request_target_on_stays_required(self):
        """Echo: map, string, and list forms of pull_request_target must stay required."""
        self._assert_on_stays_required("""
name: Manual
on:
  pull_request_target:
jobs:
  only:
    name: Target job
""", "Target job")
        self._assert_on_stays_required("""
name: Manual
on:
  pull_request_target:
    types: [opened, synchronize]
jobs:
  only:
    name: Target types job
""", "Target types job")
        self._assert_on_stays_required("""
name: Manual
on: pull_request_target
jobs:
  only:
    name: Target string job
""", "Target string job")
        self._assert_on_stays_required("""
name: Manual
on: [pull_request_target]
jobs:
  only:
    name: Target list job
""", "Target list job")

    def test_empty_or_unrecognized_on_stays_required(self):
        """Echo: an empty or unparsed `on:` must fail closed, not mark every job N/A."""
        self._assert_on_stays_required("""
name: Manual
on:

jobs:
  only:
    name: Empty on job
""", "Empty on job")
        self._assert_on_stays_required("""
name: Manual
on:
    pull_request:
jobs:
  only:
    name: Four space job
""", "Four space job")


class Signs(NoNetwork):
    def test_sha8_and_sha40_with_no_blockers(self):
        self.assertEqual(m.parse_sign("SIGN 6d5a1505 -Echo\n\nNo blockers.", HEAD), ("Echo", None))
        self.assertEqual(m.parse_sign(f"SIGN {HEAD} -Echo\nNo blockers.", HEAD), ("Echo", None))
        self.assertEqual(m.parse_sign("\n  SIGN 6D5A1505 -Echo  \nNo blockers.", HEAD), ("Echo", None))

    def test_stale_sha_does_not_count(self):
        name, why = m.parse_sign("SIGN b902de7f -Echo\nNo blockers.", HEAD)
        self.assertIsNone(name)
        self.assertIn("head is 6d5a1505", why)

    def test_sign_without_no_blockers_counts(self):
        self.assertEqual(m.parse_sign("SIGN 6d5a1505 -Echo\n\nReviewed: test-only. -Echo", HEAD), ("Echo", None))
        self.assertEqual(m.parse_sign("SIGN 6d5a1505 -Echo", HEAD), ("Echo", None))
        s = m.collect_signs([{"kind": "comment", "body": "SIGN 6d5a1505 -Atlas\n\nLooks fine.", "url": "u"}],
                            HEAD, {"fry"})
        self.assertEqual(s["valid"], {"Atlas": "u"})

    def test_sign_must_be_first_line_and_exact(self):
        self.assertEqual(m.parse_sign("Reviewed.\nSIGN 6d5a1505 -Echo\nNo blockers.", HEAD), (None, None))
        self.assertIsNone(m.parse_sign("SIGN 6d5a1505 -Echo, will sign\nNo blockers.", HEAD)[0])
        self.assertIsNone(m.parse_sign("SIGN 6d5a15 -Echo\nNo blockers.", HEAD)[0])
        self.assertEqual(m.parse_sign(None, HEAD), (None, None))

    def test_authors_include_merge_commits_and_co_authors(self):
        authors = m.commit_author_names(fixture()["commits"])
        self.assertEqual(authors, {"fry", "nova", "atlas"})

    def test_collect_excludes_authors_changes_requested_and_dupes(self):
        postings = fixture()["postings"] + [
            {"kind": "review", "state": "CHANGES_REQUESTED", "body": "SIGN 6d5a1505 -Orion\nNo blockers."}]
        s = m.collect_signs(postings, HEAD, {"fry", "nova", "atlas"})
        self.assertEqual(s["valid"], {"Echo": "u/echo", "Sentinel": "u/sentinel"})
        joined = " | ".join(s["rejected"])
        for who in ("Fry", "Nova", "Atlas"):
            self.assertIn(f"{who}: is a commit author", joined)
        self.assertIn("Orion: review requests changes", joined)

    def test_author_match_ignores_case(self):
        s = m.collect_signs([{"kind": "comment", "body": "SIGN 6d5a1505 -FRY\nNo blockers."}], HEAD, {"fry"})
        self.assertEqual(s["valid"], {})


IOS, CI = ".github/workflows/ios.yml", ".github/workflows/ci.yml"
LABELS = {IOS: "iOS", CI: "CI"}
WRUNS = [{"check_suite_id": 1, "path": IOS, "name": "iOS"},
         {"check_suite_id": 2, "path": CI + "@refs/pull/900/merge", "name": "CI"}]


def run(id, name, conclusion="success", suite=1, status="completed", started="1", sha=HEAD):
    return {"id": id, "name": name, "status": status, "conclusion": conclusion, "started_at": started,
            "head_sha": sha, "check_suite": {"id": suite}}


def assess(runs, required, workflow_runs=WRUNS):
    return m.assess_checks(runs, required, HEAD, workflow_runs, LABELS)


class Checks(NoNetwork):
    def test_latest_run_wins_and_missing_pending_failed_are_not_green(self):
        runs = [run(1, "a", "failure", started="1"), run(2, "a", "success", started="2"),
                run(3, "b", None, status="queued"), run(4, "c", "cancelled"),
                run(5, "d", "success", started="1"), run(6, "d", "cancelled", started="2")]
        r = assess(runs, [(IOS, n) for n in "abcde"])
        self.assertEqual(r["rows"], [("iOS / a", "success"), ("iOS / b", "queued"), ("iOS / c", "cancelled"),
                                     ("iOS / d", "cancelled"), ("iOS / e", "missing")])
        self.assertEqual(len(r["bad"]), 4)


class WorkflowKeying(NoNetwork):
    """#634 follow-up (Sentinel): jobs are keyed by (workflow, job name)."""

    def test_same_job_name_in_two_workflows_is_tracked_separately(self):
        runs = [run(1, "lint", "success", suite=1), run(2, "lint", "failure", suite=2, started="9")]
        r = assess(runs, [(IOS, "lint"), (CI, "lint")])
        self.assertEqual(r["rows"], [("iOS / lint", "success"), ("CI / lint", "failure")])
        self.assertEqual(r["bad"], ["CI / lint: failure"])

    def test_ci_changes_job_does_not_vouch_for_ios_skips(self):
        runs = [run(1, "changes", "failure", suite=1), run(2, "iOS simulator build", "skipped", suite=1),
                run(3, "changes", "success", suite=2, started="9")]
        r = assess(runs, [(IOS, "changes"), (IOS, "iOS simulator build"), (CI, "changes")])
        self.assertIn("iOS / iOS simulator build: skipped (changes did not pass at this head)", r["bad"])
        self.assertIn(("CI / changes", "success"), r["rows"])

    def test_ci_changes_alone_does_not_vouch_when_ios_changes_missing(self):
        runs = [run(2, "iOS simulator build", "skipped", suite=1), run(3, "changes", "success", suite=2)]
        r = assess(runs, [(IOS, "changes"), (IOS, "iOS simulator build")])
        self.assertIn("iOS / changes: missing", r["bad"])
        self.assertIn("iOS / iOS simulator build: skipped (changes did not pass at this head)", r["bad"])

    def test_unmapped_suite_fails_closed(self):
        runs = [run(1, "changes", "success", suite=99), run(2, "iOS simulator build", "success", suite=99)]
        r = assess(runs, [(IOS, "changes"), (IOS, "iOS simulator build")])
        self.assertEqual(r["bad"], [f"iOS / changes: {m.UNMAPPED}", f"iOS / iOS simulator build: {m.UNMAPPED}"])
        r = assess(runs, [(IOS, "changes")], workflow_runs=[])
        self.assertEqual(r["bad"], [f"iOS / changes: {m.UNMAPPED}"])

    def test_skip_outside_ios_is_never_green(self):
        runs = [run(1, "changes", "success", suite=1), run(2, "checks", "skipped", suite=2)]
        r = assess(runs, [(IOS, "changes"), (CI, "checks")])
        self.assertEqual(r["bad"], ["CI / checks: skipped (not an iOS path-filter job)"])

    def test_workflow_path_ref_suffix_is_stripped(self):
        self.assertEqual(m.suite_to_workflow(WRUNS), {1: IOS, 2: CI})


class PathFilterSkips(NoNetwork):
    REQ = [(IOS, "changes"), (IOS, "iOS simulator build"), (CI, "checks")]

    def runs(self, changes=("completed", "success"), changes_sha=HEAD, sim_sha=HEAD):
        out = [run(2, "iOS simulator build", "skipped", suite=1, sha=sim_sha), run(3, "checks", suite=2)]
        if changes:
            out.append(run(1, "changes", changes[1], suite=1, status=changes[0], sha=changes_sha))
        return out

    def test_skip_with_changes_success_counts_as_green(self):
        r = assess(self.runs(), self.REQ)
        self.assertEqual(r["bad"], [])
        self.assertIn(("iOS / iOS simulator build", m.SKIP_GREEN), r["rows"])

    def test_skip_with_changes_failed_or_pending_or_missing_is_not_green(self):
        for changes in (("completed", "failure"), ("completed", "skipped"), ("in_progress", None), None):
            r = assess(self.runs(changes=changes), self.REQ)
            self.assertIn("iOS / iOS simulator build: skipped (changes did not pass at this head)", r["bad"], changes)

    def test_changes_at_another_sha_does_not_vouch(self):
        r = assess(self.runs(changes_sha="b" * 40), self.REQ)
        self.assertIn("iOS / changes: missing", r["bad"])
        self.assertIn("iOS / iOS simulator build: skipped (changes did not pass at this head)", r["bad"])

    def test_skip_at_another_sha_does_not_count(self):
        r = assess(self.runs(sim_sha="b" * 40), self.REQ)
        self.assertIn("iOS / iOS simulator build: missing", r["bad"])

    def test_skipped_changes_job_itself_is_not_green(self):
        r = assess([run(1, "changes", "skipped", suite=1)], [(IOS, "changes")])
        self.assertEqual(r["bad"], ["iOS / changes: skipped"])

    def test_report_marks_skip_green_as_ok(self):
        f = fixture()
        for r in f["check_runs"]:
            if r["name"] == "AeroDJCore tests":
                r["conclusion"] = "skipped"
        rep = m.build_report(**f)
        self.assertTrue(rep["ready"], rep["reasons"])
        self.assertIn("  ok  iOS / AeroDJCore tests: skipped (path filter, changes passed)", m.render(rep))


class Roster(NoNetwork):
    """#634 follow-up (Atlas): authors outside the roster warn, report-only."""

    def test_off_roster_names(self):
        self.assertEqual(m.off_roster(["Fry", "cursor agent", "Rowerguy508", "NOVA"]),
                         ["cursor agent", "Rowerguy508"])

    def test_non_roster_author_warns_without_changing_ready(self):
        f = fixture()
        before = m.build_report(**fixture())
        self.assertEqual(before["off_roster_authors"], [])
        self.assertFalse(any(w.startswith("ROSTER") for w in before["warnings"]))
        f["commits"].append({"commit": {"author": {"name": "Cursor Agent"},
                                        "message": "x\n\nCo-authored-by: Rowerguy508 <r@example.com>"}})
        rep = m.build_report(**f)
        self.assertTrue(rep["ready"], rep["reasons"])
        self.assertEqual(rep["off_roster_authors"], ["Cursor Agent", "Rowerguy508"])
        text = m.render(rep)
        self.assertIn("WARNING: ROSTER: commit author(s) outside the bot roster", text)
        self.assertTrue(text.endswith("\nREADY"))
        self.assertIn('"off_roster_authors"', json.dumps(rep))

    def test_non_roster_author_does_not_change_not_ready(self):
        f = fixture()
        f["postings"] = []
        f["commits"].append({"commit": {"author": {"name": "Cursor Agent"}, "message": "x"}})
        rep = m.build_report(**f)
        self.assertEqual(rep["reasons"], ["0/2 non-author signs at this head"])


class Overlap(NoNetwork):
    def test_intersection_sorted_unique(self):
        self.assertEqual(m.overlap(["b", "a", "c", "a"], ["c", "a", "z"]), ["a", "c"])
        self.assertEqual(m.overlap(["a"], []), [])


class DeviceLine(NoNetwork):
    """#556 acceptance: the PR body has a line starting `Device: NOT TESTED` (#671 -Atlas)."""

    def test_accepts_the_two_exact_forms_anywhere_in_the_body(self):
        self.assertEqual(m.device_line("Summary\n\nDevice: NOT TESTED\n\n-Fry"), "NOT TESTED")
        self.assertEqual(m.device_line("Device: NOT TESTED on a phone"), "NOT TESTED")
        self.assertEqual(m.device_line("a\r\nDevice: TESTED on an iPhone 17\r\nb"), "TESTED")

    def test_everything_else_is_missing(self):
        for body in (None, "", "no such line", "Device check: NOT TESTED", "device: NOT TESTED",
                     "  Device: NOT TESTED", "- Device: NOT TESTED", "> Device: NOT TESTED",
                     "Device:NOT TESTED", "Device: NOT TESTEDX", "Device: TESTEDX", "Device: untested",
                     "Notes: Device: NOT TESTED", "Device: NOT"):
            self.assertIsNone(m.device_line(body), repr(body))

    def test_a_missing_device_line_is_the_only_reason_when_all_else_is_ready(self):
        f = fixture()
        f["pr"] = dict(f["pr"], device_line=None)
        r = m.build_report(**f)
        self.assertFalse(r["ready"])
        self.assertEqual(r["reasons"], ["PR body has no line starting `Device: NOT TESTED` (or `Device: TESTED`)"])
        self.assertIn("Device line: missing", m.render(r))

    def test_a_pr_without_the_field_fails_closed(self):
        f = fixture()
        f["pr"].pop("device_line")
        self.assertFalse(m.build_report(**f)["ready"])

    def test_fetch_reads_the_line_from_the_body_and_never_keeps_the_body(self):
        def api(path):
            if path.endswith("/pulls/9"):
                return {"head": {"sha": "a" * 40}, "base": {"ref": "integration/device-duo"}, "state": "open",
                        "merged_at": None, "changed_files": 0, "body": "x\n\nDevice: NOT TESTED\nsecret body text"}
            if "/commits/integration" in path:
                return {"sha": "b" * 40}
            if "/compare/" in path:
                return {"merge_base_commit": {"sha": "b" * 40}, "files": []}
            return {"content": "bmFtZTogeAo="}  # base64 of "name: x\n"
        with mock.patch.object(m, "gh_api", side_effect=api), mock.patch.object(m, "gh_list", return_value=[]):
            got = m.fetch("o/r", 9)
        self.assertEqual(got["pr"]["device_line"], "NOT TESTED")
        self.assertNotIn("secret body text", json.dumps(got))


class Verdict(NoNetwork):
    def test_fixture_is_ready(self):
        r = m.build_report(**fixture())
        self.assertTrue(r["ready"], r["reasons"])
        text = m.render(r)
        self.assertTrue(text.endswith("\nREADY"), text)
        self.assertIn("Signs (2/2 non-author at 6d5a1505)", text)
        self.assertIn("Device line: Device: NOT TESTED", text)
        self.assertIn("Checks (4/4 green)", text)
        self.assertIn("  ok  CI / checks: success", text)
        self.assertNotIn("Vercel", text)  # only ios.yml and ci.yml jobs are required

    def test_each_failure_is_a_reason(self):
        f = fixture()
        f["postings"] = f["postings"][:1]
        f["check_runs"] = [r for r in f["check_runs"] if r["name"] != "checks"]
        f["base_files"] = ["ios/AeroDJCore/Tests/AeroDJCoreTests/LatePollQueueEndTests.swift", "README.md"]
        f["pr"] = dict(f["pr"], base="main", device_line=None)
        r = m.build_report(**f)
        self.assertFalse(r["ready"])
        line = m.render(r).splitlines()[-1]
        self.assertTrue(line.startswith("NOT READY: "), line)
        for part in ("base is main", "1 required check(s) not green", "1/2 non-author signs",
                     "1 file(s) also changed on the base", "PR body has no line starting"):
            self.assertIn(part, line)
        self.assertIn("  ios/AeroDJCore/Tests/AeroDJCoreTests/LatePollQueueEndTests.swift", m.render(r))

    def test_closed_or_merged_is_not_ready(self):
        f = fixture()
        f["pr"] = dict(f["pr"], state="closed", merged=True)
        r = m.build_report(**f)
        self.assertIn("PR is closed (merged)", r["reasons"])

    def test_incomplete_data_fails_closed(self):
        f = fixture()
        f["warnings"] = ["INCOMPLETE: PR has 250+ commits", "PR is not open: overlap not computed"]
        r = m.build_report(**f)
        self.assertFalse(r["ready"])
        self.assertEqual(r["reasons"], ["INCOMPLETE: PR has 250+ commits"])

    def test_no_workflow_jobs_fails_closed(self):
        f = fixture()
        f["workflows"] = [{"path": IOS, "text": "name: x\n"}, {"path": CI, "text": "name: y\n"}]
        self.assertFalse(m.build_report(**f)["ready"])

    def test_original_fixture_untouched_between_tests(self):
        f = fixture()
        g = copy.deepcopy(f)
        m.build_report(**f)
        self.assertEqual(f, g)


class Cli(NoNetwork):
    def test_default_is_print_only(self):
        report = m.build_report(**fixture())
        with mock.patch.object(m, "fetch", return_value=fixture()) as fetch, \
                mock.patch.object(m, "default_repo", return_value="o/r"), \
                mock.patch("builtins.print") as out:
            self.assertEqual(m.main(["900"]), 0)
        fetch.assert_called_once_with("o/r", 900)
        m.subprocess.run.assert_not_called()  # no gh pr comment without --comment
        self.assertEqual(out.call_args[0][0], m.render(report))

    def test_comment_flag_posts_the_report(self):
        with mock.patch.object(m, "fetch", return_value=fixture()), \
                mock.patch.object(m.subprocess, "run") as run, mock.patch("builtins.print"):
            self.assertEqual(m.main(["900", "--repo", "o/r", "--comment"]), 0)
        args = run.call_args[0][0]
        self.assertEqual(args[:4], ["gh", "pr", "comment", "900"])
        self.assertTrue(run.call_args[1]["input"].rstrip().endswith("READY"))


if __name__ == "__main__":
    unittest.main()
