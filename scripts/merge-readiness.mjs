import { readFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Merge gate for PRs into integration/device-duo.
//
// A sign is one line, on its own: `SIGN <sha> -Name`.
// <sha> is the full head SHA or its first 8 hex characters. Name is one word.
// Older free-form lines ("Signed at", "Sign (Name) at", "Atlas sign at") do not count.

export const TARGET_BASE = 'integration/device-duo'
export const REQUIRED_SIGN_COUNT = 2

// Who may post a sign. Edit TRUSTED_LOGINS here when a trusted person is not
// already OWNER, MEMBER, or COLLABORATOR. Agents share Rowerguy508 with the
// PR author, so "non-author" stays the -Name on the comment, not this login.
export const TRUSTED_LOGINS = ['Rowerguy508']
export const TRUSTED_ASSOCIATIONS = ['OWNER', 'MEMBER', 'COLLABORATOR']

// Check-run name GitHub shows: the job's `name:`, or the job id when it has none.
export function checkNamesFromWorkflow(yaml) {
  const names = []
  let inJobs = false
  let currentJob = null
  let jobName = null
  let sawSteps = false
  const flush = () => {
    if (!currentJob) return
    names.push(jobName || currentJob)
    currentJob = null
    jobName = null
    sawSteps = false
  }
  for (const line of String(yaml || '').split(/\r?\n/)) {
    if (!inJobs) {
      if (line === 'jobs:') inJobs = true
      continue
    }
    if (line.length > 0 && !line.startsWith(' ') && !line.startsWith('#')) {
      flush()
      break
    }
    const jobMatch = line.match(/^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$/)
    if (jobMatch) {
      flush()
      currentJob = jobMatch[1]
      continue
    }
    if (!currentJob || sawSteps) continue
    if (/^    steps:\s*(?:#.*)?$/.test(line)) {
      sawSteps = true
      continue
    }
    const nameMatch = line.match(/^    name:\s*(.+?)\s*(?:#.*)?$/)
    if (nameMatch && !jobName) {
      let value = nameMatch[1].trim()
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1)
      }
      jobName = value
    }
  }
  flush()
  return names
}

export function requiredCheckNamesFromWorkflows(iosYaml, ciYaml) {
  const ci = checkNamesFromWorkflow(ciYaml)
  const ios = checkNamesFromWorkflow(iosYaml)
  if (ci.length === 0 || ios.length === 0) {
    return { ok: false, names: [], ci, ios }
  }
  return { ok: true, names: [...ci, ...ios], ci, ios }
}

function workflowPath(name) {
  return join(dirname(fileURLToPath(import.meta.url)), '..', '.github', 'workflows', name)
}

export function requiredCheckNamesFromDisk() {
  return requiredCheckNamesFromWorkflows(
    readFileSync(workflowPath('ios.yml'), 'utf8'),
    readFileSync(workflowPath('ci.yml'), 'utf8'),
  )
}

// Own line (`-Echo`) or the end of the last line (`… evidence. -Fry`).
// The dash has to start the line or follow whitespace, so `pass-through` is not a name.
const SIGNATURE_AT_END = /(?:^|\s)-\s*([A-Za-z][\w-]*)[ \t]*$/
// Exact sign line. SIGN is uppercase. The sha is 8 or 40 hex digits.
const SIGN_LINE = /^SIGN ([0-9a-fA-F]{8}|[0-9a-fA-F]{40}) -([A-Za-z][A-Za-z0-9]*)$/

const DEVICE_NOT_TESTED = /^Device: NOT TESTED\b/
const DEVICE_TESTED = /^Device: TESTED\b/

function signatureOnLastLine(text) {
  if (!text) return null
  const lines = String(text).split(/\r?\n/)
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim() === '') continue
    const match = lines[i].match(SIGNATURE_AT_END)
    return match ? match[1] : null
  }
  return null
}

export function authorFromBody(body) {
  return signatureOnLastLine(body)
}

export function hasDeviceLine(body) {
  if (!body) return false
  return body.split(/\r?\n/).some((line) => DEVICE_NOT_TESTED.test(line) || DEVICE_TESTED.test(line))
}

export function terminalSignature(text) {
  return signatureOnLastLine(text)
}

export function canonicalSignLines(text) {
  const found = []
  for (const raw of String(text || '').split(/\r?\n/)) {
    const match = raw.trim().match(SIGN_LINE)
    if (!match) continue
    found.push({ sha: match[1].toLowerCase(), name: match[2] })
  }
  return found
}

export function shaMatches(anchor, head) {
  if (!anchor || !head) return false
  const prefix = anchor.toLowerCase()
  const full = head.toLowerCase()
  if (!/^[0-9a-f]{40}$/.test(full)) return false
  if (/^[0-9a-f]{40}$/.test(prefix)) return prefix === full
  if (/^[0-9a-f]{8}$/.test(prefix)) return full.startsWith(prefix)
  return false
}

export function signLineFor(headSha) {
  return `SIGN ${String(headSha || '').slice(0, 8)} -YourName`
}

// "No blockers" is not a blocker. Any other use of the word is.
export function containsBlocker(text) {
  const stripped = String(text || '').replace(/\bno\s+blockers?\b/gi, '')
  return /\bblockers?\b/i.test(stripped)
}

// A promise, a refusal, or a negative claim is not a sign, even if a
// canonical line is also present. "Comment, not approval" is not one of these.
export function isDeferredSign(text) {
  const body = text || ''
  return (
    /\b(?:i'll|i will|we'll|we will|will)\s+sign\b/i.test(body) ||
    /\bmy sign posts\b/i.test(body) ||
    /\bsign\s+posts\b/i.test(body) ||
    /\bnot a sign\b/i.test(body) ||
    /\bdo not sign\b/i.test(body) ||
    /\bnobody has signed\b/i.test(body) ||
    /\bno one has signed\b/i.test(body) ||
    containsBlocker(body)
  )
}

function isBot(posting) {
  const type = (posting.userType || '').toLowerCase()
  const login = posting.userLogin || ''
  return type === 'bot' || /\[bot\]$/i.test(login)
}

export function isTrustedPoster(posting) {
  const login = posting?.userLogin || ''
  if (TRUSTED_LOGINS.some((allowed) => allowed.toLowerCase() === login.toLowerCase())) return true
  const association = (posting?.authorAssociation || '').toUpperCase()
  return TRUSTED_ASSOCIATIONS.includes(association)
}

// Missing head repo, a fork flag, or a different repository all fail closed.
export function headComesFromFork(pr) {
  const head = pr?.head?.repo
  const base = pr?.base?.repo
  if (!head?.full_name || !base?.full_name) return true
  if (head.fork === true) return true
  return head.full_name.toLowerCase() !== base.full_name.toLowerCase()
}

function isChangesRequested(posting) {
  return (posting.state || '').toUpperCase() === 'CHANGES_REQUESTED'
}

// Only a canonical SIGN line counts. Promises, blockers, and
// CHANGES_REQUESTED reviews do not, even when they contain that line.
// There is no commit_id or timestamp fallback.
function classifyPosting(posting, headSha) {
  const lines = canonicalSignLines(posting.body)
  if (isChangesRequested(posting) || isDeferredSign(posting.body)) {
    return { rejected: lines.length > 0, lines: [] }
  }
  return { rejected: false, lines }
}

export function collectSigns(postings, { headSha, author }) {
  const atHead = new Map()
  const stale = []
  const ignoredAuthor = []
  const ignoredUntrusted = []
  const ignoredDisqualified = []
  for (const posting of postings || []) {
    if (isBot(posting)) continue
    const decision = classifyPosting(posting, headSha)
    if (decision.rejected) {
      ignoredDisqualified.push(posting.userLogin || 'unknown')
      continue
    }
    for (const line of decision.lines) {
      const matchesHead = shaMatches(line.sha, headSha)
      if (!isTrustedPoster(posting)) {
        if (matchesHead) {
          ignoredUntrusted.push({
            name: line.name,
            login: posting.userLogin || 'unknown',
            association: posting.authorAssociation || 'NONE',
          })
        }
        continue
      }
      if (author && line.name.toLowerCase() === author.toLowerCase()) {
        if (matchesHead) ignoredAuthor.push(line.name)
        continue
      }
      if (matchesHead) {
        if (!atHead.has(line.name.toLowerCase())) atHead.set(line.name.toLowerCase(), line.name)
        continue
      }
      stale.push({ name: line.name, sha: line.sha })
    }
  }
  const staleOnly = []
  const seen = new Set()
  for (const item of stale) {
    if (atHead.has(item.name.toLowerCase())) continue
    const key = `${item.name.toLowerCase()}@${item.sha}`
    if (seen.has(key)) continue
    seen.add(key)
    staleOnly.push(item)
  }
  return {
    atHead: [...atHead.values()],
    stale: staleOnly,
    ignoredAuthor,
    ignoredUntrusted,
    ignoredDisqualified,
  }
}

function recency(run) {
  const stamp = Date.parse(run.completedAt || run.startedAt || run.createdAt || '')
  return Number.isFinite(stamp) ? stamp : 0
}

function latestRun(runs, name) {
  const matches = (runs || []).filter((run) => run.name === name)
  const actions = matches.filter((run) => !run.appSlug || run.appSlug === 'github-actions')
  const pool = actions.length > 0 ? actions : matches
  let best = null
  for (const run of pool) {
    if (!best || recency(run) > recency(best) || (recency(run) === recency(best) && (run.id || 0) > (best.id || 0))) {
      best = run
    }
  }
  return best
}

export function assessChecks(runs, names) {
  const missing = []
  const required = names || requiredCheckNamesFromDisk().names
  for (const name of required) {
    const run = latestRun(runs, name)
    if (!run) {
      missing.push(`${name} (no check run at this head)`)
      continue
    }
    if (run.status !== 'completed') {
      missing.push(`${name} (${run.status || 'not completed'})`)
      continue
    }
    if (run.conclusion !== 'success') {
      missing.push(`${name} (${run.conclusion || 'no conclusion'})`)
    }
  }
  return { ok: missing.length === 0, missing }
}

export function readinessProblems({
  headSha,
  baseRef,
  body,
  postings,
  headCommittedAt,
  checkRuns,
  fork = false,
  headRepo = '',
  baseRepo = '',
  requiredCheckNames,
}) {
  if (baseRef && baseRef !== TARGET_BASE) {
    return {
      applies: false,
      ok: true,
      lines: [
        `merge-readiness: base is ${baseRef}, not ${TARGET_BASE}, so this gate does not apply.`,
      ],
    }
  }

  const lines = []
  if (fork) {
    lines.push(
      `merge-readiness: head comes from a fork (${headRepo || 'unknown repository'}). This check fails closed on fork PRs. Push the branch to ${baseRepo || 'this repository'} and open the pull request from there. Do not merge.`,
    )
  }
  const author = authorFromBody(body)
  if (!author) {
    lines.push(
      'merge-readiness: PR body does not end with -Name (its own last line, or the end of the last line, for example -Nova). Without that, the author cannot be excluded. Add it. Until then this check fails closed.',
    )
  }

  if (!hasDeviceLine(body)) {
    lines.push(
      'merge-readiness: PR body must contain a line starting with "Device: NOT TESTED". "Device check: NOT TESTED …" does not count, and a mention in the middle of a sentence does not count. Add the line; do not treat simulator or Linux results as device evidence. A line starting with "Device: TESTED" is the device-tested form; recent PRs do not use a third wording.',
    )
  }

  const signs = collectSigns(postings, { headSha, author })
  if (signs.atHead.length < REQUIRED_SIGN_COUNT) {
    const found = signs.atHead.length > 0 ? ` Found ${signs.atHead.length} (${signs.atHead.join(', ')}).` : ''
    const stale =
      signs.stale.length > 0
        ? ` Stale signs that do not count: ${signs.stale.map((item) => `${item.name} at ${item.sha}`).join(', ')}.`
        : ''
    const ignored =
      signs.ignoredAuthor.length > 0 ? ` Ignored author sign from ${author}.` : ''
    const untrusted =
      signs.ignoredUntrusted.length > 0
        ? ` Ignored untrusted sign from ${signs.ignoredUntrusted
            .map((item) => `${item.login} (association ${item.association}, -${item.name})`)
            .join(', ')}. A sign counts only when that poster's author_association is OWNER, MEMBER, or COLLABORATOR, or their login is in TRUSTED_LOGINS in scripts/merge-readiness.mjs.`
        : ''
    const disqualified =
      signs.ignoredDisqualified.length > 0
        ? ' Ignored a SIGN line because the comment promises to sign later, is negative, contains a blocker, or the review is CHANGES_REQUESTED.'
        : ''
    const example = signLineFor(headSha)
    lines.push(
      `merge-readiness: need ${REQUIRED_SIGN_COUNT} signs at ${headSha.slice(0, 8)}; post a line exactly \`${example}\`.${found}${stale}${ignored}${untrusted}${disqualified} The line must be its own line. The sha is this head or its first 8 hex characters. Name is one word, and it cannot be the author's. The poster must be trusted. Do not self-approve.`,
    )
  }

  const loadedNames = requiredCheckNames || requiredCheckNamesFromDisk()
  const checkNames = Array.isArray(loadedNames) ? loadedNames : loadedNames.names
  const checksOkToRead = Array.isArray(loadedNames) || loadedNames.ok
  if (!checksOkToRead) {
    lines.push(
      'merge-readiness: could not read job names from .github/workflows/ios.yml and ci.yml on the base branch. Refusing to pass. Do not merge.',
    )
  }
  const checks = assessChecks(checkRuns, checkNames)
  if (checksOkToRead && !checks.ok) {
    lines.push(
      `merge-readiness: head ${headSha.slice(0, 8)} is missing green required checks: ${checks.missing.join(', ')}. These names are read from ci.yml and ios.yml on the base branch (a job's name:, or its id when it has no name). A skipped, failed, or cancelled job is not green. Wait for them at this sha, or push a fix. Do not merge.`,
    )
  }

  if (lines.length > 0) {
    lines.push('merge-readiness: do not merge and do not force-push.')
  }

  return { applies: true, ok: lines.length === 0, lines, author, signs, checks }
}

export function successLine(headSha, signs) {
  return `merge-readiness: head ${headSha} has ${signs.atHead.length} non-author signs (${signs.atHead.join(', ')}), a Device line, and green CI and iOS checks from the base-branch workflows.`
}

function assert(condition, message, failures) {
  if (!condition) failures.push(message)
}

export function selfTest() {
  const failures = []
  const head = 'c00e290f83622cfe788d3f2ccd8ba90a45e40dc9'
  const older = 'fa70a233aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  const other = '8f5b10d1ef7096d45a9836f4f88dde447f65c36f'

  const workflowNames = requiredCheckNamesFromDisk()
  assert(workflowNames.ok, 'ci.yml and ios.yml must yield job names', failures)
  assert(workflowNames.ios.length === 15, `expected 15 iOS checks from ios.yml, got ${workflowNames.ios.length}: ${workflowNames.ios.join(', ')}`, failures)
  assert(workflowNames.ci.length === 2, `expected 2 CI checks, got ${workflowNames.ci.join(', ')}`, failures)
  assert(
    workflowNames.ios.includes('Release archive (Xcode 27.2, unsigned)'),
    'Release archive check name missing',
    failures,
  )
  assert(workflowNames.ios.includes('core-tests'), 'heavy job id core-tests missing', failures)
  assert(workflowNames.ios.includes('changes'), 'changes job missing', failures)
  const parsedFixture = checkNamesFromWorkflow(`
name: Example
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
  heavy:
    needs: changes
    steps:
      - name: Run
  heavy-result:
    name: Heavy job (public)
    needs: [changes, heavy]
    steps:
      - name: Report
`)
  assert(
    parsedFixture.join('|') === 'changes|heavy|Heavy job (public)',
    `workflow parser got ${parsedFixture.join('|')}`,
    failures,
  )

  assert(hasDeviceLine('Device: NOT TESTED\n'), 'exact device line', failures)
  assert(
    hasDeviceLine('Intro\nDevice: NOT TESTED (needs owner AirPlay check)\n'),
    'parenthetical device line used on open PRs',
    failures,
  )
  assert(hasDeviceLine('Device: TESTED on the Duo, log attached\n'), 'device-tested line', failures)
  assert(
    !hasDeviceLine('Device check: NOT TESTED until run on the Duo (iPhone).\n'),
    'Device check: must not count',
    failures,
  )
  assert(
    !hasDeviceLine('Linux 2709/0. Device: NOT TESTED. Signs needed: Fry and Sentinel.\n'),
    'mid-sentence Device: must not count',
    failures,
  )

  assert(authorFromBody('Hello\n\n-Nova\n') === 'Nova', 'author is the last -Name line', failures)
  assert(authorFromBody('Hello\n- Linux, Swift 6.2\n') === null, 'a bullet sentence is not an author', failures)
  assert(
    authorFromBody('Linux 2709/0. Device: NOT TESTED. Signs needed: Fry and Sentinel. -Orion') === 'Orion',
    'author can sit at the end of the last line',
    failures,
  )
  assert(terminalSignature('still the pass-through\n') === null, 'a hyphenated word is not a signature', failures)

  const echoSignedOld = {
    body: 'Signed at fa70a233. Simulator only.\n\n-Echo',
    userLogin: 'Rowerguy508',
    userType: 'User',
    createdAt: '2026-11-14T23:58:28Z',
  }
  const echoResigned = {
    body: 'SIGN c00e290f -Echo',
    userLogin: 'Rowerguy508',
    userType: 'User',
    createdAt: '2026-11-15T07:53:59Z',
  }
  const fryNotYet = {
    body: "#506 at fa70a233: no blockers. I'll sign once iOS is green at this head.\n\nComment, not approval. Naturalness NOT TESTED; not device evidence. -Fry",
    userLogin: 'Rowerguy508',
    userType: 'User',
    createdAt: '2026-11-13T21:47:32Z',
  }
  const frySign = {
    body: `Notes.\nSIGN ${head} -Fry\n`,
    userLogin: 'Rowerguy508',
    userType: 'User',
    createdAt: '2026-11-15T07:59:53Z',
  }
  const sentinelPromise = {
    body: 'My sign posts at c00e290f once all 8 iOS jobs are green.\n\nComment, not approval.\n-Sentinel',
    userLogin: 'Rowerguy508',
    userType: 'User',
    createdAt: '2026-11-17T03:41:01Z',
    commitId: head,
  }
  const sentinelSign = {
    body: `SIGN ${head} -Sentinel\nComment, not approval.`,
    userLogin: 'Rowerguy508',
    userType: 'User',
    createdAt: '2026-11-17T04:31:57Z',
    commitId: head,
  }
  const vercel = {
    body: 'The latest updates on your projects.\n-Echo',
    userLogin: 'vercel[bot]',
    userType: 'Bot',
    createdAt: '2026-11-17T04:32:55Z',
  }

  const signed = collectSigns([echoResigned, frySign, sentinelSign, fryNotYet, echoSignedOld, vercel, sentinelPromise], {
    headSha: head,
    author: 'Nova',
    headCommittedAt: '2026-11-15T07:00:00Z',
  })
  assert(
    signed.atHead.slice().sort().join(',') === 'Echo,Fry,Sentinel',
    `current signs were ${signed.atHead.join(',')}`,
    failures,
  )
  assert(
    !signed.stale.some((item) => item.name === 'Echo'),
    'a later sign at the head drops the stale one for that name',
    failures,
  )
  assert(!signed.atHead.includes('Fry') || signed.atHead.filter((name) => name === 'Fry').length === 1, 'Fry counted once', failures)

  const authorExcluded = collectSigns([echoResigned, frySign], {
    headSha: head,
    author: 'Echo',
    headCommittedAt: '2026-11-15T07:00:00Z',
  })
  assert(
    authorExcluded.atHead.join(',') === 'Fry',
    `author Echo must not count, got ${authorExcluded.atHead.join(',')}`,
    failures,
  )
  assert(authorExcluded.ignoredAuthor.includes('Echo'), 'author sign should be reported', failures)
  assert(
    authorExcluded.ignoredUntrusted.length === 0,
    'a trusted login posting the author -Name is an author exclusion, not an untrusted poster',
    failures,
  )

  const trustedCollab = collectSigns(
    [
      {
        body: 'SIGN c00e290f -Echo',
        userLogin: 'studio-collab',
        userType: 'User',
        authorAssociation: 'COLLABORATOR',
        createdAt: '2026-11-15T08:00:00Z',
      },
    ],
    { headSha: head, author: 'Nova', headCommittedAt: '2026-11-15T07:00:00Z' },
  )
  assert(trustedCollab.atHead.join(',') === 'Echo', 'COLLABORATOR sign must count', failures)

  const untrusted = collectSigns(
    [
      {
        body: 'SIGN c00e290f -Echo',
        userLogin: 'outsider',
        userType: 'User',
        authorAssociation: 'NONE',
        createdAt: '2026-11-15T08:00:00Z',
      },
      {
        body: 'SIGN c00e290f -Fry',
        userLogin: 'drive-by',
        userType: 'User',
        authorAssociation: 'CONTRIBUTOR',
        createdAt: '2026-11-15T08:00:00Z',
      },
    ],
    { headSha: head, author: 'Nova', headCommittedAt: '2026-11-15T07:00:00Z' },
  )
  assert(untrusted.atHead.length === 0, `untrusted posters must not count, got ${untrusted.atHead.join(',')}`, failures)
  assert(
    untrusted.ignoredUntrusted.map((item) => item.login).sort().join(',') === 'drive-by,outsider',
    `untrusted signs were not reported: ${JSON.stringify(untrusted.ignoredUntrusted)}`,
    failures,
  )

  const onlyOld = collectSigns([echoSignedOld], {
    headSha: head,
    author: 'Nova',
    headCommittedAt: '2026-11-15T07:00:00Z',
  })
  assert(onlyOld.atHead.length === 0, 'an old free-form sign must not count', failures)
  assert(onlyOld.stale.length === 0, 'an old free-form sign is not a stale canonical sign', failures)

  const staleCanonical = collectSigns(
    [
      {
        body: 'SIGN fa70a233 -Echo',
        userLogin: 'Rowerguy508',
        userType: 'User',
      },
    ],
    { headSha: head, author: 'Nova' },
  )
  assert(staleCanonical.atHead.length === 0, 'canonical line at another sha must not count', failures)
  assert(
    staleCanonical.stale.some((item) => item.name === 'Echo' && item.sha === 'fa70a233'),
    `stale canonical sign missing: ${JSON.stringify(staleCanonical.stale)}`,
    failures,
  )

  const reviewByCommit = collectSigns(
    [
      {
        body: 'Looks right.\n-Orion',
        userLogin: 'Rowerguy508',
        userType: 'User',
        commitId: head,
        createdAt: '2026-11-15T08:00:00Z',
      },
    ],
    { headSha: head, author: 'Nova', headCommittedAt: '2026-11-15T07:00:00Z' },
  )
  assert(reviewByCommit.atHead.length === 0, 'a review without a SIGN line does not count, even at this head', failures)

  const reviewOnOldCommit = collectSigns(
    [
      {
        body: 'Looks right.\n-Orion',
        userLogin: 'Rowerguy508',
        userType: 'User',
        commitId: older,
        createdAt: '2026-11-15T08:00:00Z',
      },
    ],
    { headSha: head, author: 'Nova', headCommittedAt: '2026-11-15T07:00:00Z' },
  )
  assert(reviewOnOldCommit.atHead.length === 0, 'review commit_id on an older sha must not count', failures)

  const timing = collectSigns(
    [
      {
        body: 'Signed.\n-Atlas',
        userLogin: 'Rowerguy508',
        userType: 'User',
        createdAt: '2026-11-15T08:00:00Z',
      },
      {
        body: 'Signed.\n-Atlas',
        userLogin: 'Rowerguy508',
        userType: 'User',
        createdAt: '2026-11-15T06:00:00Z',
      },
    ],
    { headSha: head, author: 'Nova', headCommittedAt: '2026-11-15T07:00:00Z' },
  )
  assert(timing.atHead.length === 0, 'a timestamp plus the word Signed is not a sign', failures)

  const promiseNotSign = collectSigns([fryNotYet, sentinelPromise], {
    headSha: head,
    author: 'Nova',
    headCommittedAt: '2026-11-13T00:00:00Z',
  })
  assert(promiseNotSign.atHead.length === 0, `promises to sign counted: ${promiseNotSign.atHead.join(',')}`, failures)

  const oldFormats = [
    ['Echo', `Signed at ${head.slice(0, 8)}. iOS 44011129006 is green with all 8 jobs run.\n\n-Echo`],
    ['Fry', `Sign (Fry) at ${head}. iOS 44011129006: all 8 jobs green.\n-Fry`],
    ['Sentinel', `Sign at ${head.slice(0, 8)}: iOS green.\n\nComment, not approval. -Sentinel`],
    ['Atlas', `Atlas sign at ${head}: green. No blockers.\n-Atlas`],
  ]
  for (const [name, body] of oldFormats) {
    const result = collectSigns(
      [{ body, userLogin: 'Rowerguy508', userType: 'User' }],
      { headSha: head, author: 'Nova' },
    )
    assert(result.atHead.length === 0, `old ${name} format must be rejected: ${result.atHead.join(',')}`, failures)
  }

  const deferredWithLine = collectSigns(
    [
      {
        body: `I will sign once iOS is green.\nSIGN ${head.slice(0, 8)} -Atlas`,
        userLogin: 'Rowerguy508',
        userType: 'User',
      },
    ],
    { headSha: head, author: 'Nova' },
  )
  assert(deferredWithLine.atHead.length === 0, 'deferred wording rejects a canonical line', failures)

  const negativeWithLine = collectSigns(
    [
      {
        body: `nobody has signed at ${head.slice(0, 8)} yet\nSIGN ${head.slice(0, 8)} -Sentinel`,
        userLogin: 'Rowerguy508',
        userType: 'User',
      },
    ],
    { headSha: head, author: 'Nova' },
  )
  assert(negativeWithLine.atHead.length === 0, 'negative wording rejects a canonical line', failures)

  const blockerReview = collectSigns(
    [
      {
        body: `One blocker remains.\nSIGN ${head.slice(0, 8)} -Sentinel`,
        userLogin: 'Rowerguy508',
        userType: 'User',
        state: 'COMMENTED',
      },
    ],
    { headSha: head, author: 'Nova' },
  )
  assert(blockerReview.atHead.length === 0, 'a blocker review must not count', failures)

  const changesRequested = collectSigns(
    [
      {
        body: `SIGN ${head.slice(0, 8)} -Fry`,
        userLogin: 'Rowerguy508',
        userType: 'User',
        state: 'CHANGES_REQUESTED',
      },
    ],
    { headSha: head, author: 'Nova' },
  )
  assert(changesRequested.atHead.length === 0, 'CHANGES_REQUESTED must not count', failures)

  const greenRuns = workflowNames.names.map((name, index) => ({
    id: index + 1,
    name,
    status: 'completed',
    conclusion: 'success',
    completedAt: '2026-11-17T05:00:00Z',
    appSlug: 'github-actions',
  }))
  assert(assessChecks(greenRuns).ok, `green checks failed: ${assessChecks(greenRuns).missing.join('; ')}`, failures)

  const inProgress = greenRuns.map((run) =>
    run.name === 'CI checks' ? { ...run, status: 'in_progress', conclusion: null, completedAt: null } : run,
  )
  const pending = assessChecks(inProgress)
  assert(!pending.ok && pending.missing.some((item) => item.includes('CI checks (in_progress)')), 'in_progress must fail', failures)

  const archiveFailed = greenRuns.map((run) =>
    run.name === 'Release archive (Xcode 27.2, unsigned)' ? { ...run, conclusion: 'failure' } : run,
  )
  const failedArchive = assessChecks(archiveFailed)
  assert(
    !failedArchive.ok && failedArchive.missing.some((item) => item.startsWith('Release archive')),
    'failed archive must be named',
    failures,
  )

  const skipped = greenRuns.map((run) => (run.name === 'changes' ? run : { ...run, conclusion: 'skipped' }))
  assert(!assessChecks(skipped).ok, 'a skipped iOS job is not green', failures)

  const newerFailureLosesToNewerSuccess = assessChecks([
    {
      id: 1,
      name: 'CI checks',
      status: 'completed',
      conclusion: 'failure',
      completedAt: '2026-11-17T04:00:00Z',
      appSlug: 'github-actions',
    },
    {
      id: 2,
      name: 'CI checks',
      status: 'completed',
      conclusion: 'success',
      completedAt: '2026-11-17T05:00:00Z',
      appSlug: 'github-actions',
    },
    ...greenRuns.filter((run) => run.name !== 'CI checks'),
  ])
  assert(newerFailureLosesToNewerSuccess.ok, 'latest check run for a name is the one that counts', failures)

  const ready = readinessProblems({
    headSha: head,
    baseRef: TARGET_BASE,
    body: 'Fixes the gate.\n\nDevice: NOT TESTED\n\n-Nova',
    postings: [echoResigned, frySign],
    headCommittedAt: '2026-11-15T07:00:00Z',
    checkRuns: greenRuns,
  })
  assert(ready.ok, `expected ready, got ${ready.lines.join(' | ')}`, failures)

  const notReady = readinessProblems({
    headSha: head,
    baseRef: TARGET_BASE,
    body: 'Device check: NOT TESTED until run on the Duo (iPhone).\n',
    postings: [echoSignedOld],
    headCommittedAt: '2026-11-15T07:00:00Z',
    checkRuns: archiveFailed,
  })
  assert(!notReady.ok, 'incomplete PR must fail', failures)
  const text = notReady.lines.join('\n')
  assert(text.includes(`need 2 signs at ${head.slice(0, 8)}`), `sign line missing:\n${text}`, failures)
  assert(
    text.includes(`post a line exactly \`${signLineFor(head)}\``),
    `exact sign instruction missing:\n${text}`,
    failures,
  )
  assert(text.includes('Device: NOT TESTED'), 'device instruction', failures)
  assert(text.includes('Device check:'), 'device-check counterexample', failures)
  assert(text.includes('Release archive (Xcode 27.2, unsigned)'), 'archive named in the check failure', failures)
  assert(text.includes('do not merge and do not force-push'), 'do-not-merge line', failures)
  assert(/does not end with -Name/.test(text), 'missing author line', failures)

  const otherBase = readinessProblems({
    headSha: other,
    baseRef: 'main',
    body: '',
    postings: [],
    headCommittedAt: null,
    checkRuns: [],
  })
  assert(otherBase.ok && otherBase.applies === false, 'other bases are out of scope', failures)

  assert(
    headComesFromFork({
      head: { repo: { full_name: 'Rowerguy508/ai-radio-dj', fork: false } },
      base: { repo: { full_name: 'Rowerguy508/ai-radio-dj', fork: false } },
    }) === false,
    'same-repo head is not a fork',
    failures,
  )
  assert(
    headComesFromFork({
      head: { repo: { full_name: 'outsider/ai-radio-dj', fork: true } },
      base: { repo: { full_name: 'Rowerguy508/ai-radio-dj', fork: false } },
    }) === true,
    'fork head must be detected',
    failures,
  )
  assert(
    headComesFromFork({
      head: { repo: null },
      base: { repo: { full_name: 'Rowerguy508/ai-radio-dj' } },
    }) === true,
    'missing head repo fails closed as a fork',
    failures,
  )

  const forked = readinessProblems({
    headSha: head,
    baseRef: TARGET_BASE,
    body: 'Fixes the gate.\n\nDevice: NOT TESTED\n\n-Nova',
    postings: [echoResigned, frySign],
    headCommittedAt: '2026-11-15T07:00:00Z',
    checkRuns: greenRuns,
    fork: true,
    headRepo: 'outsider/ai-radio-dj',
    baseRepo: 'Rowerguy508/ai-radio-dj',
  })
  assert(!forked.ok, 'a fork head must fail even with trusted signs and green checks', failures)
  assert(
    forked.lines.some((line) => line.includes('fails closed on fork PRs') && line.includes('outsider/ai-radio-dj')),
    `fork failure missing:\n${forked.lines.join('\n')}`,
    failures,
  )

  const outsidePair = readinessProblems({
    headSha: head,
    baseRef: TARGET_BASE,
    body: 'Fixes the gate.\n\nDevice: NOT TESTED\n\n-Nova',
    postings: [
      {
        body: 'SIGN c00e290f -Echo',
        userLogin: 'outsider',
        userType: 'User',
        authorAssociation: 'NONE',
        createdAt: '2026-11-15T08:00:00Z',
      },
      {
        body: 'SIGN c00e290f -Fry',
        userLogin: 'drive-by',
        userType: 'User',
        authorAssociation: 'CONTRIBUTOR',
        createdAt: '2026-11-15T08:00:00Z',
      },
    ],
    headCommittedAt: '2026-11-15T07:00:00Z',
    checkRuns: greenRuns,
    fork: false,
  })
  assert(!outsidePair.ok, 'two outside accounts must not turn the gate green', failures)
  const outsideText = outsidePair.lines.join('\n')
  assert(outsideText.includes(`need 2 signs at ${head.slice(0, 8)}`), `outside signs counted:\n${outsideText}`, failures)
  assert(outsideText.includes('outsider'), 'untrusted outsider missing from the error', failures)
  assert(outsideText.includes('TRUSTED_LOGINS'), 'the error must point at the allowlist', failures)

  if (failures.length > 0) {
    throw new Error(`merge-readiness self-test failed:\n${failures.map((item) => `- ${item}`).join('\n')}`)
  }
}

function githubHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'merge-readiness',
  }
}

async function github(token, method, path, body) {
  const response = await fetch(`https://api.github.com${path}`, {
    method,
    headers: githubHeaders(token),
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await response.text()
  let data = null
  if (text) {
    try {
      data = JSON.parse(text)
    } catch {
      data = text
    }
  }
  if (!response.ok) {
    const detail = typeof data === 'string' ? data : JSON.stringify(data)
    throw new Error(`${method} ${path} -> ${response.status} ${detail.slice(0, 500)}`)
  }
  return { data, headers: response.headers }
}

function nextLink(linkHeader) {
  if (!linkHeader) return null
  for (const part of linkHeader.split(',')) {
    const match = part.match(/<([^>]+)>;\s*rel="next"/)
    if (match) return match[1]
  }
  return null
}

async function githubList(token, path) {
  const items = []
  let url = `https://api.github.com${path}`
  while (url) {
    const response = await fetch(url, { headers: githubHeaders(token) })
    const data = await response.json()
    if (!response.ok) {
      throw new Error(`GET ${url} -> ${response.status} ${JSON.stringify(data).slice(0, 500)}`)
    }
    if (Array.isArray(data)) items.push(...data)
    else if (Array.isArray(data.check_runs)) items.push(...data.check_runs)
    else throw new Error(`Unexpected list payload from ${url}`)
    const next = nextLink(response.headers.get('link'))
    url = next
  }
  return items
}

function prNumbersFromEvent(eventName, payload) {
  if (eventName === 'pull_request' || eventName === 'pull_request_review') {
    return payload.pull_request?.number ? [payload.pull_request.number] : []
  }
  if (eventName === 'issue_comment') {
    if (!payload.issue?.pull_request) return []
    return payload.issue.number ? [payload.issue.number] : []
  }
  if (eventName === 'check_suite') {
    return (payload.check_suite?.pull_requests || []).map((pr) => pr.number).filter(Boolean)
  }
  if (eventName === 'check_run') {
    const embedded = payload.check_run?.pull_requests || payload.check_run?.check_suite?.pull_requests || []
    return embedded.map((pr) => pr.number).filter(Boolean)
  }
  if (eventName === 'workflow_run') {
    return (payload.workflow_run?.pull_requests || []).map((pr) => pr.number).filter(Boolean)
  }
  return []
}

function postingFromComment(comment) {
  return {
    body: comment.body || '',
    userLogin: comment.user?.login || '',
    userType: comment.user?.type || '',
    authorAssociation: comment.author_association || '',
    createdAt: comment.created_at || null,
    commitId: comment.commit_id || null,
  }
}

async function loadPullRequest(token, owner, repo, number) {
  const { data: pr } = await github(token, 'GET', `/repos/${owner}/${repo}/pulls/${number}`)
  const [comments, reviews, reviewComments] = await Promise.all([
    githubList(token, `/repos/${owner}/${repo}/issues/${number}/comments?per_page=100`),
    githubList(token, `/repos/${owner}/${repo}/pulls/${number}/reviews?per_page=100`),
    githubList(token, `/repos/${owner}/${repo}/pulls/${number}/comments?per_page=100`),
  ])
  const stateByReview = new Map(reviews.map((review) => [review.id, review.state || '']))
  const postings = [
    ...comments.map(postingFromComment),
    ...reviews.map((review) => ({
      body: review.body || '',
      userLogin: review.user?.login || '',
      userType: review.user?.type || '',
      authorAssociation: review.author_association || '',
      state: review.state || '',
      createdAt: review.submitted_at || null,
      commitId: review.commit_id || null,
    })),
    ...reviewComments.map((comment) => ({
      ...postingFromComment(comment),
      state: stateByReview.get(comment.pull_request_review_id) || '',
    })),
  ]
  let headCommittedAt = null
  try {
    const { data: commit } = await github(token, 'GET', `/repos/${owner}/${repo}/commits/${pr.head.sha}`)
    headCommittedAt = commit.commit?.committer?.date || commit.commit?.author?.date || null
  } catch (error) {
    console.log(`::warning::Could not read head commit time (${error.message}). Timing-only signs will not count.`)
  }
  const checkRuns = await githubList(token, `/repos/${owner}/${repo}/commits/${pr.head.sha}/check-runs?per_page=100`)
  return {
    number: pr.number,
    state: pr.state,
    baseRef: pr.base?.ref,
    headSha: pr.head?.sha,
    body: pr.body || '',
    fork: headComesFromFork(pr),
    headRepo: pr.head?.repo?.full_name || '',
    baseRepo: pr.base?.repo?.full_name || '',
    headCommittedAt,
    postings,
    checkRuns: checkRuns.map((run) => ({
      id: run.id,
      name: run.name,
      status: run.status,
      conclusion: run.conclusion,
      startedAt: run.started_at,
      completedAt: run.completed_at,
      createdAt: run.started_at,
      appSlug: run.app?.slug || null,
    })),
  }
}

async function publishCheck(token, owner, repo, headSha, ok, summary) {
  await github(token, 'POST', `/repos/${owner}/${repo}/check-runs`, {
    name: 'merge-readiness',
    head_sha: headSha,
    status: 'completed',
    conclusion: ok ? 'success' : 'failure',
    output: {
      title: ok ? 'Ready to merge' : 'Not ready to merge',
      summary,
    },
  })
}

function emit(lines, ok) {
  for (const line of lines) {
    if (!ok && line.startsWith('merge-readiness:')) console.log(`::error::${line}`)
    else console.log(line)
  }
}

async function main() {
  if (process.argv.includes('--self-test')) {
    selfTest()
    console.log('merge-readiness self-test: ok')
    return
  }

  const eventName = process.env.GITHUB_EVENT_NAME || ''
  const eventPath = process.env.GITHUB_EVENT_PATH
  const token = process.env.GITHUB_TOKEN
  const repository = process.env.GITHUB_REPOSITORY || ''
  if (!token || !eventPath || !repository.includes('/')) {
    console.log(
      '::error::merge-readiness: GITHUB_TOKEN, GITHUB_EVENT_PATH, or GITHUB_REPOSITORY is missing. Re-run the workflow. Do not treat this as a pass.',
    )
    process.exitCode = 1
    return
  }
  const [owner, repo] = repository.split('/')
  const payload = JSON.parse(await readFile(eventPath, 'utf8'))
  const numbers = [...new Set(prNumbersFromEvent(eventName, payload))]
  if (numbers.length === 0) {
    console.log(`merge-readiness: ${eventName} is not attached to a pull request. Nothing to gate.`)
    return
  }

  // pull_request_target's automatic check is not a reliable head-SHA status.
  // Always write merge-readiness onto the head. The job still exits non-zero
  // when the pull request is not ready.
  let failed = false
  for (const number of numbers) {
    let loaded
    try {
      loaded = await loadPullRequest(token, owner, repo, number)
    } catch (error) {
      const line = `merge-readiness: could not read PR #${number} (${error.message}). Re-run the job. Do not treat this as a pass.`
      console.log(`::error::${line}`)
      failed = true
      continue
    }
    if (loaded.state !== 'open') {
      console.log(`merge-readiness: PR #${number} is ${loaded.state}. Not gating a closed PR.`)
      continue
    }
    const result = readinessProblems({
      headSha: loaded.headSha,
      baseRef: loaded.baseRef,
      body: loaded.body,
      postings: loaded.postings,
      headCommittedAt: loaded.headCommittedAt,
      checkRuns: loaded.checkRuns,
      fork: loaded.fork,
      headRepo: loaded.headRepo,
      baseRepo: loaded.baseRepo,
    })
    const lines = result.ok && result.applies
      ? [successLine(loaded.headSha, result.signs)]
      : result.lines
    console.log(`merge-readiness: evaluated PR #${number} at ${loaded.headSha} (base ${loaded.baseRef}).`)
    emit(lines, result.ok)
    if (result.applies) {
      try {
        await publishCheck(token, owner, repo, loaded.headSha, result.ok, lines.join('\n\n'))
        console.log(`merge-readiness: wrote the check onto ${loaded.headSha}.`)
      } catch (error) {
        console.log(
          `::error::merge-readiness: failed to write the check onto ${loaded.headSha} (${error.message}). The job result may not show on the PR. Re-run. Do not merge.`,
        )
        failed = true
      }
    }
    if (!result.ok) failed = true
  }
  if (failed) process.exitCode = 1
}

const invokedDirectly = process.argv[1] && process.argv[1].endsWith('merge-readiness.mjs')
if (invokedDirectly) {
  main().catch((error) => {
    console.log(`::error::merge-readiness: ${error.message}`)
    process.exit(1)
  })
}
