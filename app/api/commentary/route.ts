import { NextRequest, NextResponse } from 'next/server';
import { generateCommentary } from '@/lib/llm/commentary';

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { context } = body;

    if (!context?.station) {
      return NextResponse.json({ error: 'Missing station context' }, { status: 400 });
    }

    const result = await generateCommentary(context);
    return NextResponse.json(result);
  } catch (error) {
    console.error('Commentary error:', error);
    return NextResponse.json({ error: 'Failed to generate commentary' }, { status: 500 });
  }
}
