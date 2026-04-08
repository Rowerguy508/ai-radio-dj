import { NextRequest, NextResponse } from 'next/server';

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const code = searchParams.get('code');
  const error = searchParams.get('error');

  if (error || !code) {
    // User denied access or something went wrong
    const redirectUrl = new URL('/', req.url);
    redirectUrl.searchParams.set('error', error || 'spotify_auth_failed');
    return NextResponse.redirect(redirectUrl);
  }

  // Redirect back to homepage with the auth code
  // The client-side SpotifyProvider will exchange it for a token using PKCE
  const redirectUrl = new URL('/', req.url);
  redirectUrl.searchParams.set('code', code);
  return NextResponse.redirect(redirectUrl);
}
