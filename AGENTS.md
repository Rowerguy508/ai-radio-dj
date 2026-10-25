# AeroDJ coding-agent instructions

These instructions apply to all automated and human contributors in this repository. See docs/ENGINEERING_STANDARDS.md for the enforceable review policy.

## Execution contract
1. Read docs/AERODJ_IOS_ROADMAP.md and the specific GitHub issue before editing. Reproduce the issue, inspect actual sources and dependencies, and scope changes narrowly.
2. One GitHub issue -> one short-lived branch -> one focused PR. Put unrelated work in another issue. Use conventional commits, e.g. feat(ios): ..., fix(api): ..., test(core): ....
3. Never write code directly to main, force-push main, self-approve, or self-merge. Another human/agent working independently of the author must inspect the actual diff and tests. A second persona of the same agent is not independent.
4. PRs require a linked issue, summary, decision/risks, manual validation, automated tests with commands and CI URLs, data/privacy implications, deployment or rollback. No check-box theater or invented run results.
5. Follow test pyramid: domain unit tests and negative tests, adapter integration tests, simulator smoke tests, then real-device checks. CI must be green on the PR head. If iOS build cannot run locally, CI proof is mandatory.
6. Never include generated .build, DerivedData, binaries, auth keys, .env or personal data in commits. Secrets belong in protected server configuration. Protect Supabase user-scoped queries; service_role bypasses RLS.
7. Apple native first: SwiftUI, MusicKit, EventKit, user-selected Files and Share Extension. No arbitrary Apple Mail/Messages scraping, DRM capture, or unsupported entitlements. Dessa stays a disabled stub until official documented access.
8. For all voice work, document TTS characters/minutes, LLM token usage, estimated per-user cost and quotas. Tests use mocks; no paid provider usage without explicit enablement.
9. Review feedback: respond in GitHub with a commit SHA, reproduced result or technical rationale for each thread; don't resolve reviewer threads on the reviewer's behalf.
10. No work counts as done until issue acceptance criteria, CI, independent review, and linked PR are complete. Update GitHub issue and PR, not an external status document.
11. All agents share one GitHub account: begin every comment, review and commit body with your role tag and end comments with your signature (see the team table in docs/ENGINEERING_STANDARDS.md). Push only to branches you own; announce on the PR before pushing to anyone else's.

## Priority rule
Before starting new work, check open `[SECURITY/P0]` issues. No work that ingests personal data (Calendar, shared Mail/Messages, Obsidian) or sends it to the backend may merge while a P0 security issue affecting that path is open.
