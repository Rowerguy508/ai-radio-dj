import { NextResponse } from 'next/server';
import { mintDeveloperToken } from '@/lib/apple-music/developer-token';

function configuredValue(name: string): string | null {
  const value = process.env[name];
  if (!value || !value.trim()) return null;
  return value;
}

// Caller-supplied lifetimes are ignored. Missing or unusable key material is a 404
// with no detail, so the browser can skip MusicKit instead of embedding a token.
export function GET() {
  const teamId = configuredValue('APPLE_MUSIC_TEAM_ID');
  const keyId = configuredValue('APPLE_MUSIC_KEY_ID');
  const privateKey = configuredValue('APPLE_MUSIC_PRIVATE_KEY');
  if (!teamId || !keyId || !privateKey) {
    return NextResponse.json({ error: 'Not found' }, { status: 404 });
  }

  try {
    const token = mintDeveloperToken({ teamId, keyId, privateKeyPem: privateKey });
    return NextResponse.json({ token });
  } catch {
    return NextResponse.json({ error: 'Not found' }, { status: 404 });
  }
}
