import { NextRequest, NextResponse } from 'next/server';

// MiniMax T2A v2 API for text-to-speech
export async function POST(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const body = await request.json();
    const { text, speed, style } = body;

    if (!text || typeof text !== 'string') {
      return NextResponse.json({ error: 'Text is required', requestId }, { status: 400 });
    }

    if (style && !['chill', 'balanced', 'hype'].includes(style)) {
      return NextResponse.json({ error: 'Invalid style value', requestId }, { status: 400 });
    }

    const apiKey = process.env.MINIMAX_API_KEY;
    if (!apiKey) {
      return NextResponse.json({ error: 'MINIMAX_API_KEY not configured', requestId }, { status: 500 });
    }

    // Pick voice and emotion based on style
    const voiceConfig: Record<string, { voice: string; emotion: string }> = {
      chill: { voice: 'Wise_Woman', emotion: 'neutral' },
      balanced: { voice: 'English_expressive_narrator', emotion: 'happy' },
      hype: { voice: 'Casual Guy', emotion: 'happy' },
    };
    const config = voiceConfig[style] || voiceConfig.balanced;

    // Vary speed slightly per request for natural feel
    const baseSpeed = speed || 1.0;
    const naturalSpeed = baseSpeed + (Math.random() * 0.15 - 0.075);

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
          speed: Math.round(naturalSpeed * 100) / 100,
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
      const errText = await res.text();
      console.error('MiniMax T2A error:', { requestId, status: res.status, errText });
      return NextResponse.json({ error: 'TTS generation failed', requestId }, { status: 500 });
    }

    const data = await res.json();

    // MiniMax returns audio as hex-encoded string in data.data.audio
    const audioHex = data?.data?.audio;
    if (!audioHex) {
      console.error('No audio in MiniMax response:', { requestId, data: JSON.stringify(data).slice(0, 500) });
      return NextResponse.json({ error: 'No audio returned', requestId }, { status: 500 });
    }

    // Convert hex to base64 for the browser
    const audioBuffer = Buffer.from(audioHex, 'hex');
    const base64Audio = audioBuffer.toString('base64');

    return NextResponse.json({
      audio: `data:audio/mp3;base64,${base64Audio}`,
      duration: text.split(/\s+/).length / 2.5,
      requestId,
    });
  } catch (error) {
    console.error('Voice generation error:', { requestId, error });
    return NextResponse.json({ error: 'Failed to generate voice', requestId }, { status: 500 });
  }
}
