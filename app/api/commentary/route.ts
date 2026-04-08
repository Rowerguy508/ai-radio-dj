import { NextRequest, NextResponse } from 'next/server';
import { generateCommentary } from '@/lib/llm/commentary';

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { context, style } = body;

    if (!context?.currentTrack || !context?.station) {
      return NextResponse.json(
        { error: 'Missing required context (currentTrack and station)' },
        { status: 400 }
      );
    }

    const result = await generateCommentary(context, style);
    return NextResponse.json(result);
  } catch (error) {
    console.error('Commentary generation error:', error);
    return NextResponse.json(
      { error: 'Failed to generate commentary' },
      { status: 500 }
    );
  }
}
