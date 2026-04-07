// AI Commentary Generator using Anthropic Claude API

export interface TrackInfo {
  title: string;
  artist: string;
  album?: string;
  year?: number;
  genre?: string;
}

export interface CommentaryContext {
  station: {
    name: string;
    energy: number; // 0-1
    style: 'chill' | 'balanced' | 'hype';
  };
  previousTrack?: TrackInfo;
  currentTrack: TrackInfo;
  nextTrack?: TrackInfo;
  timeOfDay?: string;
  isFirstTrack?: boolean;
  isTransition?: boolean;
}

export interface CommentaryResponse {
  text: string;
  estimatedDuration: number; // seconds
}

// Server-side only: generate commentary via Claude API
export async function generateCommentary(
  context: CommentaryContext,
  style: 'short' | 'medium' | 'long' = 'medium'
): Promise<CommentaryResponse> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return generateFallbackCommentary(context);
  }

  const systemPrompt = buildSystemPrompt(context);
  const userPrompt = buildUserPrompt(context, style);

  try {
    const response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 300,
        system: systemPrompt,
        messages: [{ role: 'user', content: userPrompt }],
      }),
    });

    if (!response.ok) {
      throw new Error(`Claude API error: ${response.status}`);
    }

    const data = await response.json();
    const text = data.content?.[0]?.text || '';

    return {
      text,
      estimatedDuration: estimateAudioDuration(text),
    };
  } catch (error) {
    console.error('Commentary generation failed:', error);
    return generateFallbackCommentary(context);
  }
}

function buildSystemPrompt(context: CommentaryContext): string {
  const { station } = context;

  const personalities: Record<string, string> = {
    chill: `You are a smooth, laid-back radio host. Warm, relaxed, calm tone. You make listeners feel comfortable. Not overly excited - you appreciate good music and share insights thoughtfully.`,
    hype: `You're an energetic, enthusiastic radio host! You get excited about great tracks, pump up the audience, and make every song feel special. Your energy is infectious.`,
    balanced: `You're a friendly, engaging radio host who balances energy with sophistication. Knowledgeable about music, you tell interesting stories and keep listeners entertained.`,
  };

  return `${personalities[station.style] || personalities.balanced}

You are the AI DJ for "${station.name}".

Rules:
- Keep commentary under 100 words
- Stay in radio host character at all times
- Make it feel natural, like real radio
- Energy level: ${station.energy < 0.3 ? 'very chill' : station.energy < 0.7 ? 'balanced' : 'high energy'}
- Output ONLY the spoken words - no stage directions, no quotes, no asterisks`;
}

function buildUserPrompt(
  context: CommentaryContext,
  style: 'short' | 'medium' | 'long'
): string {
  const wordLimits = { short: 30, medium: 60, long: 100 };
  let prompt = `Generate a ${style} DJ commentary (max ${wordLimits[style]} words).\n\n`;

  prompt += `Now playing: "${context.currentTrack.title}" by ${context.currentTrack.artist}`;
  if (context.currentTrack.album) prompt += ` from "${context.currentTrack.album}"`;
  prompt += '\n';

  if (context.previousTrack) {
    prompt += `Previous: "${context.previousTrack.title}" by ${context.previousTrack.artist}\n`;
  }
  if (context.nextTrack) {
    prompt += `Up next: "${context.nextTrack.title}" by ${context.nextTrack.artist}\n`;
  }
  if (context.isFirstTrack) {
    prompt += `\nThis is the first track - welcome the listener!\n`;
  }
  if (context.isTransition) {
    prompt += `\nTransition between tracks - smooth handoff.\n`;
  }
  if (context.timeOfDay) {
    prompt += `Time: ${context.timeOfDay}\n`;
  }

  return prompt;
}

function estimateAudioDuration(text: string): number {
  const wordsPerMinute = 150;
  const wordCount = text.split(/\s+/).length;
  return Math.ceil((wordCount / wordsPerMinute) * 60);
}

function generateFallbackCommentary(context: CommentaryContext): CommentaryResponse {
  const { currentTrack, station, isFirstTrack } = context;

  let text: string;
  if (isFirstTrack) {
    text = `Welcome to ${station.name}! Kicking things off with "${currentTrack.title}" by ${currentTrack.artist}. Let's go.`;
  } else if (context.previousTrack) {
    text = `That was "${context.previousTrack.title}" by ${context.previousTrack.artist}. Now here's "${currentTrack.title}" by ${currentTrack.artist} on ${station.name}.`;
  } else {
    text = `You're listening to "${currentTrack.title}" by ${currentTrack.artist} on ${station.name}.`;
  }

  return { text, estimatedDuration: estimateAudioDuration(text) };
}
