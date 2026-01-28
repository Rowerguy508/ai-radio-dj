import { NextRequest, NextResponse } from 'next/server';
import { createCommentaryGenerator } from '@/lib/llm/commentary';

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { context, maxLength, style } = body;

    const generator = createCommentaryGenerator();
    const result = await generator.generateCommentary({ context, maxLength, style });

    return NextResponse.json(result);
  } catch (error) {
    console.error('Commentary generation error:', error);
    return NextResponse.json(
      { error: 'Failed to generate commentary' },
      { status: 500 }
    );
  }
}
