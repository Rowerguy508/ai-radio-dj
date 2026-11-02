import { NextRequest, NextResponse } from 'next/server';
import {
  PAID_TEXT_MAX_CHARS,
  paidRoutesEnabled,
  reservePaidCharacters,
  resolveSpeed,
} from '@/lib/llm/paid-inference';
import { adminDecision } from '@/lib/auth/route-gate';

// MiniMax T2A v2 API for text-to-speech.
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
    const { text, speed, style } = body;

    if (!text || typeof text !== 'string') {
      return NextResponse.json({ error: 'Text is required', requestId }, { status: 400 });
    }
    if (text.length > PAID_TEXT_MAX_CHARS) {
      return NextResponse.json({ error: 'invalid_input', requestId }, { status: 413 });
    }
    const resolvedSpeed = resolveSpeed(speed);
    if (resolvedSpeed === null) {
      return NextResponse.json({ error: 'invalid_input', requestId }, { status: 400 });
    }

    const apiKey = process.env.MINIMAX_API_KEY;
    if (!apiKey) {
      return NextResponse.json({ error: 'MINIMAX_API_KEY not configured', requestId }, { status: 500 });
    }
    if (!reservePaidCharacters(text.length)) {
      return NextResponse.json({ error: 'budget_exceeded', requestId }, { status: 429 });
    }

    const voiceConfig: Record<string, { voice: string; emotion: string }> = {
      chill: { voice: 'Wise_Woman', emotion: 'neutral' },
      balanced: { voice: 'English_expressive_narrator', emotion: 'happy' },
      hype: { voice: 'Casual Guy', emotion: 'happy' },
    };
    const config = voiceConfig[style] || voiceConfig.balanced;

    const res = await fetch('https://api.minimaxi.chat/v1/t2a_v2', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: 'speech-02-hd',
        text,
        stream: false,
        voice_setting: {
          voice_id: config.voice,
          speed: resolvedSpeed,
          vol: 1,
          pitch: 0,
          emotion: config.emotion,
        },
        audio_setting: {
          sample_rate: 32000,
          bitrate: 128000,
          format: 'mp3',
          channel: 1,
        },
      }),
    });

    if (!res.ok) {
      console.error('MiniMax T2A error:', { requestId, status: res.status });
      return NextResponse.json({ error: 'TTS generation failed', requestId }, { status: 500 });
    }

    const data = await res.json();
    const audioHex = data?.data?.audio;
    if (!audioHex) {
      console.error('No audio in MiniMax response:', { requestId });
      return NextResponse.json({ error: 'No audio returned', requestId }, { status: 500 });
    }

    const audioBuffer = Buffer.from(audioHex, 'hex');
    const base64Audio = audioBuffer.toString('base64');

    return NextResponse.json({
      audio: `data:audio/mp3;base64,${base64Audio}`,
      duration: text.split(/\s+/).length / 2.5,
      requestId,
    });
  } catch {
    console.error('Voice generation error:', { requestId });
    return NextResponse.json({ error: 'Failed to generate voice', requestId }, { status: 500 });
  }
}
