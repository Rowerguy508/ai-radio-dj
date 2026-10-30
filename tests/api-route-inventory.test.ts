import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { unstable_doesMiddlewareMatch } from 'next/experimental/testing/server';
import { describe, expect, it } from 'vitest';

// #178: every integration branch gets a public ray-do preview, so a new or
// revived API route ships to the internet as soon as it is pushed. This list
// is the reviewed surface. Adding a route means updating it in a reviewed PR.
const REVIEWED_ROUTES: Record<string, string[]> = {
  'commentary/route.ts': ['POST'],
  'messages/route.ts': ['GET', 'PATCH', 'POST'],
  'spotify/callback/route.ts': ['GET'],
  'spotify/disconnect/route.ts': ['GET'],
  'stations/route.ts': ['GET', 'POST', 'PUT'],
  'telegram/route.ts': ['POST'],
  'voice/route.ts': ['POST'],
  'voices/route.ts': ['DELETE', 'GET', 'POST'],
  'webhooks/telegram/route.ts': ['POST'],
};

const API_DIR = path.resolve(__dirname, '..', 'app', 'api');
const METHODS = ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'];

function routeFiles(dir: string, prefix = ''): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = path.join(dir, entry);
    const rel = prefix ? `${prefix}/${entry}` : entry;
    if (statSync(full).isDirectory()) return routeFiles(full, rel);
    return /^route\.(ts|tsx|js|mjs)$/.test(entry) ? [rel] : [];
  });
}

function exportedMethods(file: string): string[] {
  const source = readFileSync(path.join(API_DIR, file), 'utf8');
  return METHODS.filter((method) =>
    new RegExp(`export\\s+(async\\s+)?(function|const)\\s+${method}\\b`).test(source),
  ).sort();
}

describe('API route inventory', () => {
  it('matches the reviewed list of route files', () => {
    expect(routeFiles(API_DIR).sort()).toEqual(Object.keys(REVIEWED_ROUTES).sort());
  });

  it('exports only the reviewed methods from each route', () => {
    for (const [file, methods] of Object.entries(REVIEWED_ROUTES)) {
      expect(exportedMethods(file), file).toEqual([...methods].sort());
    }
  });

  it('never constructs the service-role client in a route handler', () => {
    for (const file of routeFiles(API_DIR)) {
      const source = readFileSync(path.join(API_DIR, file), 'utf8');
      expect(source, file).not.toContain('createAdminClient');
    }
  });

  it('keeps every paid route behind the opt-in gate', () => {
    for (const file of ['commentary/route.ts', 'voice/route.ts']) {
      const source = readFileSync(path.join(API_DIR, file), 'utf8');
      expect(source, file).toContain('if (!paidRoutesEnabled())');
    }
  });

  it('keeps every paid route behind the admin token as well', () => {
    for (const file of ['commentary/route.ts', 'voice/route.ts']) {
      const source = readFileSync(path.join(API_DIR, file), 'utf8');
      expect(source, file).toContain('await adminDecision(request.headers)');
    }
  });

  it('runs the fail-closed middleware on every /api path', async () => {
    const { config } = await import('@/middleware');
    expect(config.matcher).toEqual(['/api', '/api/:path*']);
  });

  // Sentinel's nit on #268: pin matcher behaviour, not just the array.
  it('runs the middleware on /api, every path under it, and trailing-slash forms', async () => {
    const { config } = await import('@/middleware');
    for (const url of [
      '/api', '/api/', '/api/foo', '/api/foo/', '/api/voices', '/api/voices/', '/api/a/b/c',
      '/api/telegram/set-webhook', '/api/voices.rsc', '/api/voices?x=1', '/api/%76oices', '/api/voices%2F',
      '/_next/data/build-id/api/voices.json',
    ]) {
      expect(unstable_doesMiddlewareMatch({ config, url }), url).toBe(true);
    }
  });

  it('does not treat look-alike prefixes or other case as /api', async () => {
    const { config } = await import('@/middleware');
    for (const url of ['/apix', '/apix/voices', '/api-foo', '/api-voices', '/API', '/API/voices', '/Api/voices', '/aPI/voices', '/', '/about']) {
      expect(unstable_doesMiddlewareMatch({ config, url }), url).toBe(false);
    }
  });

  // Paths the matcher skips (look-alikes, other case) are safe only because nothing can
  // serve them: every handler lives under lowercase app/api (routing is case-sensitive,
  // so /API/... is a 404), there is no pages/ or src/ tree, and no config rewrites,
  // basePath or middleware URL-normalisation switch. Built-server probe at dac01e5:
  // /API/voices, /Api/voices, /apix, /api-foo -> 404 page; /api%2Fvoices, /%61pi/voices,
  // /api/%76oices, /api/./voices -> 401; //api/voices, /api/voices/ -> 308 to the gated path.
  it('has no route handler or alternate router that the matcher could miss', () => {
    const APP_DIR = path.resolve(__dirname, '..', 'app');
    const handlers = routeFiles(APP_DIR);
    expect(handlers.length).toBeGreaterThan(0);
    for (const file of handlers) expect(file, file).toMatch(/^api\//);
    for (const entry of readdirSync(APP_DIR)) {
      if (entry !== 'api') expect(entry.toLowerCase(), entry).not.toMatch(/^[(\[]|^api/);
    }
    const root = path.resolve(__dirname, '..');
    for (const dir of ['pages', 'src', 'src/app', 'src/pages']) {
      expect(existsSync(path.join(root, dir)), dir).toBe(false);
    }
    const nextConfig = readFileSync(path.join(root, 'next.config.js'), 'utf8');
    for (const key of ['rewrites', 'basePath', 'skipMiddlewareUrlNormalize', 'skipTrailingSlashRedirect', 'trailingSlash', 'i18n']) {
      expect(nextConfig, key).not.toContain(key);
    }
  });
});
