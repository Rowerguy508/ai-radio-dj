import { NextRequest, NextResponse } from 'next/server';
import { apiDecision } from '@/lib/auth/route-gate';

// Every /api route on the legacy ray-do app is closed by default (#174 §6).
export async function middleware(request: NextRequest) {
  const decision = await apiDecision(request.nextUrl.pathname, request.headers);
  if (decision.allow) return NextResponse.next();
  return NextResponse.json(
    { error: decision.error },
    { status: decision.status, headers: { 'cache-control': 'no-store' } },
  );
}

export const config = {
  matcher: ['/api', '/api/:path*'],
};
