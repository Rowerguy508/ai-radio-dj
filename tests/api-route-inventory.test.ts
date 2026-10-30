import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
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
});
