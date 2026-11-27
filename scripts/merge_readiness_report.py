#!/usr/bin/env python3
"""Report-only merge readiness for a PR into integration/device-duo (#556). -Fry

Run by hand:  python3 scripts/merge_readiness_report.py 633 [--repo owner/name] [--json] [--comment]

Prints, at the PR's exact head sha:
  (a) checks: every job in ios.yml and ci.yml (read from the base branch head) has a completed
      `success` check run on that sha. Jobs are keyed by (workflow, job name): each check run is
      mapped to its workflow through its check suite and the Actions workflow runs for the sha, and
      a run that can't be mapped never counts. A skipped iOS job counts as green only when
      ios.yml's own `changes` job (the path filter) concluded success at the same sha; it is shown as
      "skipped (path filter, changes passed)". Missing, pending, cancelled, failed, or any other
      skip is not green. A job is N/A on a PR only when that is certain: a plain positive
      dispatch-only `if:` (`github.event_name == 'workflow_dispatch'`, optionally `&&` a
      positive `inputs.<id>` / `inputs.<id> == true` check), or a fully parsed `on:` whose every key is a known non-PR event (allowlist:
      `workflow_dispatch`, `schedule`, `push`, `release`, and other documented events that
      a pull request cannot trigger). Anything else — `!`, `!=`, `||`, chained `==`,
      parentheses, an empty or unparsed `on:`, or an unknown `on:` key — fails closed and
      is a missing required check if it has no run.
      N/A jobs are listed, not hidden.
  (b) signs: a comment or review whose first non-empty line is exactly `SIGN <sha8|sha40> -Name`,
      where the sha is the current head. A review in
      CHANGES_REQUESTED state never counts. The signer is the `-Name`, not the GitHub login (every
      bot posts as the same login). Non-author: Name is not the git author name, nor a
      Co-authored-by name, of ANY commit on the PR, forward-merge commits included. One sign per
      Name. 2 needed.
  (c) overlap: files the PR changes (merge-base..head) intersected with files the base branch
      changed since the merge-base (merge-base..base head). Any overlap makes the verdict NOT
      READY ("forward-merge or confirm the hunks are disjoint"), because the PR has not been
      tested against those base changes.
  (d) device line: the PR body has a line that starts with `Device: NOT TESTED` (or the
      device-tested form `Device: TESTED`). `Device check: ...` and an indented or quoted line do not
      count. Missing is NOT READY (#556 acceptance; #671 -Atlas).
  (e) READY or NOT READY, with every reason.
  Also warns (report-only, never a reason) when a commit author is outside ROSTER.

Report-only: it is not a required check, writes no check run, and changes no branch protection.
Default is print-only. `--comment` posts the same report as a PR comment (only when asked).
Needs `gh` signed in with read access. Exit 0 when a report was produced (READY or NOT), 1 on a
fetch error.
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys

TARGET_BASE = "integration/device-duo"
REQUIRED_SIGNS = 2
WORKFLOWS = (".github/workflows/ios.yml", ".github/workflows/ci.yml")
IOS_WORKFLOW = ".github/workflows/ios.yml"
CHANGES_JOB = "changes"
# #634 follow-up (Atlas): the bot roster. A commit author outside it is a warning only.
ROSTER = ("Fry", "Nova", "Echo", "Atlas", "Sentinel", "Orion")
PAGE = 100
MAX_PR_COMMITS = 250   # GitHub's pulls/N/commits limit: more than this and we can't see every author.
MAX_COMPARE_FILES = 300  # GitHub's compare file limit.

SIGN_LINE = re.compile(r"^SIGN ([0-9a-fA-F]{8}|[0-9a-fA-F]{40}) -([A-Za-z][A-Za-z0-9]*)$")
DEVICE_LINE = re.compile(r"^Device: (NOT TESTED|TESTED)(?![A-Za-z0-9])")
CO_AUTHOR = re.compile(r"^Co-authored-by:\s*(.+?)\s*<[^>]*>\s*$", re.IGNORECASE | re.MULTILINE)


# ---------- pure logic (tested offline) ----------

def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def _parse_jobs(yaml_text: str) -> list[dict]:
    """Jobs as {id, name, if} for this repo's layout (jobs at 2 spaces, keys at 4)."""
    jobs: list[dict] = []
    in_jobs = False
    current = None

    def flush():
        nonlocal current
        if current is not None:
            jobs.append(current)
            current = None

    for raw in yaml_text.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            if in_jobs:
                flush()
            in_jobs = line == "jobs:"
            continue
        if not in_jobs:
            continue
        m = re.match(r"^  ([A-Za-z_][\w-]*):\s*$", line)
        if m:
            flush()
            current = {"id": m.group(1), "name": None, "if": None}
            continue
        if current is None:
            continue
        m = re.match(r"^    name:\s*(.+?)\s*$", line)
        if m and current["name"] is None:
            current["name"] = _unquote(m.group(1))
            continue
        m = re.match(r"^    if:\s*(.+?)\s*$", line)
        if m and current["if"] is None:
            current["if"] = m.group(1).strip()
    if in_jobs:
        flush()
    return jobs


def job_check_names(yaml_text: str) -> list[str]:
    """Check-run names for a workflow's jobs: the job's `name:`, or its id when it has none.
    A tiny line parser for this repo's layout (jobs at 2 spaces, job keys at 4)."""
    return [j["name"] or j["id"] for j in _parse_jobs(yaml_text)]


def workflow_runs_on_pull_request(yaml_text: str) -> bool:
    """True unless every parsed `on:` key is a known non-PR event.

    A workflow is N/A on a PR only when at least one event key was parsed and every
    key is in `_NON_PR_ON_EVENTS`. Any unknown key (a typo such as `pull_requets`),
    any PR event, or an empty / unparsed `on:` fails closed and is treated as running
    on a PR, so its jobs stay required.
    """
    events = _parse_on_events(yaml_text)
    if not events:
        return True
    return any(e not in _NON_PR_ON_EVENTS for e in events)


# Documented GitHub Actions events that are not triggered by pull-request activity.
# PR events (`pull_request`, `pull_request_target`, reviews, merge_group) and events
# that also fire on PRs (`issue_comment`, check runs) are omitted: an unknown key
# fails closed.
_NON_PR_ON_EVENTS = frozenset({
    "branch_protection_rule",
    "create",
    "delete",
    "deployment",
    "deployment_protection_rule",
    "deployment_review",
    "deployment_status",
    "discussion",
    "discussion_comment",
    "fork",
    "gollum",
    "issues",
    "label",
    "milestone",
    "page_build",
    "public",
    "push",
    "registry_package",
    "release",
    "repository_advisory",
    "repository_dispatch",
    "schedule",
    "status",
    "watch",
    "workflow_call",
    "workflow_dispatch",
    "workflow_run",
    "member",
    "membership",
    "organization",
    "team",
    "team_add",
    "project",
    "project_card",
    "project_column",
    "projects_v2",
    "projects_v2_item",
})
_ON_EVENT = re.compile(r"^[A-Za-z_][\w-]*$")
_ON_INLINE_LIST = re.compile(r"^on:\s*\[([^]]*)\]\s*$")
_ON_INLINE_ONE = re.compile(r"^on:\s*([A-Za-z_][\w-]*)\s*$")
_ON_MAPPING_KEY = re.compile(r"^  ([A-Za-z_][\w-]*)\s*:")


def _parse_on_events(yaml_text: str) -> set[str] | None:
    """Event names in `on:`, or None if the block is absent or not fully understood."""
    in_on = False
    collected: set[str] = set()
    for raw in yaml_text.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            if in_on:
                return collected or None
            if re.match(r"^on:\s*$", line):
                in_on = True
                continue
            if line.startswith("on:"):
                m = _ON_INLINE_LIST.match(line)
                if m:
                    items = [i.strip() for i in m.group(1).split(",") if i.strip()]
                    if items and all(_ON_EVENT.fullmatch(i) for i in items):
                        return set(items)
                    return None
                m = _ON_INLINE_ONE.match(line)
                if m:
                    return {m.group(1)}
                return None
            if line == "jobs:":
                break
            continue
        if in_on:
            if line.startswith("    "):
                continue
            m = _ON_MAPPING_KEY.match(line)
            if not m or not line.startswith("  ") or line.startswith("   "):
                return None
            collected.add(m.group(1))
    if in_on:
        return collected or None
    return None


_DISPATCH_EVENT = re.compile(r"^github\.event_name\s*==\s*['\"]workflow_dispatch['\"]$")
_POSITIVE_INPUT = re.compile(r"^inputs\.[A-Za-z_][\w-]*(\s*==\s*true)?$")


def _plain_dispatch_only(if_expr: str) -> bool:
    """True only for an allowlisted positive dispatch-only `if:`.

    Allowed: `github.event_name == 'workflow_dispatch'` and optional `inputs.<id>` or
    `inputs.<id> == true`, joined only by `&&`. No `||`, `!`, `!=`, parentheses,
    chained `==`, or any term the parser does not fully understand.
    """
    expr = if_expr.strip()
    if expr.startswith("${{") and expr.endswith("}}"):
        expr = expr[3:-2].strip()
    if "${{" in expr or "}}" in expr:
        return False
    expr = re.sub(r"\s+", " ", expr)
    if not expr or "||" in expr:
        return False
    terms = [t.strip() for t in expr.split("&&")]
    if not terms or any(not t for t in terms):
        return False
    saw_dispatch = False
    for t in terms:
        if _DISPATCH_EVENT.fullmatch(t):
            saw_dispatch = True
        elif _POSITIVE_INPUT.fullmatch(t):
            continue
        else:
            return False
    return saw_dispatch


def na_on_pull_request_reason(if_expr: str | None, workflow_has_pr: bool) -> str | None:
    """Why this job cannot run on a pull_request, or None if it can (or we cannot tell)."""
    if not workflow_has_pr:
        return "N/A (workflow does not run on pull_request)"
    if not if_expr:
        return None
    if _plain_dispatch_only(if_expr):
        return "N/A (dispatch-only; cannot run on a pull_request)"
    return None


def job_na_reasons(workflows: list[dict]) -> dict[tuple[str, str], str]:
    """(workflow path, job name) -> N/A reason for jobs that cannot run on a pull_request."""
    out: dict[tuple[str, str], str] = {}
    for wf in workflows:
        has_pr = workflow_runs_on_pull_request(wf["text"])
        for j in _parse_jobs(wf["text"]):
            reason = na_on_pull_request_reason(j["if"], has_pr)
            if reason:
                out[(wf["path"], j["name"] or j["id"])] = reason
    return out


def workflow_display_name(path: str, yaml_text: str) -> str:
    m = re.search(r"^name:\s*['\"]?(.+?)['\"]?\s*$", yaml_text, re.MULTILINE)
    return m.group(1) if m else path


def required_jobs(workflows: list[dict]) -> list[tuple[str, str]]:
    """(workflow path, check-run name) for every job of every workflow, in order."""
    out: list[tuple[str, str]] = []
    for wf in workflows:
        for n in job_check_names(wf["text"]):
            if (wf["path"], n) not in out:
                out.append((wf["path"], n))
    return out


def normalize_workflow_path(path: str | None) -> str | None:
    """`path` from the workflow-runs API, without any `@ref` suffix."""
    return path.split("@", 1)[0] if path else None


def suite_to_workflow(workflow_runs: list[dict]) -> dict[int, str]:
    """check_suite_id -> workflow path, from the Actions workflow runs for the head sha."""
    out: dict[int, str] = {}
    for w in workflow_runs:
        sid, path = w.get("check_suite_id"), normalize_workflow_path(w.get("path"))
        if sid is not None and path:
            out[sid] = path
    return out


def commit_author_display(commits: list[dict]) -> list[str]:
    """Author and Co-authored-by names as written, unique case-insensitively, sorted."""
    seen: dict[str, str] = {}
    for c in commits:
        commit = c.get("commit") or {}
        names = [(commit.get("author") or {}).get("name") or ""]
        names += CO_AUTHOR.findall(commit.get("message") or "")
        for n in names:
            n = n.strip()
            if n:
                seen.setdefault(n.lower(), n)
    return sorted(seen.values(), key=str.lower)


def off_roster(authors: list[str], roster=ROSTER) -> list[str]:
    known = {r.lower() for r in roster}
    return [a for a in authors if a.lower() not in known]


def commit_author_names(commits: list[dict]) -> set[str]:
    """Git author names and Co-authored-by names of every commit, lowercased."""
    names: set[str] = set()
    for c in commits:
        commit = c.get("commit") or {}
        name = (commit.get("author") or {}).get("name")
        if name:
            names.add(name.strip().lower())
        for co in CO_AUTHOR.findall(commit.get("message") or ""):
            names.add(co.strip().lower())
    return names


def device_line(body: str | None) -> str | None:
    """`NOT TESTED` or `TESTED` when some body line starts exactly with `Device: NOT TESTED` or
    `Device: TESTED`; None otherwise. `Device check: NOT TESTED` and indented lines never match."""
    for line in (body or "").replace("\r\n", "\n").split("\n"):
        found = DEVICE_LINE.match(line)
        if found:
            return found.group(1)
    return None


def parse_sign(body: str | None, head_sha: str) -> tuple[str | None, str | None]:
    """(Name, None) for a valid sign at `head_sha`, else (None, why-not) or (None, None) if not a sign."""
    if not body:
        return None, None
    lines = [l.strip() for l in body.replace("\r\n", "\n").split("\n")]
    first = next((l for l in lines if l), "")
    if not first.startswith("SIGN "):
        return None, None
    m = SIGN_LINE.match(first)
    if not m:
        return None, f"malformed first line {first[:40]!r}"
    sha, name = m.group(1).lower(), m.group(2)
    if not head_sha.lower().startswith(sha):
        return None, f"{name}: sign at {sha[:8]}, head is {head_sha[:8]}"
    return name, None


def collect_signs(postings: list[dict], head_sha: str, authors: set[str]) -> dict:
    """postings: {"kind": "comment"|"review", "body": str, "state": str|None, "url": str}."""
    valid: dict[str, str] = {}
    rejected: list[str] = []
    for p in postings:
        name, why = parse_sign(p.get("body"), head_sha)
        if name is None:
            if why and why not in rejected:
                rejected.append(why)
            continue
        if p.get("kind") == "review" and (p.get("state") or "").upper() == "CHANGES_REQUESTED":
            rejected.append(f"{name}: review requests changes")
            continue
        if name.lower() in authors:
            rejected.append(f"{name}: is a commit author on this PR")
            continue
        valid.setdefault(name, p.get("url") or "")
    return {"valid": valid, "rejected": rejected}


SKIP_GREEN = "skipped (path filter, changes passed)"
UNMAPPED = "unmapped (check run's suite has no workflow run)"


def latest_runs(check_runs: list[dict], head_sha: str | None = None,
                suites: dict[int, str] | None = None) -> dict[tuple, dict]:
    """Latest check run per (workflow path, name), by started_at then id. Runs at another sha are
    ignored. A run whose check suite maps to no workflow run is keyed (None, name)."""
    best: dict[tuple, dict] = {}
    suites = suites or {}
    for r in check_runs:
        if head_sha and r.get("head_sha") and r["head_sha"].lower() != head_sha.lower():
            continue
        wf = suites.get((r.get("check_suite") or {}).get("id"))
        k = (wf, r.get("name"))
        key = (r.get("started_at") or "", r.get("id") or 0)
        cur = best.get(k)
        if cur is None or key > (cur.get("started_at") or "", cur.get("id") or 0):
            best[k] = r
    return best


def assess_checks(check_runs: list[dict], required: list[tuple[str, str]], head_sha: str | None = None,
                  workflow_runs: list[dict] | None = None, labels: dict[str, str] | None = None,
                  na_reasons: dict[tuple[str, str], str] | None = None) -> dict:
    """Required jobs are keyed by (workflow path, job name), so the same job name in two workflows
    never collides (Sentinel). A skipped iOS job counts as green only when ios.yml's own `changes`
    job concluded success at the same head sha. Any other skip, a skip with that `changes` missing,
    pending or not successful, or a run that can't be mapped to its workflow, is not green.
    A job that cannot run on a pull_request is N/A (listed, not hidden, not a missing check)."""
    runs = latest_runs(check_runs, head_sha, suite_to_workflow(workflow_runs or []))
    labels = labels or {}
    na_reasons = na_reasons or {}
    ch = runs.get((IOS_WORKFLOW, CHANGES_JOB))
    changes_passed = bool(ch and ch.get("status") == "completed" and ch.get("conclusion") == "success")
    rows, bad = [], []
    for wf, name in required:
        label = f"{labels.get(wf, wf)} / {name}"
        if (wf, name) in na_reasons:
            rows.append((label, na_reasons[(wf, name)]))
            continue
        r = runs.get((wf, name))
        if r is None:
            state = UNMAPPED if (None, name) in runs else "missing"
        elif r.get("status") != "completed":
            state = r.get("status") or "pending"
        else:
            state = r.get("conclusion") or "no conclusion"
            if state == "skipped" and not (wf == IOS_WORKFLOW and name == CHANGES_JOB):
                if wf != IOS_WORKFLOW:
                    state = "skipped (not an iOS path-filter job)"
                else:
                    state = SKIP_GREEN if changes_passed else "skipped (changes did not pass at this head)"
        rows.append((label, state))
        if state not in ("success", SKIP_GREEN):
            bad.append(f"{label}: {state}")
    return {"rows": rows, "bad": bad}


def overlap(pr_files: list[str], base_files: list[str]) -> list[str]:
    return sorted(set(pr_files) & set(base_files))


def verdict(*, pr: dict, checks: dict, signs: dict, overlap_files: list[str], warnings: list[str]) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    if pr.get("state") != "open":
        reasons.append(f"PR is {pr.get('state')}{' (merged)' if pr.get('merged') else ''}")
    if pr.get("base") != TARGET_BASE:
        reasons.append(f"base is {pr.get('base')}, not {TARGET_BASE}")
    if checks["bad"]:
        reasons.append(f"{len(checks['bad'])} required check(s) not green")
    if not pr.get("device_line"):
        reasons.append("PR body has no line starting `Device: NOT TESTED` (or `Device: TESTED`)")
    n = len(signs["valid"])
    if n < REQUIRED_SIGNS:
        reasons.append(f"{n}/{REQUIRED_SIGNS} non-author signs at this head")
    if overlap_files:
        reasons.append(f"{len(overlap_files)} file(s) also changed on the base since the merge-base: "
                       "forward-merge or confirm the hunks are disjoint")
    # Truncated data can hide an author or a file: fail closed.
    reasons += [w for w in warnings if w.startswith("INCOMPLETE")]
    return (not reasons), reasons


def render(report: dict) -> str:
    pr, checks, signs = report["pr"], report["checks"], report["signs"]
    out = [f"Merge readiness for #{pr['number']} at {pr['head_sha']} (report-only)",
           f"Base {pr['base']} at {report['base_head'][:8]}, merge-base {report['merge_base'][:8]}",
           f"Commit authors on the PR: {', '.join(report['author_display']) or '(none)'}",
           ""]
    n_na = sum(1 for _, s in checks["rows"] if s.startswith("N/A"))
    n_req = len(checks["rows"]) - n_na
    n_green = n_req - len(checks["bad"])
    head = f"Checks ({n_green}/{n_req} green"
    out.append(head + (f", {n_na} N/A):" if n_na else "):"))
    marks = []
    for n, s in checks["rows"]:
        mark = "n/a" if s.startswith("N/A") else ("ok " if s in ("success", SKIP_GREEN) else "NO ")
        marks.append(f"  {mark} {n}: {s}")
    out += marks
    out += ["", f"Device line: {('Device: ' + pr['device_line']) if pr.get('device_line') else 'missing'}"]
    out += ["", f"Signs ({len(signs['valid'])}/{REQUIRED_SIGNS} non-author at {pr['head_sha'][:8]}):"]
    out += [f"  ok  {n} {u}".rstrip() for n, u in signs["valid"].items()] or ["  (none)"]
    out += [f"  --  not counted: {r}" for r in signs["rejected"]]
    ov = report["overlap"]
    out += ["", f"Overlap with {pr['base']} since the merge-base ({len(ov)} file(s); "
            f"PR changes {report['pr_file_count']}, base changed {report['base_file_count']}):"]
    out += [f"  {f}" for f in ov] or ["  (none)"]
    for w in report["warnings"]:
        out.append(f"WARNING: {w}")
    out.append("")
    out.append("READY" if report["ready"] else "NOT READY: " + "; ".join(report["reasons"]))
    return "\n".join(out)


def build_report(*, pr: dict, base_head: str, merge_base: str, workflows: list[dict], check_runs: list[dict],
                 commits: list[dict], postings: list[dict], pr_files: list[str], base_files: list[str],
                 workflow_runs: list[dict] | None = None, warnings: list[str] | None = None) -> dict:
    warnings = list(warnings or [])
    required = required_jobs(workflows)
    if not required:
        warnings.append("INCOMPLETE: no job names found in ios.yml/ci.yml")
    labels = {wf["path"]: workflow_display_name(wf["path"], wf["text"]) for wf in workflows}
    authors = commit_author_names(commits)
    display = commit_author_display(commits)
    outside = off_roster(display)
    if outside:
        # Report-only (Atlas): never a reason, never changes READY or NOT READY.
        warnings.append(f"ROSTER: commit author(s) outside the bot roster ({', '.join(ROSTER)}): "
                        f"{', '.join(outside)}. Report-only; does not change the verdict")
    checks = assess_checks(check_runs, required, pr["head_sha"], workflow_runs or [], labels,
                           job_na_reasons(workflows))
    signs = collect_signs(postings, pr["head_sha"], authors)
    ov = overlap(pr_files, base_files)
    ready, reasons = verdict(pr=pr, checks=checks, signs=signs, overlap_files=ov, warnings=warnings)
    return {"pr": pr, "base_head": base_head, "merge_base": merge_base,
            "required": [list(r) for r in required],
            "author_names": sorted(authors), "author_display": display, "off_roster_authors": outside, "checks": checks, "signs": signs, "overlap": ov,
            "pr_file_count": len(set(pr_files)), "base_file_count": len(set(base_files)),
            "warnings": warnings, "ready": ready, "reasons": reasons}


# ---------- GitHub fetch (gh CLI, read-only unless --comment) ----------

def gh_api(path: str):
    out = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github+json", path],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def gh_list(path: str, key: str | None = None, limit_pages: int = 30) -> list:
    items: list = []
    sep = "&" if "?" in path else "?"
    for page in range(1, limit_pages + 1):
        data = gh_api(f"{path}{sep}per_page={PAGE}&page={page}")
        chunk = data.get(key, []) if key else data
        items += chunk
        if len(chunk) < PAGE:
            break
    return items


def fetch(repo: str, number: int) -> dict:
    p = gh_api(f"repos/{repo}/pulls/{number}")
    head = p["head"]["sha"]
    base_ref = p["base"]["ref"]
    pr = {"number": number, "head_sha": head, "base": base_ref, "state": p["state"],
          "merged": bool(p.get("merged_at")), "device_line": device_line(p.get("body"))}
    warnings: list[str] = []
    base_head = gh_api(f"repos/{repo}/commits/{base_ref}")["sha"]
    cmp_pr = gh_api(f"repos/{repo}/compare/{base_head}...{head}?per_page=1")
    merge_base = cmp_pr["merge_base_commit"]["sha"]
    workflows = []
    for path in WORKFLOWS:
        c = gh_api(f"repos/{repo}/contents/{path}?ref={base_head}")
        workflows.append({"path": path, "text": base64.b64decode(c["content"]).decode()})
    check_runs = gh_list(f"repos/{repo}/commits/{head}/check-runs?filter=all", key="check_runs")
    # Map each check run to its workflow via its check suite (Sentinel). Unmapped runs never count.
    workflow_runs = [{"check_suite_id": w.get("check_suite_id"), "path": w.get("path"), "name": w.get("name"),
                      "head_sha": w.get("head_sha")}
                     for w in gh_list(f"repos/{repo}/actions/runs?head_sha={head}", key="workflow_runs")]
    commits = gh_list(f"repos/{repo}/pulls/{number}/commits", limit_pages=3)
    if len(commits) >= MAX_PR_COMMITS:
        warnings.append(f"INCOMPLETE: PR has {len(commits)}+ commits; GitHub lists at most {MAX_PR_COMMITS}, "
                        "so some authors may be unseen")
    postings = [{"kind": "comment", "body": c.get("body"), "url": c.get("html_url")}
                for c in gh_list(f"repos/{repo}/issues/{number}/comments")]
    postings += [{"kind": "review", "body": r.get("body"), "state": r.get("state"), "url": r.get("html_url")}
                 for r in gh_list(f"repos/{repo}/pulls/{number}/reviews")]
    pr_files = [f["filename"] for f in gh_list(f"repos/{repo}/pulls/{number}/files")]
    if p.get("changed_files") and len(pr_files) < p["changed_files"]:
        warnings.append(f"INCOMPLETE: listed {len(pr_files)} of {p['changed_files']} PR files")
    base_files: list[str] = []
    if pr["merged"] or pr["state"] != "open":
        warnings.append("PR is not open: overlap not computed (the base already contains or dropped it)")
    elif merge_base != base_head:
        cmp_base = gh_api(f"repos/{repo}/compare/{merge_base}...{base_head}")
        base_files = [f["filename"] for f in cmp_base.get("files", [])]
        if len(base_files) >= MAX_COMPARE_FILES:
            warnings.append(f"INCOMPLETE: base changed {len(base_files)}+ files since the merge-base "
                            f"(compare lists at most {MAX_COMPARE_FILES}); overlap may be missing files")
    return dict(pr=pr, base_head=base_head, merge_base=merge_base, workflows=workflows, check_runs=check_runs,
                workflow_runs=workflow_runs,
                commits=commits, postings=postings, pr_files=pr_files, base_files=base_files, warnings=warnings)


def default_repo() -> str:
    out = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                         check=True, capture_output=True, text=True).stdout.strip()
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Report-only merge readiness for one PR (#556).")
    ap.add_argument("pr", type=int)
    ap.add_argument("--repo", help="owner/name (default: gh repo view)")
    ap.add_argument("--json", action="store_true", help="print the report as JSON")
    ap.add_argument("--comment", action="store_true", help="also post the text report as a PR comment")
    args = ap.parse_args(argv)
    try:
        repo = args.repo or default_repo()
        report = build_report(**fetch(repo, args.pr))
    except (subprocess.CalledProcessError, KeyError, ValueError) as e:
        detail = getattr(e, "stderr", "") or str(e)
        print(f"merge-readiness: could not fetch #{args.pr}: {detail.strip()}", file=sys.stderr)
        return 1
    text = render(report)
    print(json.dumps(report, indent=2) if args.json else text)
    if args.comment:
        subprocess.run(["gh", "pr", "comment", str(args.pr), "--repo", repo, "--body-file", "-"],
                       input=text + "\n", text=True, check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
