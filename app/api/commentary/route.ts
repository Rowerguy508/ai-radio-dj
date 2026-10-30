import { NextRequest, NextResponse } from 'next/server';
import { generateCommentary } from '@/lib/llm/commentary';
import { PaidInferenceRefusal, paidRoutesEnabled } from '@/lib/llm/paid-inference';
import { adminDecision } from '@/lib/auth/route-gate';

// Off in production unless ENABLE_PAID_INFERENCE=true, and always needs RAY_DO_ADMIN_TOKEN.
export async function POST(request: NextRequest) {
  const requestId = crypto.randomUUID();
  if (!paidRoutesEnabled()) {
    return NextResponse.json({ error: 'Not found', requestId }, { status: 404 });
  }
  // Middleware already requires the admin token; this repeats it next to the spend.
  const auth = await adminDecision(request.headers);
  if (!auth.allow) {
    return NextResponse.json({ error: auth.error, requestId }, { status: auth.status });
  }

  try {
    const body = await request.json();
    const { context } = body;

    if (!context?.station) {
      return NextResponse.json({ error: 'Missing station context', requestId }, { status: 400 });
    }

    const result = await generateCommentary(context);
    return NextResponse.json({ ...result, requestId });
  } catch (error) {
    if (error instanceof PaidInferenceRefusal) {
      return NextResponse.json({ error: error.code, requestId }, { status: error.status });
    }
    console.error('Commentary error:', { requestId });
    return NextResponse.json({ error: 'Failed to generate commentary', requestId }, { status: 500 });
  }
}
