/**
 * Vercel Ignored Build Step for aerodj-tts (scripts/vercel-ignore-build.sh).
 *
 * The old ignoreCommand, `git diff --quiet HEAD^ HEAD -- .`, only looked at the
 * tip commit. Integration 6307545 (the #273 merge, ray-do only) sat on top of
 * 96aa006 (the #256 merge, proxy changes) in one push, so Production was skipped.
 * The script now diffs VERCEL_GIT_PREVIOUS_SHA (last successful deploy for the
 * branch) against HEAD over services/aerodj-tts/, and fails open (builds) on
 * anything it can't prove. Exit 0 = skip, exit 1 = build.
 *
 * Each case builds a throwaway git repo shaped like this one and runs the real
 * script from services/aerodj-tts (Vercel's Root Directory).
 */
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SERVICE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = process.env.IGNORE_BUILD_SCRIPT ?? path.join(SERVICE_DIR, 'scripts', 'vercel-ignore-build.sh');
const TTS = 'services/aerodj-tts';

const GIT_ENV: NodeJS.ProcessEnv = {
  ...process.env,
  GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_CONFIG_NOSYSTEM: '1',
  GIT_AUTHOR_NAME: 'Test',
  GIT_AUTHOR_EMAIL: 'test@example.invalid',
  GIT_COMMITTER_NAME: 'Test',
  GIT_COMMITTER_EMAIL: 'test@example.invalid',
  GIT_TERMINAL_PROMPT: '0',
};
delete GIT_ENV.VERCEL_GIT_PREVIOUS_SHA;
delete GIT_ENV.VERCEL_ENV;

let tmpRoot = '';
let counter = 0;

function git(cwd: string, ...args: string[]): string {
  return execFileSync('git', args, { cwd, env: GIT_ENV, encoding: 'utf8' }).trim();
}

function write(repo: string, rel: string, content: string): void {
  const p = path.join(repo, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, content);
}

function commit(repo: string, msg: string, files: Record<string, string | null>): string {
  for (const [rel, content] of Object.entries(files)) {
    if (content === null) git(repo, 'rm', '-q', rel);
    else {
      write(repo, rel, content);
      git(repo, 'add', rel);
    }
  }
  git(repo, 'commit', '-q', '-m', msg);
  return git(repo, 'rev-parse', 'HEAD');
}

/** A repo with the same top-level shape as ai-radio-dj: ray-do at the root, the proxy under services/. */
function newRepo(): string {
  const repo = path.join(tmpRoot, `repo-${counter++}`);
  fs.mkdirSync(repo);
  git(repo, 'init', '-q', '-b', 'main');
  commit(repo, 'base', {
    'package.json': '{"name":"ray-do"}\n',
    'vercel.json': '{"framework":"nextjs"}\n',
    'lib/telegram/webhook-auth.ts': 'export const a = 1;\n',
    'tests/raydo-lockdown.test.ts': '// ray-do\n',
    'site/index.html': '<p>site</p>\n',
    'ios/App.swift': '// ios\n',
    [`${TTS}/package.json`]: '{"name":"aerodj-tts"}\n',
    [`${TTS}/package-lock.json`]: '{}\n',
    [`${TTS}/tsconfig.json`]: '{}\n',
    [`${TTS}/vercel.json`]: '{"ignoreCommand":"bash scripts/vercel-ignore-build.sh"}\n',
    [`${TTS}/scripts/vercel-ignore-build.sh`]: '# stub\n',
    [`${TTS}/api/tts.ts`]: 'export default 1;\n',
    [`${TTS}/api/attest/challenge.ts`]: 'export default 1;\n',
    [`${TTS}/src/handler.ts`]: 'export const h = 1;\n',
    [`${TTS}/config/storekit.json`]: '{}\n',
    [`${TTS}/test/handler.test.ts`]: '// test\n',
  });
  return repo;
}

interface Result { code: number | null; out: string }

/**
 * Runs the script as a Preview deploy unless extraEnv sets VERCEL_ENV: only
 * preview/development ever compare against PREV (Orion's report, see the
 * 'VERCEL_ENV' describe below). `VERCEL_ENV: undefined` runs it with VERCEL_ENV unset.
 */
function run(repo: string, prev: string | undefined, cwdRel = TTS, extraEnv: NodeJS.ProcessEnv = {}): Result {
  const env: NodeJS.ProcessEnv = { ...GIT_ENV, IGNORE_BUILD_FETCH_TIMEOUT_S: '10', VERCEL_ENV: 'preview', ...extraEnv };
  if (Object.prototype.hasOwnProperty.call(extraEnv, 'VERCEL_ENV') && extraEnv.VERCEL_ENV === undefined) delete env.VERCEL_ENV;
  if (prev !== undefined) env.VERCEL_GIT_PREVIOUS_SHA = prev;
  const r = spawnSync('bash', [SCRIPT], { cwd: path.join(repo, cwdRel), env, encoding: 'utf8', timeout: 30_000 });
  return { code: r.status, out: `${r.stdout}${r.stderr}` };
}

const BUILD = 1;
const SKIP = 0;

function expectCode(r: Result, code: number, why: string): void {
  assert.equal(r.code, code, `${why}\nexpected ${code === BUILD ? 'BUILD (1)' : 'SKIP (0)'}, got ${r.code}\n${r.out}`);
  const lines = r.out.split('\n').filter((l) => l.length > 0);
  assert.equal(lines.length, 1, `exactly one log line, got:\n${r.out}`);
  assert.match(lines[0], code === BUILD ? /^vercel-ignore-build: BUILD - / : /^vercel-ignore-build: SKIP - /);
}

/**
 * A `git` wrapper first on PATH: logs every call, and can make `fetch` a no-op
 * success (SHIM_FETCH_NOOP), make `fetch --deepen=N` or `fetch --unshallow` fail
 * (SHIM_FAIL_DEEPEN, SHIM_FAIL_UNSHALLOW), or make either one hang for N seconds
 * (SHIM_SLEEP_DEEPEN, SHIM_SLEEP_UNSHALLOW) so the script's timeout has to cut it off.
 * A `timeout` wrapper next to it records the bound each fetch got (SHIM_TIMEOUT_LOG)
 * and then runs the real timeout(1).
 */
let shimDir = '';
interface ShimOpts { fetchNoop?: boolean; failDeepen?: boolean; failUnshallow?: boolean; sleepDeepen?: number; sleepUnshallow?: number; timeoutLog?: string }
function shimEnv(log: string, opts: ShimOpts = {}): NodeJS.ProcessEnv {
  return {
    PATH: `${shimDir}${path.delimiter}${process.env.PATH ?? ''}`,
    SHIM_LOG: log,
    ...(opts.fetchNoop ? { SHIM_FETCH_NOOP: '1' } : {}),
    ...(opts.failDeepen ? { SHIM_FAIL_DEEPEN: '1' } : {}),
    ...(opts.failUnshallow ? { SHIM_FAIL_UNSHALLOW: '1' } : {}),
    ...(opts.sleepDeepen ? { SHIM_SLEEP_DEEPEN: String(opts.sleepDeepen) } : {}),
    ...(opts.sleepUnshallow ? { SHIM_SLEEP_UNSHALLOW: String(opts.sleepUnshallow) } : {}),
    ...(opts.timeoutLog ? { SHIM_TIMEOUT_LOG: opts.timeoutLog } : {}),
  };
}
function shimCalls(log: string): string[] {
  return fs.existsSync(log) ? fs.readFileSync(log, 'utf8').split('\n').filter((l) => l.length > 0) : [];
}

before(() => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'tts-ignore-build-'));
  const realGit = execFileSync('bash', ['-c', 'command -v git'], { encoding: 'utf8' }).trim();
  const realTimeout = execFileSync('bash', ['-c', 'command -v timeout'], { encoding: 'utf8' }).trim();
  shimDir = path.join(tmpRoot, 'shim');
  fs.mkdirSync(shimDir);
  fs.writeFileSync(
    path.join(shimDir, 'git'),
    [
      '#!/usr/bin/env bash',
      'printf "%s\\n" "$*" >> "$SHIM_LOG"',
      'for a in "$@"; do',
      '  if [ "$a" = fetch ] && [ -n "${SHIM_FETCH_NOOP:-}" ]; then exit 0; fi',
      '  if [ "$a" = --unshallow ] && [ -n "${SHIM_FAIL_UNSHALLOW:-}" ]; then exit 128; fi',
      '  if [ "$a" = --unshallow ] && [ -n "${SHIM_SLEEP_UNSHALLOW:-}" ]; then exec sleep "$SHIM_SLEEP_UNSHALLOW"; fi',
      '  case "$a" in --deepen=*)',
      '    if [ -n "${SHIM_FAIL_DEEPEN:-}" ]; then exit 128; fi',
      '    if [ -n "${SHIM_SLEEP_DEEPEN:-}" ]; then exec sleep "$SHIM_SLEEP_DEEPEN"; fi ;;',
      '  esac',
      'done',
      `exec ${JSON.stringify(realGit)} "$@"`,
      '',
    ].join('\n'),
    { mode: 0o755 },
  );
  fs.writeFileSync(
    path.join(shimDir, 'timeout'),
    [
      '#!/usr/bin/env bash',
      'if [ -n "${SHIM_TIMEOUT_LOG:-}" ]; then printf "%s\\n" "$1" >> "$SHIM_TIMEOUT_LOG"; fi',
      `exec ${JSON.stringify(realTimeout)} "$@"`,
      '',
    ].join('\n'),
    { mode: 0o755 },
  );
});
after(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});

describe('vercel-ignore-build.sh', () => {
  test('the 6307545 case: proxy change in a middle merge, ray-do-only tip -> BUILD', () => {
    const repo = newRepo();
    const prev = git(repo, 'rev-parse', 'HEAD'); // last successful deploy
    git(repo, 'checkout', '-q', '-b', 'pr256');
    commit(repo, 'proxy change', { [`${TTS}/src/handler.ts`]: 'export const h = 2;\n' });
    git(repo, 'checkout', '-q', 'main');
    git(repo, 'merge', '-q', '--no-ff', '-m', 'Merge #256', 'pr256'); // 96aa006
    git(repo, 'checkout', '-q', '-b', 'pr273');
    commit(repo, 'ray-do change', { 'lib/telegram/webhook-auth.ts': 'export const a = 2;\n' });
    git(repo, 'checkout', '-q', 'main');
    git(repo, 'merge', '-q', '--no-ff', '-m', 'Merge #273', 'pr273'); // 6307545

    // The old command really does miss it: tip vs first parent has no proxy diff.
    const legacy = spawnSync('git', ['diff', '--quiet', 'HEAD^', 'HEAD', '--', '.'], { cwd: path.join(repo, TTS), env: GIT_ENV });
    assert.equal(legacy.status, 0, 'precondition: HEAD^..HEAD alone would skip');

    expectCode(run(repo, prev), BUILD, 'an earlier commit since PREV changed the proxy');
  });

  test('plain linear history: proxy commit then ray-do commit -> BUILD', () => {
    const repo = newRepo();
    const prev = git(repo, 'rev-parse', 'HEAD');
    commit(repo, 'proxy', { [`${TTS}/api/tts.ts`]: 'export default 2;\n' });
    commit(repo, 'ray-do', { 'package.json': '{"name":"ray-do","v":2}\n' });
    expectCode(run(repo, prev), BUILD, 'HEAD~1 changed the proxy');
  });

  test('only ray-do / site / ios / root config changed since PREV -> SKIP', () => {
    const repo = newRepo();
    const prev = git(repo, 'rev-parse', 'HEAD');
    commit(repo, 'ray-do 1', { 'lib/telegram/webhook-auth.ts': 'export const a = 3;\n' });
    commit(repo, 'ray-do 2', { 'tests/raydo-lockdown.test.ts': '// ray-do 2\n', 'vercel.json': '{"framework":"nextjs","x":1}\n' });
    commit(repo, 'site + ios', { 'site/index.html': '<p>2</p>\n', 'ios/App.swift': '// 2\n', 'package.json': '{"name":"ray-do","v":3}\n' });
    expectCode(run(repo, prev), SKIP, 'nothing under services/aerodj-tts changed');
    // Same answer when run from the repo root: the pathspec is anchored at the top.
    expectCode(run(repo, prev, '.'), SKIP, 'cwd-independent');
  });

  test('a proxy change that was reverted since PREV -> SKIP (tree-level diff)', () => {
    const repo = newRepo();
    const prev = git(repo, 'rev-parse', 'HEAD');
    commit(repo, 'proxy', { [`${TTS}/src/handler.ts`]: 'export const h = 9;\n' });
    commit(repo, 'revert', { [`${TTS}/src/handler.ts`]: 'export const h = 1;\n' });
    expectCode(run(repo, prev), SKIP, 'the deployed tree is identical');
  });

  test('PREV == HEAD -> SKIP', () => {
    const repo = newRepo();
    expectCode(run(repo, git(repo, 'rev-parse', 'HEAD')), SKIP, 'same commit');
  });

  test('PREV unset, empty or malformed -> BUILD', () => {
    const repo = newRepo();
    commit(repo, 'ray-do only', { 'lib/telegram/webhook-auth.ts': 'export const a = 4;\n' });
    expectCode(run(repo, undefined), BUILD, 'unset (first deploy on a branch)');
    expectCode(run(repo, ''), BUILD, 'empty');
    expectCode(run(repo, 'HEAD'), BUILD, 'a ref name is not a SHA');
    expectCode(run(repo, 'deadbeef; rm -rf /'), BUILD, 'garbage');
  });

  test('every path the proxy build depends on -> BUILD', () => {
    const changes: Array<[string, string | null]> = [
      [`${TTS}/api/tts.ts`, 'export default 3;\n'],
      [`${TTS}/api/attest/challenge.ts`, 'export default 3;\n'],
      [`${TTS}/api/attest/new-route.ts`, 'export default 1;\n'],
      [`${TTS}/src/handler.ts`, 'export const h = 3;\n'],
      [`${TTS}/src/handler.ts`, null],
      [`${TTS}/config/storekit.json`, '{"x":1}\n'],
      [`${TTS}/package.json`, '{"name":"aerodj-tts","v":2}\n'],
      [`${TTS}/package-lock.json`, '{"v":2}\n'],
      [`${TTS}/tsconfig.json`, '{"v":2}\n'],
      [`${TTS}/vercel.json`, '{"v":2}\n'],
      [`${TTS}/scripts/vercel-ignore-build.sh`, '# changed\n'],
      [`${TTS}/test/handler.test.ts`, '// changed\n'],
    ];
    for (const [rel, content] of changes) {
      const repo = newRepo();
      const prev = git(repo, 'rev-parse', 'HEAD');
      commit(repo, `touch ${rel}`, { [rel]: content });
      commit(repo, 'ray-do tip', { 'lib/telegram/webhook-auth.ts': 'export const a = 5;\n' });
      expectCode(run(repo, prev), BUILD, `${content === null ? 'deleting' : 'changing'} ${rel}`);
    }
  });

  /** Bare "GitHub" + a depth-1 clone, like Vercel's shallow checkout. */
  function shallowSetup(proxyChange: boolean): { clone: string; prev: string } {
    const src = newRepo();
    const prev = git(src, 'rev-parse', 'HEAD');
    if (proxyChange) commit(src, 'proxy', { [`${TTS}/src/handler.ts`]: 'export const h = 7;\n' });
    for (let i = 0; i < 3; i++) commit(src, `ray-do ${i}`, { 'lib/telegram/webhook-auth.ts': `export const a = ${10 + i};\n` });
    const bare = path.join(tmpRoot, `bare-${counter++}.git`);
    git(tmpRoot, 'clone', '-q', '--bare', src, bare);
    git(bare, 'config', 'uploadpack.allowAnySHA1InWant', 'true');
    const clone = path.join(tmpRoot, `clone-${counter++}`);
    git(tmpRoot, 'clone', '-q', '--depth=1', `file://${bare}`, clone);
    assert.throws(() => git(clone, 'cat-file', '-e', `${prev}^{commit}`), 'precondition: PREV not in the shallow clone');
    return { clone, prev };
  }

  test('PREV outside the shallow clone, fetch works -> real answer (SKIP / BUILD)', () => {
    const quiet = shallowSetup(false);
    expectCode(run(quiet.clone, quiet.prev), SKIP, 'fetched PREV, only ray-do changed');
    const changed = shallowSetup(true);
    expectCode(run(changed.clone, changed.prev), BUILD, 'fetched PREV, proxy changed');
  });

  test('PREV outside the clone and the fetch fails -> BUILD (fail open)', () => {
    // Only ray-do changed, so a script that guessed "skip" would be wrong to do so.
    const { clone, prev } = shallowSetup(false);
    git(clone, 'remote', 'set-url', 'origin', `file://${path.join(tmpRoot, 'does-not-exist.git')}`);
    expectCode(run(clone, prev), BUILD, 'unfetchable PREV');
    const noRemote = newRepo();
    commit(noRemote, 'ray-do', { 'lib/telegram/webhook-auth.ts': 'export const a = 6;\n' });
    expectCode(run(noRemote, '0123456789abcdef0123456789abcdef01234567'), BUILD, 'unknown PREV, no origin');
  });

  test('git diff itself errors (PREV commit present, its tree object missing) -> BUILD', () => {
    const repo = newRepo();
    const prev = git(repo, 'rev-parse', 'HEAD');
    commit(repo, 'ray-do only', { 'lib/telegram/webhook-auth.ts': 'export const a = 8;\n' });
    const tree = git(repo, 'rev-parse', `${prev}^{tree}`);
    fs.rmSync(path.join(repo, '.git', 'objects', tree.slice(0, 2), tree.slice(2)));
    git(repo, 'cat-file', '-e', `${prev}^{commit}`); // the commit is still there
    expectCode(run(repo, prev), BUILD, 'diff exits >1');
  });

  test('not a git checkout -> BUILD', () => {
    const dir = path.join(tmpRoot, `nogit-${counter++}`, TTS);
    fs.mkdirSync(dir, { recursive: true });
    const r = spawnSync('bash', [SCRIPT], {
      cwd: dir,
      env: { ...GIT_ENV, VERCEL_ENV: 'preview', VERCEL_GIT_PREVIOUS_SHA: '0123456789abcdef0123456789abcdef01234567', GIT_CEILING_DIRECTORIES: tmpRoot },
      encoding: 'utf8',
    });
    expectCode({ code: r.status, out: `${r.stdout}${r.stderr}` }, BUILD, 'no repo');
  });

  test('PREV not an ancestor of HEAD: force-push shape -> BUILD', () => {
    const repo = newRepo();
    const base = git(repo, 'rev-parse', 'HEAD');
    // PREV was deployed, then main was rewritten from base. The proxy tree is
    // identical on both sides, so only the ancestry check stands between this and a skip.
    const prev = commit(repo, 'deployed, later force-pushed away', { 'lib/telegram/webhook-auth.ts': 'export const a = 20;\n' });
    git(repo, 'reset', '-q', '--hard', base);
    commit(repo, 'rewritten', { 'lib/telegram/webhook-auth.ts': 'export const a = 21;\n' });
    git(repo, 'cat-file', '-e', `${prev}^{commit}`); // still in the object store
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    const r = run(repo, prev, TTS, shimEnv(log));
    expectCode(r, BUILD, 'PREV is no longer in HEAD history');
    assert.match(r.out, /not an ancestor of HEAD/);
    // A full clone already has all of its history: no --deepen / --unshallow.
    assert.deepEqual(historyFetches(log), [], 'non-shallow: no history fetch');
  });

  test('PREV not an ancestor of HEAD: unrelated orphan history -> BUILD', () => {
    const repo = newRepo();
    git(repo, 'checkout', '-q', '--orphan', 'other');
    git(repo, 'commit', '-q', '-m', 'orphan with an identical tree');
    const prev = git(repo, 'rev-parse', 'HEAD');
    git(repo, 'checkout', '-q', 'main');
    const r = run(repo, prev);
    expectCode(r, BUILD, 'PREV shares no history with HEAD');
    assert.match(r.out, /not an ancestor of HEAD/);
  });

  test('shallow clone, PREV fetched but ancestry unprovable (--deepen and --unshallow both fail) -> BUILD', () => {
    const { clone, prev } = shallowSetup(false); // only ray-do changed: a guess would skip
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    const r = run(clone, prev, TTS, shimEnv(log, { failDeepen: true, failUnshallow: true }));
    expectCode(r, BUILD, 'cannot prove PREV is an ancestor');
    assert.match(r.out, /not an ancestor of HEAD/);
    assert.deepEqual(historyFetches(log), ['--deepen=50', '--unshallow'], 'deepen first, then the full fetch');
  });

  /** The history fetches (`--deepen=N` / `--unshallow`) the script made, in order. */
  function historyFetches(log: string): string[] {
    return shimCalls(log)
      .filter((l) => /(^|\s)fetch(\s|$)/.test(l))
      .map((l) => l.split(' ').find((a) => a.startsWith('--deepen=') || a === '--unshallow'))
      .filter((a): a is string => a !== undefined);
  }

  test('--deepen proves ancestry: no --unshallow, real answer (SKIP unchanged / BUILD changed)', () => {
    for (const [proxyChange, code] of [[false, SKIP], [true, BUILD]] as const) {
      const { clone, prev } = shallowSetup(proxyChange);
      const log = path.join(tmpRoot, `shim-${counter++}.log`);
      const r = run(clone, prev, TTS, shimEnv(log));
      expectCode(r, code, proxyChange ? 'deepened, proxy changed' : 'deepened, only ray-do changed');
      assert.deepEqual(historyFetches(log), ['--deepen=50'], 'one cheap deepen, never a full unshallow');
      // Every history fetch keeps --end-of-options before its revision.
      for (const l of shimCalls(log).filter((x) => x.includes('--deepen='))) assert.match(l, /--end-of-options origin [0-9a-f]{40}$/);
    }
  });

  test('every --end-of-options the header promises is on the real git call (PREV fetch, --deepen, --unshallow, merge-base, diff)', () => {
    // Sentinel's #288 N1: dropping it from --unshallow or from the final diff survived.
    const { clone, prev } = shallowSetup(false); // PREV outside the clone; --deepen=1 too shallow -> all three fetches
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    expectCode(run(clone, prev, TTS, { ...shimEnv(log), IGNORE_BUILD_DEEPEN_COMMITS: '1' }), SKIP, 'every call ran');
    const calls = shimCalls(log);
    const hex = '[0-9a-f]{40}';
    const expectEvery = (what: string, pick: (l: string) => boolean, shape: RegExp, min = 1) => {
      const lines = calls.filter(pick);
      assert.ok(lines.length >= min, `${what}: expected at least ${min} call(s), got ${lines.length}\n${calls.join('\n')}`);
      for (const l of lines) assert.match(l, shape, what);
    };
    const isFetch = (l: string) => /(^|\s)fetch(\s|$)/.test(l);
    expectEvery('PREV fetch', (l) => isFetch(l) && l.includes('--depth=1'), new RegExp(`--depth=1 --end-of-options origin ${prev}$`));
    expectEvery('--deepen fetch', (l) => isFetch(l) && l.includes('--deepen='), new RegExp(`--deepen=1 --end-of-options origin ${hex}$`));
    expectEvery('--unshallow fetch', (l) => isFetch(l) && l.includes('--unshallow'), new RegExp(`--unshallow --end-of-options origin ${hex}$`));
    expectEvery('merge-base', (l) => /(^|\s)merge-base(\s|$)/.test(l), new RegExp(`^merge-base --is-ancestor --end-of-options ${prev} ${hex}$`), 2);
    expectEvery('diff', (l) => /^diff(\s|$)/.test(l), new RegExp(`^diff --quiet --end-of-options ${prev} ${hex} -- `));
  });

  test('--deepen reaches PREV on a long history: clone stays shallow and --unshallow is never run', () => {
    const src = newRepo();
    for (let i = 0; i < 10; i++) commit(src, `old ${i}`, { 'lib/telegram/webhook-auth.ts': `export const a = ${100 + i};\n` });
    const prev = git(src, 'rev-parse', 'HEAD');
    for (let i = 0; i < 3; i++) commit(src, `ray-do ${i}`, { 'lib/telegram/webhook-auth.ts': `export const a = ${200 + i};\n` });
    const bare = path.join(tmpRoot, `bare-${counter++}.git`);
    git(tmpRoot, 'clone', '-q', '--bare', src, bare);
    git(bare, 'config', 'uploadpack.allowAnySHA1InWant', 'true');
    const clone = path.join(tmpRoot, `clone-${counter++}`);
    git(tmpRoot, 'clone', '-q', '--depth=1', `file://${bare}`, clone);
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    expectCode(run(clone, prev, TTS, { ...shimEnv(log), IGNORE_BUILD_DEEPEN_COMMITS: '5' }), SKIP, 'deepen by 5 reaches PREV (3 below HEAD)');
    assert.deepEqual(historyFetches(log), ['--deepen=5'], 'ancestry proven: no --unshallow');
    assert.equal(git(clone, 'rev-parse', '--is-shallow-repository'), 'true', 'the deepen did not need the whole history');
  });

  test('--deepen too shallow, then --unshallow proves it -> SKIP (unchanged) / BUILD (changed)', () => {
    for (const [proxyChange, code] of [[false, SKIP], [true, BUILD]] as const) {
      const { clone, prev } = shallowSetup(proxyChange); // PREV is 3-4 commits below HEAD
      const log = path.join(tmpRoot, `shim-${counter++}.log`);
      const r = run(clone, prev, TTS, { ...shimEnv(log), IGNORE_BUILD_DEEPEN_COMMITS: '1' });
      expectCode(r, code, 'deepen by 1 is not enough; unshallow is');
      assert.deepEqual(historyFetches(log), ['--deepen=1', '--unshallow']);
      assert.equal(git(clone, 'rev-parse', '--is-shallow-repository'), 'false');
    }
  });

  test('--deepen fails, --unshallow still runs and proves it -> SKIP', () => {
    const { clone, prev } = shallowSetup(false);
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    expectCode(run(clone, prev, TTS, shimEnv(log, { failDeepen: true })), SKIP, 'fallback to the full fetch');
    assert.deepEqual(historyFetches(log), ['--deepen=50', '--unshallow']);
  });

  test('--deepen insufficient and --unshallow fails -> BUILD', () => {
    const { clone, prev } = shallowSetup(false);
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    const r = run(clone, prev, TTS, { ...shimEnv(log, { failUnshallow: true }), IGNORE_BUILD_DEEPEN_COMMITS: '1' });
    expectCode(r, BUILD, 'still unproven');
    assert.match(r.out, /not an ancestor of HEAD/);
    assert.deepEqual(historyFetches(log), ['--deepen=1', '--unshallow']);
  });

  test('--unshallow that hangs past IGNORE_BUILD_FETCH_TIMEOUT_S is cut off -> BUILD', () => {
    assert.equal(spawnSync('bash', ['-c', 'command -v timeout'], { encoding: 'utf8' }).status, 0, 'precondition: timeout(1) exists');
    const { clone, prev } = shallowSetup(false); // a guess would skip
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    const started = Date.now();
    const r = run(clone, prev, TTS, { ...shimEnv(log, { sleepUnshallow: 20 }), IGNORE_BUILD_DEEPEN_COMMITS: '1', IGNORE_BUILD_FETCH_TIMEOUT_S: '1' });
    const elapsed = Date.now() - started;
    expectCode(r, BUILD, 'timed-out unshallow leaves ancestry unproven');
    assert.match(r.out, /not an ancestor of HEAD/);
    assert.deepEqual(historyFetches(log), ['--deepen=1', '--unshallow']);
    assert.ok(elapsed < 10_000, `the 1 s bound cut off the 20 s hang (took ${elapsed} ms)`);
  });

  test('--deepen that hangs is cut off too, and --unshallow still runs -> SKIP', () => {
    const { clone, prev } = shallowSetup(false);
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    const started = Date.now();
    const r = run(clone, prev, TTS, { ...shimEnv(log, { sleepDeepen: 20 }), IGNORE_BUILD_FETCH_TIMEOUT_S: '2' });
    expectCode(r, SKIP, 'unshallow after the timed-out deepen');
    assert.deepEqual(historyFetches(log), ['--deepen=50', '--unshallow']);
    assert.ok(Date.now() - started < 12_000, 'bounded');
  });

  test('IGNORE_BUILD_DEEPEN_COMMITS: only a positive integer up to 99999 is used; anything else is 50', () => {
    for (const [value, used] of [['7', '7'], ['99999', '99999'], ['0', '50'], ['-5', '50'], ['abc', '50'], ['1e3', '50'], ['', '50'], ['100000', '50'], ['5;id', '50'], ['07', '50']]) {
      const { clone, prev } = shallowSetup(false);
      const log = path.join(tmpRoot, `shim-${counter++}.log`);
      expectCode(run(clone, prev, TTS, { ...shimEnv(log), IGNORE_BUILD_DEEPEN_COMMITS: value }), SKIP, `value ${JSON.stringify(value)}`);
      assert.equal(historyFetches(log)[0], `--deepen=${used}`, `value ${JSON.stringify(value)}`);
    }
  });

  test('IGNORE_BUILD_FETCH_TIMEOUT_S: only a positive integer up to 300 is used; anything else (0 included) is 20', () => {
    for (const [value, used] of [
      ['1', '1'], ['7', '7'], ['20', '20'], ['300', '300'],
      ['0', '20'], ['00', '20'], ['-5', '20'], ['abc', '20'], ['1.5', '20'], ['1e3', '20'], ['', '20'], [' 5', '20'],
      ['5s', '20'], ['5;id', '20'], ['07', '20'], ['301', '20'], ['999', '20'], ['1000', '20'], ['99999999999999999999', '20'],
    ]) {
      const { clone, prev } = shallowSetup(false);
      const log = path.join(tmpRoot, `shim-${counter++}.log`);
      const tlog = path.join(tmpRoot, `timeout-${counter++}.log`);
      // PREV is outside the clone and --deepen=1 is too shallow, so all three fetches run
      // (PREV, --deepen, --unshallow) and each one gets the same bound.
      const r = run(clone, prev, TTS, { ...shimEnv(log, { timeoutLog: tlog }), IGNORE_BUILD_DEEPEN_COMMITS: '1', IGNORE_BUILD_FETCH_TIMEOUT_S: value });
      expectCode(r, SKIP, `value ${JSON.stringify(value)}`);
      assert.deepEqual(historyFetches(log), ['--deepen=1', '--unshallow'], `value ${JSON.stringify(value)}`);
      assert.deepEqual(shimCalls(tlog), [used, used, used], `value ${JSON.stringify(value)}`);
    }
  });

  test('IGNORE_BUILD_FETCH_TIMEOUT_S unset: every fetch, the PREV fetch included, gets the 20 s default', () => {
    const { clone, prev } = shallowSetup(false); // PREV outside the clone: fetched first
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    const tlog = path.join(tmpRoot, `timeout-${counter++}.log`);
    const env = { ...shimEnv(log, { timeoutLog: tlog }), IGNORE_BUILD_DEEPEN_COMMITS: '1', IGNORE_BUILD_FETCH_TIMEOUT_S: undefined };
    const r = run(clone, prev, TTS, env);
    expectCode(r, SKIP, 'unset timeout');
    const calls = shimCalls(tlog);
    assert.deepEqual(calls, ['20', '20', '20']);
  });

  test('IGNORE_BUILD_FETCH_TIMEOUT_S=0 still bounds a hanging fetch (default 20 s, not unbounded) -> BUILD', () => {
    const { clone, prev } = shallowSetup(false); // a guess would skip
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    const tlog = path.join(tmpRoot, `timeout-${counter++}.log`);
    const started = Date.now();
    const r = run(clone, prev, TTS, { ...shimEnv(log, { sleepUnshallow: 60, timeoutLog: tlog }), IGNORE_BUILD_DEEPEN_COMMITS: '1', IGNORE_BUILD_FETCH_TIMEOUT_S: '0' });
    const elapsed = Date.now() - started;
    assert.notEqual(r.code, null, `the script itself was killed by the test's 30 s guard: the 60 s hang was not bounded (${elapsed} ms)`);
    expectCode(r, BUILD, 'timed-out unshallow leaves ancestry unproven');
    assert.match(r.out, /not an ancestor of HEAD/);
    assert.deepEqual(historyFetches(log), ['--deepen=1', '--unshallow']);
    assert.deepEqual(shimCalls(tlog), ['20', '20', '20']);
    assert.ok(elapsed >= 19_000 && elapsed < 29_000, `cut off at the 20 s default (took ${elapsed} ms)`);
  });

  test('shallow force-push shape: --deepen fetches all of it, still not an ancestor -> BUILD with no --unshallow', () => {
    const src = newRepo();
    const base = git(src, 'rev-parse', 'HEAD');
    const prev = commit(src, 'deployed, later force-pushed away', { 'lib/telegram/webhook-auth.ts': 'export const a = 40;\n' });
    git(src, 'branch', 'old-deploy', prev); // keeps PREV fetchable by SHA from the bare remote
    git(src, 'reset', '-q', '--hard', base);
    for (let i = 0; i < 3; i++) commit(src, `rewritten ${i}`, { 'lib/telegram/webhook-auth.ts': `export const a = ${41 + i};\n` });
    const bare = path.join(tmpRoot, `bare-${counter++}.git`);
    git(tmpRoot, 'clone', '-q', '--bare', src, bare);
    git(bare, 'config', 'uploadpack.allowAnySHA1InWant', 'true');
    const clone = path.join(tmpRoot, `clone-${counter++}`);
    git(tmpRoot, 'clone', '-q', '--depth=1', '--branch', 'main', `file://${bare}`, clone);
    // Bring PREV and its full history in up front (no depth), so the only shallow
    // boundary left is HEAD's and a --deepen that reaches the root completes the
    // clone on every git version (a by-SHA PREV fetch may leave its own boundary).
    git(clone, 'fetch', '-q', 'origin', 'old-deploy');
    git(clone, 'cat-file', '-e', `${prev}^{commit}`);
    assert.equal(git(clone, 'rev-parse', '--is-shallow-repository'), 'true', 'precondition: still shallow at HEAD');
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    const r = run(clone, prev, TTS, shimEnv(log));
    expectCode(r, BUILD, 'PREV is not in HEAD history');
    assert.match(r.out, /not an ancestor of HEAD/);
    assert.equal(git(clone, 'rev-parse', '--is-shallow-repository'), 'false', 'the deepen reached the root');
    assert.deepEqual(historyFetches(log), ['--deepen=50'], 'no pointless --unshallow on a complete clone');
  });

  test('a full (non-shallow) clone never fetches history: ancestry is checked locally', () => {
    const repo = newRepo();
    const prev = git(repo, 'rev-parse', 'HEAD');
    commit(repo, 'ray-do', { 'lib/telegram/webhook-auth.ts': 'export const a = 30;\n' });
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    expectCode(run(repo, prev, TTS, shimEnv(log)), SKIP, 'local history');
    assert.deepEqual(shimCalls(log).filter((l) => /(^|\s)fetch(\s|$)/.test(l)), []);
  });

  test('PREV must be a full lowercase 40-hex SHA: short, uppercase, 64-hex -> BUILD', () => {
    const repo = newRepo();
    commit(repo, 'ray-do only', { 'lib/telegram/webhook-auth.ts': 'export const a = 22;\n' });
    const prev = git(repo, 'rev-parse', 'HEAD~1'); // a valid answer would be SKIP
    expectCode(run(repo, prev), SKIP, 'control: the full SHA skips');
    expectCode(run(repo, prev.slice(0, 7)), BUILD, '7-char abbreviation');
    expectCode(run(repo, prev.slice(0, 12)), BUILD, '12-char abbreviation');
    expectCode(run(repo, prev.slice(0, 39)), BUILD, '39 chars');
    expectCode(run(repo, prev.toUpperCase()), BUILD, 'uppercase');
    expectCode(run(repo, `${prev}${prev.slice(0, 24)}`), BUILD, '64 hex');
  });

  test('a ref named like a SHA cannot cause a skip', () => {
    const repo = newRepo();
    commit(repo, 'proxy', { [`${TTS}/src/handler.ts`]: 'export const h = 23;\n' });
    // Fry's repro: a branch named like a short SHA, at HEAD (diff would be empty).
    git(repo, 'branch', 'abcdef1', 'HEAD');
    expectCode(run(repo, 'abcdef1'), BUILD, 'short-SHA-shaped branch name');
    // A full 40-hex name is read as an object, never as the ref of the same name.
    const fake = 'abcdef1abcdef1abcdef1abcdef1abcdef1abcde';
    git(repo, 'update-ref', `refs/heads/${fake}`, 'HEAD');
    git(repo, 'update-ref', `refs/tags/${fake}`, 'HEAD');
    expectCode(run(repo, fake), BUILD, 'full-SHA-shaped ref names, no such object');
  });

  test('option-like PREV -> BUILD and never reaches git fetch', () => {
    const repo = newRepo();
    const marker = path.join(tmpRoot, `pwned-${counter++}`);
    const hex = '0123456789abcdef0123456789abcdef01234567';
    const values = [
      `--upload-pack=touch ${marker};#${hex}`,
      `--upload-pack=touch${'${IFS}'}${marker}`,
      `${hex}\n--upload-pack=touch ${marker}`,
      `--end-of-options`,
      `-${hex.slice(1)}`,
    ];
    for (const v of values) {
      const log = path.join(tmpRoot, `shim-${counter++}.log`);
      expectCode(run(repo, v, TTS, shimEnv(log)), BUILD, `option-like PREV ${JSON.stringify(v)}`);
      assert.deepEqual(shimCalls(log).filter((l) => /(^|\s)fetch(\s|$)/.test(l)), [], 'no git fetch');
      assert.ok(!fs.existsSync(marker), 'nothing executed');
    }
  });

  test('PREV still missing after a fetch that "succeeds" -> BUILD', () => {
    const repo = newRepo();
    commit(repo, 'ray-do only', { 'lib/telegram/webhook-auth.ts': 'export const a = 24;\n' });
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    const r = run(repo, '0123456789abcdef0123456789abcdef01234567', TTS, shimEnv(log, { fetchNoop: true }));
    expectCode(r, BUILD, 'fetch exit 0 but no object');
    assert.match(r.out, /still missing after fetch/);
  });

  test('HEAD cannot be resolved (unborn branch) -> BUILD', () => {
    const repo = path.join(tmpRoot, `unborn-${counter++}`);
    fs.mkdirSync(path.join(repo, TTS), { recursive: true });
    git(repo, 'init', '-q', '-b', 'main');
    const r = run(repo, '0123456789abcdef0123456789abcdef01234567');
    expectCode(r, BUILD, 'no commits');
    assert.match(r.out, /cannot resolve HEAD/);
  });

  test('services/aerodj-tts/vercel.json gone from HEAD (folder renamed) -> BUILD', () => {
    const repo = newRepo();
    git(repo, 'mv', TTS, 'services/onairly-tts');
    git(repo, 'commit', '-q', '-m', 'rename the proxy folder');
    const prev = git(repo, 'rev-parse', 'HEAD'); // deployed after the rename
    commit(repo, 'proxy change in the new folder', { 'services/onairly-tts/src/handler.ts': 'export const h = 25;\n' });
    // The old pathspec now matches nothing on either side, so a bare diff would skip.
    const bare = spawnSync('git', ['diff', '--quiet', prev, 'HEAD', '--', `:(top)${TTS}/`], { cwd: repo, env: GIT_ENV });
    assert.equal(bare.status, 0, 'precondition: the diff alone would skip');
    const r = run(repo, prev, '.');
    expectCode(r, BUILD, 'watched folder no longer exists');
    assert.match(r.out, /vercel\.json is not at HEAD/);
  });

  test('vercel.json points ignoreCommand at the script, not the last-commit diff', () => {
    const cfg = JSON.parse(fs.readFileSync(path.join(SERVICE_DIR, 'vercel.json'), 'utf8')) as { ignoreCommand?: string };
    assert.equal(cfg.ignoreCommand, 'bash scripts/vercel-ignore-build.sh');
    const body = fs.readFileSync(path.join(SERVICE_DIR, 'scripts', 'vercel-ignore-build.sh'), 'utf8');
    const code = body.split('\n').filter((l) => !l.trimStart().startsWith('#')).join('\n');
    assert.doesNotMatch(code, /HEAD(~|\^(?!\{))/, 'no last-commit comparison left in the script');
  });
});

describe('vercel-ignore-build.sh: VERCEL_ENV (Orion: PREVIOUS_SHA can be another environment\'s deploy)', () => {
  const PROD_LINE = 'vercel-ignore-build: BUILD - production deploys always build (PREVIOUS_SHA may be a preview deploy)';
  const UNKNOWN_LINE = 'vercel-ignore-build: BUILD - VERCEL_ENV is unset, empty or not preview/development/production';
  const onlyLine = (r: Result) => r.out.split('\n').filter((l) => l.length > 0)[0];

  test('dpl_CuqEdr shape: Preview of X builds, then Production of the same X with PREV = X still builds; Preview with PREV = X skips', () => {
    const repo = newRepo();
    const older = git(repo, 'rev-parse', 'HEAD');
    const x = commit(repo, 'proxy change', { [`${TTS}/src/handler.ts`]: 'export const h = 2;\n' });

    // 1. Preview deploy of X: PREV is the older deploy, the proxy changed -> BUILD.
    const preview = run(repo, older, TTS, { VERCEL_ENV: 'preview' });
    expectCode(preview, BUILD, 'preview of X, proxy changed since the older deploy');
    assert.match(preview.out, /services\/aerodj-tts\/ changed since last deploy/);

    // 2. ~50 s later, Production of the same X: Vercel hands it PREV = X (the preview deploy).
    const log = path.join(tmpRoot, `shim-${counter++}.log`);
    const prod = run(repo, x, TTS, { ...shimEnv(log), VERCEL_ENV: 'production' });
    expectCode(prod, BUILD, 'production must not compare against a preview deploy of the same SHA');
    assert.equal(onlyLine(prod), PROD_LINE);
    assert.deepEqual(shimCalls(log), [], 'decided before any git or fetch work');

    // 3. A Preview (or Development) run with PREV = X still skips: the diff-based skip is kept there.
    for (const d of ['preview', 'development']) {
      const r = run(repo, x, TTS, { VERCEL_ENV: d });
      expectCode(r, SKIP, `${d} with PREV = HEAD`);
      assert.match(r.out, new RegExp(`no changes under services/aerodj-tts/ since last deploy ${x.slice(0, 12)}`));
    }
  });

  test('Production with an unchanged proxy diff still builds, with no git call (also when PREV is unset or junk)', () => {
    const repo = newRepo();
    const prev = git(repo, 'rev-parse', 'HEAD');
    commit(repo, 'ray-do only', { 'lib/telegram/webhook-auth.ts': 'export const a = 2;\n', 'site/index.html': '<p>2</p>\n' });
    expectCode(run(repo, prev, TTS, { VERCEL_ENV: 'preview' }), SKIP, 'control: preview skips this diff');
    expectCode(run(repo, prev, TTS, { VERCEL_ENV: 'development' }), SKIP, 'control: development skips this diff');
    for (const p of [prev, undefined, 'not-a-sha', `--upload-pack=x;#${'a'.repeat(40)}`]) {
      const log = path.join(tmpRoot, `shim-${counter++}.log`);
      const r = run(repo, p, TTS, { ...shimEnv(log), VERCEL_ENV: 'production' });
      expectCode(r, BUILD, `production, PREV ${JSON.stringify(p)}`);
      assert.equal(onlyLine(r), PROD_LINE);
      assert.deepEqual(shimCalls(log), [], 'no git call at all');
    }
  });

  test('unset, empty or unknown VERCEL_ENV builds (fail open), with no git call', () => {
    const repo = newRepo();
    const prev = git(repo, 'rev-parse', 'HEAD');
    commit(repo, 'ray-do only', { 'lib/telegram/webhook-auth.ts': 'export const a = 3;\n' });
    expectCode(run(repo, prev, TTS, { VERCEL_ENV: 'preview' }), SKIP, 'control: preview skips this diff');
    const values: (string | undefined)[] = [undefined, '', 'Production', 'PRODUCTION', 'Preview', 'prod', 'staging', 'test', ' preview', 'preview ', 'preview\n', 'production\n', 'development;true', '*'];
    for (const v of values) {
      const log = path.join(tmpRoot, `shim-${counter++}.log`);
      const r = run(repo, prev, TTS, { ...shimEnv(log), VERCEL_ENV: v });
      expectCode(r, BUILD, `VERCEL_ENV ${JSON.stringify(v)}`);
      assert.equal(onlyLine(r), UNKNOWN_LINE, `VERCEL_ENV ${JSON.stringify(v)}`);
      assert.deepEqual(shimCalls(log), [], 'no git call at all');
    }
  });
});
