import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { unstable_doesMiddlewareMatch } from 'next/experimental/testing/server';
import ts from 'typescript';
import { describe, expect, it } from 'vitest';

// #178 / #235: every integration branch gets a public ray-do preview, so a new or
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

const ROOT_DIR = path.resolve(__dirname, '..');
const APP_DIR = path.join(ROOT_DIR, 'app');
const API_DIR = path.join(APP_DIR, 'api');
const METHODS = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']);
const ROUTE_FILE_RE = /^route\.(ts|tsx|js|jsx|mjs|cjs)$/;
const CODE_FILE_RE = /\.(ts|tsx|js|jsx|mjs|cjs)$/;

function walkFiles(dir: string, predicate: (entry: string) => boolean, prefix = ''): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).flatMap((entry) => {
    const full = path.join(dir, entry);
    const rel = prefix ? `${prefix}/${entry}` : entry;
    if (statSync(full).isDirectory()) return walkFiles(full, predicate, rel);
    return predicate(entry) ? [rel] : [];
  });
}

function routeFiles(dir: string, prefix = ''): string[] {
  return walkFiles(dir, (entry) => ROUTE_FILE_RE.test(entry), prefix);
}

/**
 * #235 (2): scan every Next.js route surface across app/, src/app/, pages/api/, and src/pages/api/.
 * Returns repo-relative paths.
 */
function allRepoRouteHandlers(root: string): string[] {
  const found: string[] = [
    ...routeFiles(path.join(root, 'app'), 'app'),
    ...routeFiles(path.join(root, 'src', 'app'), 'src/app'),
    ...walkFiles(path.join(root, 'pages', 'api'), (e) => CODE_FILE_RE.test(e), 'pages/api'),
    ...walkFiles(path.join(root, 'src', 'pages', 'api'), (e) => CODE_FILE_RE.test(e), 'src/pages/api'),
  ];
  return found.sort();
}

function allMiddlewareFiles(root: string): string[] {
  const candidates = [
    'middleware.ts', 'middleware.js', 'middleware.mjs', 'middleware.cjs',
    'src/middleware.ts', 'src/middleware.js', 'src/middleware.mjs', 'src/middleware.cjs',
  ];
  return candidates.filter((rel) => existsSync(path.join(root, rel))).sort();
}

function hasExportModifier(node: ts.Node): boolean {
  if (!ts.canHaveModifiers(node)) return false;
  return (ts.getModifiers(node) ?? []).some((m) => m.kind === ts.SyntaxKind.ExportKeyword);
}

function collectBindingNames(name: ts.BindingName, out: Set<string>): void {
  if (ts.isIdentifier(name)) {
    out.add(name.text);
  } else if (ts.isObjectBindingPattern(name) || ts.isArrayBindingPattern(name)) {
    for (const el of name.elements) {
      if (ts.isBindingElement(el)) collectBindingNames(el.name, out);
    }
  }
}

/**
 * #235 (1): AST-based exported HTTP method detector.
 * Catches `export async function POST`, `export const POST = ...`, destructured exports,
 * aliased exports (`export { handler as POST }`), re-exports (`export { handler as POST } from '...'`),
 * and flags wildcard re-exports (`export * from '...'`) as an unreviewed export.
 */
function extractExportedMethods(source: string, fileName = 'route.ts'): string[] {
  const sf = ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true);
  const exported = new Set<string>();

  for (const stmt of sf.statements) {
    if (ts.isFunctionDeclaration(stmt) && hasExportModifier(stmt) && stmt.name) {
      exported.add(stmt.name.text);
    } else if (ts.isVariableStatement(stmt) && hasExportModifier(stmt)) {
      for (const decl of stmt.declarationList.declarations) {
        collectBindingNames(decl.name, exported);
      }
    } else if (ts.isExportDeclaration(stmt)) {
      if (!stmt.exportClause) {
        // Wildcard re-export (`export * from '...'`) could smuggle unreviewed HTTP methods.
        exported.add('*');
      } else if (ts.isNamedExports(stmt.exportClause)) {
        for (const spec of stmt.exportClause.elements) {
          exported.add(spec.name.text);
        }
      }
    }
  }

  return Array.from(exported).filter((name) => name === '*' || METHODS.has(name)).sort();
}

function exportedMethods(file: string): string[] {
  const full = path.join(API_DIR, file);
  return extractExportedMethods(readFileSync(full, 'utf8'), full);
}

const EQUALITY_OPS = new Set<ts.SyntaxKind>([
  ts.SyntaxKind.EqualsEqualsEqualsToken,
  ts.SyntaxKind.ExclamationEqualsEqualsToken,
  ts.SyntaxKind.EqualsEqualsToken,
  ts.SyntaxKind.ExclamationEqualsToken,
]);

/**
 * #235 (3): AST check that a source file calls `requiredHelper`, optionally imports it from
 * `requiredImport`, and never compares secret-related identifiers with `===`/`!==`/`==`/`!=`.
 */
function auditConstantTimeSecretCheck(
  source: string,
  fileName: string,
  opts: { requiredHelper: string; requiredImport?: string; secretHints: RegExp },
): { imported: boolean; called: boolean; plainComparisons: string[] } {
  const sf = ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true);
  let imported = opts.requiredImport === undefined;
  let localHelperName = opts.requiredHelper;
  let called = false;
  const plainComparisons: string[] = [];

  function visit(node: ts.Node): void {
    if (
      opts.requiredImport &&
      ts.isImportDeclaration(node) &&
      ts.isStringLiteral(node.moduleSpecifier) &&
      node.moduleSpecifier.text === opts.requiredImport &&
      node.importClause?.namedBindings &&
      ts.isNamedImports(node.importClause.namedBindings)
    ) {
      for (const el of node.importClause.namedBindings.elements) {
        const importedName = el.propertyName ? el.propertyName.text : el.name.text;
        if (importedName === opts.requiredHelper) {
          imported = true;
          localHelperName = el.name.text;
        }
      }
    }
    if (ts.isCallExpression(node)) {
      const expr = node.expression;
      if (ts.isIdentifier(expr) && expr.text === localHelperName) called = true;
      if (ts.isPropertyAccessExpression(expr) && expr.name.text === opts.requiredHelper) called = true;
    }
    if (ts.isBinaryExpression(node) && EQUALITY_OPS.has(node.operatorToken.kind)) {
      const leftText = node.left.getText(sf);
      const rightText = node.right.getText(sf);
      const comparedToNullish =
        /^(null|undefined)$/.test(leftText.trim()) || /^(null|undefined)$/.test(rightText.trim());
      if (!comparedToNullish && (opts.secretHints.test(leftText) || opts.secretHints.test(rightText))) {
        plainComparisons.push(node.getText(sf));
      }
    }
    ts.forEachChild(node, visit);
  }

  visit(sf);
  return { imported, called, plainComparisons };
}

describe('API route inventory', () => {
  it('matches the reviewed list of route files across the entire repo (#235)', () => {
    const expected = Object.keys(REVIEWED_ROUTES)
      .map((rel) => `app/api/${rel}`)
      .sort();
    expect(allRepoRouteHandlers(ROOT_DIR)).toEqual(expected);
  });

  it('has only the single reviewed root middleware.ts (#235)', () => {
    expect(allMiddlewareFiles(ROOT_DIR)).toEqual(['middleware.ts']);
  });

  it('exports only the reviewed methods from each route (AST-checked, including aliases) (#235)', () => {
    for (const [file, methods] of Object.entries(REVIEWED_ROUTES)) {
      expect(exportedMethods(file), file).toEqual([...methods].sort());
    }
  });

  it('detects aliased, destructured, and re-exported HTTP methods (#235)', () => {
    expect(extractExportedMethods('const handler = () => {}; export { handler as POST };')).toEqual(['POST']);
    expect(extractExportedMethods('export { handle as DELETE, get as GET } from "./impl";')).toEqual(['DELETE', 'GET']);
    expect(extractExportedMethods('export const { PUT, PATCH } = handlers;')).toEqual(['PATCH', 'PUT']);
    expect(extractExportedMethods('export * from "./other";')).toEqual(['*']);
  });

  it('enforces constant-time webhook secret verification in both Telegram routes and helper (#235)', () => {
    const secretHints = /secret|TELEGRAM_WEBHOOK_SECRET|x-telegram-bot-api-secret-token/i;
    for (const file of ['telegram/route.ts', 'webhooks/telegram/route.ts']) {
      const full = path.join(API_DIR, file);
      const audit = auditConstantTimeSecretCheck(readFileSync(full, 'utf8'), full, {
        requiredHelper: 'webhookAuthorized',
        requiredImport: '@/lib/telegram/webhook-auth',
        secretHints,
      });
      expect(audit.imported, `${file} must import webhookAuthorized`).toBe(true);
      expect(audit.called, `${file} must call webhookAuthorized`).toBe(true);
      expect(audit.plainComparisons, `${file} must not compare secrets with ===/!==`).toEqual([]);
    }

    const helperPath = path.join(ROOT_DIR, 'lib', 'telegram', 'webhook-auth.ts');
    const helperAudit = auditConstantTimeSecretCheck(readFileSync(helperPath, 'utf8'), helperPath, {
      requiredHelper: 'timingSafeEqual',
      secretHints: /\b(provided|rawExpected|expected|actual|wanted)\b/,
    });
    expect(helperAudit.called, 'webhook-auth.ts must call timingSafeEqual').toBe(true);
    expect(helperAudit.plainComparisons, 'webhook-auth.ts must not compare secrets with ===/!==').toEqual([]);

    // Self-test: a plain === secret compare mutation is caught.
    const mutated = auditConstantTimeSecretCheck(
      'export async function POST(req) { if (incomingSecret !== expectedSecret) return 401; }',
      'mutated.ts',
      { requiredHelper: 'webhookAuthorized', requiredImport: '@/lib/telegram/webhook-auth', secretHints },
    );
    expect(mutated.called).toBe(false);
    expect(mutated.plainComparisons.length).toBe(1);
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
    const handlers = routeFiles(APP_DIR);
    expect(handlers.length).toBeGreaterThan(0);
    for (const file of handlers) expect(file, file).toMatch(/^api\//);
    for (const entry of readdirSync(APP_DIR)) {
      if (entry !== 'api') expect(entry.toLowerCase(), entry).not.toMatch(/^[(\[]|^api/);
    }
    for (const dir of ['pages', 'src', 'src/app', 'src/pages']) {
      expect(existsSync(path.join(ROOT_DIR, dir)), dir).toBe(false);
    }
    const nextConfig = readFileSync(path.join(ROOT_DIR, 'next.config.js'), 'utf8');
    for (const key of ['rewrites', 'basePath', 'skipMiddlewareUrlNormalize', 'skipTrailingSlashRedirect', 'trailingSlash', 'i18n']) {
      expect(nextConfig, key).not.toContain(key);
    }
  });
});
