import { NextRequest, NextResponse } from 'next/server';
import { createElevenLabsClient, getVoiceSettingsForEnergy } from '@/lib/elevenlabs/client';

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { text, voiceId, energy, voiceSettings } = body;

    const apiKey = process.env.ELEVENLABS_API_KEY;
    if (!apiKey) {
      return NextResponse.json(
        { error: 'ElevenLabs API key not configured' },
        { status: 500 }
      );
    }

    const client = createElevenLabsClient(apiKey);

    // Get voice settings based on energy or use custom settings
    const settings = voiceSettings || getVoiceSettingsForEnergy(energy || 0.5);

    const audioBuffer = await client.generateSpeech({
      voiceId,
      text,
      ...settings,
    });

    // Return audio as base64
    const base64Audio = Buffer.from(audioBuffer).toString('base64');

    return NextResponse.json({
      audio: `data:audio/mp3;base64,${base64Audio}`,
      duration: text.split(/\s+/).length / 2.5, // Rough estimate
    });
  } catch (error) {
    console.error('Voice generation error:', error);
    return NextResponse.json(
      { error: 'Failed to generate voice' },
      { status: 500 }
    );
  }
}
