import { NextRequest, NextResponse } from 'next/server';
import { createAdminClient } from '@/lib/database/supabase';

export interface AuthResult {
  userId: string | null;
  errorResponse: NextResponse | null;
}

function isAuthRequired(): boolean {
  return process.env.REQUIRE_AUTH === 'true';
}

export async function authorizeRequest(request: NextRequest, requestId: string): Promise<AuthResult> {
  if (!isAuthRequired()) {
    return { userId: null, errorResponse: null };
  }

  const authHeader = request.headers.get('authorization') || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  if (!token) {
    return {
      userId: null,
      errorResponse: NextResponse.json({ error: 'Missing bearer token', requestId }, { status: 401 }),
    };
  }

  const supabase = createAdminClient();
  if (!supabase) {
    return {
      userId: null,
      errorResponse: NextResponse.json({ error: 'Auth is required but Supabase is not configured', requestId }, { status: 503 }),
    };
  }

  const { data, error } = await (supabase as any).auth.getUser(token);
  if (error || !data?.user?.id) {
    return {
      userId: null,
      errorResponse: NextResponse.json({ error: 'Invalid auth token', requestId }, { status: 401 }),
    };
  }

  return { userId: data.user.id, errorResponse: null };
}
