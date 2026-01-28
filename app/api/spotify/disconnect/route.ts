import { NextRequest, NextResponse } from 'next/server';

// Clear Spotify tokens and redirect to home
export async function GET(request: NextRequest) {
  const response = NextResponse.redirect(new URL('/', request.url));
  
  // Clear cookies/localStorage keys (client will handle the rest)
  response.cookies.delete('spotify_access_token');
  
  return response;
}
