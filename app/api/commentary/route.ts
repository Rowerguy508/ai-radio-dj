import { NextRequest, NextResponse } from 'next/server';
import { generateCommentary } from '@/lib/llm/commentary';

export async function POST(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const body = await request.json();
    const { context } = body;

    if (!context?.station) {
      return NextResponse.json({ error: 'Missing station context', requestId }, { status: 400 });
    }

    const result = await generateCommentary(context);
    return NextResponse.json({ ...result, requestId });
  } catch (error) {
    console.error('Commentary error:', { requestId, error });
    return NextResponse.json({ error: 'Failed to generate commentary', requestId }, { status: 500 });
  }
}
