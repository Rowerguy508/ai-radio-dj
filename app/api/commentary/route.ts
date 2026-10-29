import { NextRequest, NextResponse } from 'next/server';
import { generateCommentary } from '@/lib/llm/commentary';
import { PaidInferenceRefusal, paidRoutesEnabled } from '@/lib/llm/paid-inference';

// Off in production unless ENABLE_PAID_INFERENCE=true.
export async function POST(request: NextRequest) {
  const requestId = crypto.randomUUID();
  if (!paidRoutesEnabled()) {
    return NextResponse.json({ error: 'Not found', requestId }, { status: 404 });
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
