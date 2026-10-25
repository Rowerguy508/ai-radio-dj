# AeroDJ Engineering Standards

## Roles
**Implementer:** junior coding agent or developer. Writes code/tests, explains implementation, responds to findings. Cannot approve/merge own work.

**Senior reviewer:** independent reviewer of architecture, correctness, security, privacy, performance, cost and failure behavior. Uses actual code diff and evidence, not PR description alone. Reviews with severity P0 security/release blocker, P1 premerge correctness, P2 maintainability or later improvement. Only a reviewer independent of the PR author can satisfy approval.

**Repository owner:** configures branch protection/rulesets, reviewer permissions, Apple signing, protected secrets, and authorizes release.

## Required GitHub flow
1. Issue has scope, risks, dependencies, implementation tasks, measurable acceptance criteria. Label by type and sprint.
2. Create `feat/<issue-number>-short-name` or `fix/<issue-number>-short-name` from current main. Draft PR early.
3. Make minimal changes. Prefer <400 net changed source lines per PR unless explained. Never combine unrelated sprint issues.
4. Tests are written alongside behavior: positive, negative, permission-denied, revoked, offline, timeout, malformed payload, user isolation where applicable. Every bug gets regression coverage.
5. CI runs Swift package unit tests + iOS Simulator build, web typecheck/lint/build when touched, and the `Reject generated artifacts and credentials` step in `ci.yml` on every PR. Secret scanning with push protection is an owner setting (see below). TestFlight/manual device evidence is additionally required for hardware/audio-specific features.
6. PR must pass the template, all blocking CI jobs, and independent approval. No red builds, pending review, unresolved P0/P1 comments or unverified test claims at merge.
7. Merge via squash, retain issue link, verify main CI, close issue only after acceptance criteria demonstrated. Deployment/release via separate tracked issue.

## Mandatory review checklist
- Behavior correct? Edge cases/failure recovery? Swift concurrency cancellation, actor safety, type correctness and memory ownership?
- Source scoped? Data minimization, explicit consent, local retention and revocation? Never narrate disallowed context.
- Authentication enforced on server? Supabase service_role and RLS separation, rate limits, log PII and secret safety?
- MusicKit compliant? Background AVAudioSession, interruptions, remote commands, subscriptions, licensing?
- Voice naturalness and operational cost measured? No unlimited streaming, hard per-user budget ceiling, retry/circuit breaker?
- UI accessible and responsive without hardcoded Duo dimensions? VoiceOver, Dynamic Type, reduced motion?
- Tests meaningful? Clean clone works? Reproducible Xcode project included? Binary/generated artifacts absent?
- Rollback documented, migrations safe and existing Next.js prototype unaffected?

## GitHub settings to enforce (owner action)
Protect `main` with a GitHub ruleset or branch protection:
- Pull request required, **at least 1 approving review from someone other than the author**; optionally require code owner review for protected areas.
- Dismiss stale approvals on new commits and require all review threads resolved.
- Require iOS simulator build, Swift core tests and applicable web CI checks; check exact check names from a completed workflow before configuring.
- A required check must come from a workflow **without top-level `paths` filters**; otherwise PRs that don't touch those paths wait forever on a check that never reports. Gate inside the workflow instead (a skipped job reports success).
- Enable secret scanning with push protection.
- No direct push or force-push; do not permit bypasses for automation, except explicitly audited emergency process.
- Block deleting the protected branch and enforce up-to-date branch check.
- Set CODEOWNERS with *actual independent GitHub user/team*, not an invented placeholder, when reviewer is chosen.

## Reviewer identity (current state and plan)
**Current state:** the repository has one collaborator (`Rowerguy508`), and every agent — lead, principal reviewer and implementer — acts through that account. GitHub cannot distinguish them, so the account cannot approve or request changes on its own PRs, and "independent approval" is **procedural, not technically enforced**. Reviews are posted as COMMENT reviews; nobody may describe one as an enforced block or an approval.

**Interim merge procedure:** a PR may merge only by owner bypass, and only when (1) required CI is green on the head commit, (2) the independent review comment states no open P0/P1, and (3) the merger posts a comment linking that review and stating the reason for bypass. Bypasses are audited in the ruleset insights.

**Planned (owner action):** give each agent its own identity — the principal reviewer a machine-user collaborator with Write access (the one free machine account GitHub's terms allow), the lead and implementer GitHub Apps — each credential held only in that agent's environment. Then set `CODEOWNERS` to the reviewer identity, require code-owner review, and retire the bypass procedure. Until then, AGENTS.md rule 3 is a rule of conduct, not a control.

**Important:** files and templates are guidance; enforcement requires GitHub repository settings/rulesets and separate identities.

## Reviewer communication
The senior reviewer posts line-specific findings where possible with P0/P1/P2 severity, explanation, expected fix and verification. The author replies with exact commits/CI runs. Escalate disagreements in GitHub discussion; no silent merges and no endless agent self-review loops. Keep all project decisions, comments and artifacts in GitHub.
