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

function run(repo: string, prev: string | undefined, cwdRel = TTS): Result {
  const env: NodeJS.ProcessEnv = { ...GIT_ENV, IGNORE_BUILD_FETCH_TIMEOUT_S: '10' };
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

before(() => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'tts-ignore-build-'));
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
      env: { ...GIT_ENV, VERCEL_GIT_PREVIOUS_SHA: '0123456789abcdef0123456789abcdef01234567', GIT_CEILING_DIRECTORIES: tmpRoot },
      encoding: 'utf8',
    });
    expectCode({ code: r.status, out: `${r.stdout}${r.stderr}` }, BUILD, 'no repo');
  });

  test('vercel.json points ignoreCommand at the script, not the last-commit diff', () => {
    const cfg = JSON.parse(fs.readFileSync(path.join(SERVICE_DIR, 'vercel.json'), 'utf8')) as { ignoreCommand?: string };
    assert.equal(cfg.ignoreCommand, 'bash scripts/vercel-ignore-build.sh');
    const body = fs.readFileSync(path.join(SERVICE_DIR, 'scripts', 'vercel-ignore-build.sh'), 'utf8');
    const code = body.split('\n').filter((l) => !l.trimStart().startsWith('#')).join('\n');
    assert.doesNotMatch(code, /HEAD(~|\^(?!\{))/, 'no last-commit comparison left in the script');
  });
});
