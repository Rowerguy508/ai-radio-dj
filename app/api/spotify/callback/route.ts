import { NextRequest, NextResponse } from 'next/server';

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const accessToken = searchParams.get('access_token');
  const expiresIn = searchParams.get('expires_in');

  if (!accessToken) {
    return NextResponse.redirect(new URL('/?error=spotify_auth_failed', req.url));
  }

  // Redirect to home with token in URL (for client to store)
  const response = NextResponse.redirect(new URL(`/?spotify_token=${accessToken}&spotify_expires=${expiresIn}`, req.url));
  
  return response;
}
