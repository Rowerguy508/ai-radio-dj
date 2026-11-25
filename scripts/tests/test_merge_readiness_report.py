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
        self.assertEqual(m.job_check_names(f["workflows"][0]),
                         ["changes", "AeroDJCore tests", "Release archive (Xcode 27.2, unsigned)"])
        self.assertEqual(m.job_check_names(f["workflows"][1]), ["checks"])

    def test_repo_workflows_give_8_ios_jobs_and_2_ci_jobs(self):
        with open(os.path.join(ROOT, ".github/workflows/ios.yml")) as f:
            ios = m.job_check_names(f.read())
        with open(os.path.join(ROOT, ".github/workflows/ci.yml")) as f:
            ci = m.job_check_names(f.read())
        self.assertEqual(len(ios), 8, ios)
        self.assertIn("Release archive (Xcode 27.2, unsigned)", ios)
        self.assertIn("changes", ios)
        self.assertEqual(ci, ["checks", "tts-proxy"])


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


class Checks(NoNetwork):
    def test_latest_run_wins_and_missing_pending_failed_are_not_green(self):
        runs = [
            {"id": 1, "name": "a", "status": "completed", "conclusion": "failure", "started_at": "1"},
            {"id": 2, "name": "a", "status": "completed", "conclusion": "success", "started_at": "2"},
            {"id": 3, "name": "b", "status": "queued", "conclusion": None, "started_at": "1"},
            {"id": 4, "name": "c", "status": "completed", "conclusion": "cancelled", "started_at": "1"},
            {"id": 5, "name": "d", "status": "completed", "conclusion": "success", "started_at": "1"},
            {"id": 6, "name": "d", "status": "completed", "conclusion": "cancelled", "started_at": "2"},
        ]
        r = m.assess_checks(runs, ["a", "b", "c", "d", "e"])
        self.assertEqual(r["rows"], [("a", "success"), ("b", "queued"), ("c", "cancelled"),
                                     ("d", "cancelled"), ("e", "missing")])
        self.assertEqual(len(r["bad"]), 4)


class PathFilterSkips(NoNetwork):
    REQ = ["changes", "iOS simulator build", "checks"]

    def runs(self, changes=("completed", "success"), changes_sha=HEAD, sim_sha=HEAD):
        out = [{"id": 2, "name": "iOS simulator build", "status": "completed", "conclusion": "skipped",
                "started_at": "1", "head_sha": sim_sha},
               {"id": 3, "name": "checks", "status": "completed", "conclusion": "success",
                "started_at": "1", "head_sha": HEAD}]
        if changes:
            out.append({"id": 1, "name": "changes", "status": changes[0], "conclusion": changes[1],
                        "started_at": "1", "head_sha": changes_sha})
        return out

    def test_skip_with_changes_success_counts_as_green(self):
        r = m.assess_checks(self.runs(), self.REQ, HEAD)
        self.assertEqual(r["bad"], [])
        self.assertIn(("iOS simulator build", m.SKIP_GREEN), r["rows"])

    def test_skip_with_changes_failed_or_pending_or_missing_is_not_green(self):
        for changes in (("completed", "failure"), ("completed", "skipped"), ("in_progress", None), None):
            r = m.assess_checks(self.runs(changes=changes), self.REQ, HEAD)
            self.assertIn("iOS simulator build: skipped (changes did not pass at this head)", r["bad"], changes)

    def test_changes_at_another_sha_does_not_vouch(self):
        r = m.assess_checks(self.runs(changes_sha="b" * 40), self.REQ, HEAD)
        self.assertIn("changes: missing", r["bad"])
        self.assertIn("iOS simulator build: skipped (changes did not pass at this head)", r["bad"])

    def test_skip_at_another_sha_does_not_count(self):
        r = m.assess_checks(self.runs(sim_sha="b" * 40), self.REQ, HEAD)
        self.assertIn("iOS simulator build: missing", r["bad"])

    def test_skipped_changes_job_itself_is_not_green(self):
        runs = [{"id": 1, "name": "changes", "status": "completed", "conclusion": "skipped",
                 "started_at": "1", "head_sha": HEAD}]
        self.assertEqual(m.assess_checks(runs, ["changes"], HEAD)["bad"], ["changes: skipped"])

    def test_report_marks_skip_green_as_ok(self):
        f = fixture()
        for r in f["check_runs"]:
            if r["name"] == "AeroDJCore tests":
                r["conclusion"] = "skipped"
        rep = m.build_report(**f)
        self.assertTrue(rep["ready"], rep["reasons"])
        self.assertIn("  ok  AeroDJCore tests: skipped (path filter, changes passed)", m.render(rep))


class Overlap(NoNetwork):
    def test_intersection_sorted_unique(self):
        self.assertEqual(m.overlap(["b", "a", "c", "a"], ["c", "a", "z"]), ["a", "c"])
        self.assertEqual(m.overlap(["a"], []), [])


class Verdict(NoNetwork):
    def test_fixture_is_ready(self):
        r = m.build_report(**fixture())
        self.assertTrue(r["ready"], r["reasons"])
        text = m.render(r)
        self.assertTrue(text.endswith("\nREADY"), text)
        self.assertIn("Signs (2/2 non-author at 6d5a1505)", text)
        self.assertIn("Checks (4/4 green)", text)
        self.assertNotIn("Vercel", text)  # only ios.yml and ci.yml jobs are required

    def test_each_failure_is_a_reason(self):
        f = fixture()
        f["postings"] = f["postings"][:1]
        f["check_runs"] = [r for r in f["check_runs"] if r["name"] != "checks"]
        f["base_files"] = ["ios/AeroDJCore/Tests/AeroDJCoreTests/LatePollQueueEndTests.swift", "README.md"]
        f["pr"] = dict(f["pr"], base="main")
        r = m.build_report(**f)
        self.assertFalse(r["ready"])
        line = m.render(r).splitlines()[-1]
        self.assertTrue(line.startswith("NOT READY: "), line)
        for part in ("base is main", "1 required check(s) not green", "1/2 non-author signs",
                     "1 file(s) also changed on the base"):
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
        f["workflows"] = ["name: x\n", "name: y\n"]
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
