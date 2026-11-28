import { NextRequest, NextResponse } from 'next/server';
import { mintDeveloperToken } from '@/lib/apple-music/developer-token';
import {
  clientAddress,
  originAllowed,
  parseOriginAllowlist,
  permitTokenRequest,
} from '@/lib/apple-music/token-access';

// #36: the browser asks here for a short-lived developer token instead of reading a
// long-lived one from a NEXT_PUBLIC_ variable baked into the bundle.
//
// This route is not added to any public allowlist in lib/auth/route-gate.ts, so the
// fail-closed /api middleware (#174) still requires the admin token in front of it.
// Opening it to anonymous browsers is a separate, reviewed route-gate change.

const NO_STORE = { 'cache-control': 'no-store' };

function configuredValue(name: string): string | null {
  const value = process.env[name];
  if (!value || !value.trim()) return null;
  return value;
}

function reply(body: Record<string, string>, status: number) {
  return NextResponse.json(body, { status, headers: NO_STORE });
}

// The Origin header is not a boundary against non-browser callers: they can set it.
// MusicKit JS enforces the token's `origin` claim, and the lifetime stays capped.
// POST only: browsers attach Origin to a POST fetch, but not always to a same-origin GET.
export function POST(request: NextRequest) {
  const teamId = configuredValue('APPLE_MUSIC_TEAM_ID');
  const keyId = configuredValue('APPLE_MUSIC_KEY_ID');
  const privateKey = configuredValue('APPLE_MUSIC_PRIVATE_KEY');
  if (!teamId || !keyId || !privateKey) {
    return reply({ error: 'Not found' }, 404);
  }

  const allowlist = parseOriginAllowlist(process.env.APPLE_MUSIC_ALLOWED_ORIGINS);
  if (!originAllowed(request.headers.get('origin'), allowlist)) {
    return reply({ error: 'Forbidden' }, 403);
  }

  // #78: only an allowed origin spends rate budget, so refused origins cannot drain
  // a bucket. Best-effort, per instance; see lib/apple-music/token-access.ts.
  // Fails closed (#78): if the limiter itself throws, refuse the request and mint
  // nothing. The refusal is a fixed body, so no error text, key or token is echoed.
  let permitted: boolean;
  try {
    permitted = permitTokenRequest(clientAddress(request.headers));
  } catch {
    return reply({ error: 'Service unavailable' }, 503);
  }
  if (!permitted) {
    return reply({ error: 'Too many requests' }, 429);
  }

  try {
    const token = mintDeveloperToken({
      teamId,
      keyId,
      privateKeyPem: privateKey,
      origins: allowlist,
    });
    return reply({ token }, 200);
  } catch {
    return reply({ error: 'Not found' }, 404);
  }
}
