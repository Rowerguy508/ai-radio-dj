import { NextRequest, NextResponse } from 'next/server';

// MiniMax T2A v2 API for text-to-speech
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { text, speed, style } = body;

    const apiKey = process.env.MINIMAX_API_KEY;
    if (!apiKey) {
      return NextResponse.json({ error: 'MINIMAX_API_KEY not configured' }, { status: 500 });
    }

    // Pick voice based on style
    const voices: Record<string, string> = {
      chill: 'English_Calm_Woman',
      balanced: 'English_expressive_narrator',
      hype: 'English_Insightful_Speaker',
    };
    const voiceId = voices[style] || voices.balanced;

    // Vary speed slightly for natural feel (0.9-1.1 range)
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
          voice_id: voiceId,
          speed: Math.round(naturalSpeed * 100) / 100,
          vol: 1,
          pitch: 0,
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
      console.error('MiniMax T2A error:', res.status, errText);
      return NextResponse.json({ error: 'TTS generation failed' }, { status: 500 });
    }

    const data = await res.json();

    // MiniMax returns audio as hex-encoded string in data.data.audio
    const audioHex = data?.data?.audio;
    if (!audioHex) {
      console.error('No audio in MiniMax response:', JSON.stringify(data).slice(0, 500));
      return NextResponse.json({ error: 'No audio returned' }, { status: 500 });
    }

    // Convert hex to base64 for the browser
    const audioBuffer = Buffer.from(audioHex, 'hex');
    const base64Audio = audioBuffer.toString('base64');

    return NextResponse.json({
      audio: `data:audio/mp3;base64,${base64Audio}`,
      duration: text.split(/\s+/).length / 2.5,
    });
  } catch (error) {
    console.error('Voice generation error:', error);
    return NextResponse.json({ error: 'Failed to generate voice' }, { status: 500 });
  }
}
