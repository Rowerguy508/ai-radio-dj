import { NextRequest, NextResponse } from 'next/server';
import { mintDeveloperToken } from '@/lib/apple-music/developer-token';
import {
  clientAddress,
  originAllowed,
  parseOriginAllowlist,
  permitTokenRequest,
} from '@/lib/apple-music/token-access';

function configuredValue(name: string): string | null {
  const value = process.env[name];
  if (!value || !value.trim()) return null;
  return value;
}

// The Origin header is not a boundary against non-browser callers: they can set it.
// MusicKit JS enforces the token's `origin` claim, and the lifetime stays capped.
function issue(request: NextRequest) {
  const teamId = configuredValue('APPLE_MUSIC_TEAM_ID');
  const keyId = configuredValue('APPLE_MUSIC_KEY_ID');
  const privateKey = configuredValue('APPLE_MUSIC_PRIVATE_KEY');
  if (!teamId || !keyId || !privateKey) {
    return NextResponse.json({ error: 'Not found' }, { status: 404 });
  }

  if (!permitTokenRequest(clientAddress(request))) {
    return NextResponse.json({ error: 'Too many requests' }, { status: 429 });
  }

  const allowlist = parseOriginAllowlist(process.env.APPLE_MUSIC_ALLOWED_ORIGINS);
  const origin = request.headers.get('origin');
  if (!originAllowed(origin, allowlist)) {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }

  try {
    const token = mintDeveloperToken({
      teamId,
      keyId,
      privateKeyPem: privateKey,
      origins: allowlist,
    });
    return NextResponse.json({ token });
  } catch {
    return NextResponse.json({ error: 'Not found' }, { status: 404 });
  }
}

export function GET(request: NextRequest) {
  return issue(request);
}

export function POST(request: NextRequest) {
  return issue(request);
}
