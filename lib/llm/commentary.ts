// LLM Commentary Generator using Clawdbot's local gateway

interface TrackInfo {
  title: string;
  artist: string;
  album?: string;
  year?: number;
  genre?: string;
  bpm?: number;
}

interface CommentaryContext {
  station: {
    name: string;
    energy: number; // 0-1
    style: 'chill' | 'balanced' | 'hype';
  };
  previousTrack?: TrackInfo;
  currentTrack: TrackInfo;
  nextTrack?: TrackInfo;
  timeOfDay?: string; // 'morning', 'afternoon', 'evening', 'night'
  recentMessages?: string[]; // Messages to read
  calendarEvent?: string; // Upcoming event
  weather?: string;
  isFirstTrack?: boolean;
  isTransition?: boolean;
  isEnding?: boolean;
}

interface CommentaryRequest {
  context: CommentaryContext;
  maxLength?: number;
  style?: 'short' | 'medium' | 'long';
}

interface CommentaryResponse {
  text: string;
  audioDuration?: number;
}

class CommentaryGenerator {
  private gatewayUrl: string;

  constructor(gatewayUrl?: string) {
    // Use env var in production, local gateway in development
    this.gatewayUrl = gatewayUrl || process.env.LLM_GATEWAY_URL || 'http://127.0.0.1:18789';
  }

  // Generate commentary for a track
  async generateCommentary(request: CommentaryRequest): Promise<CommentaryResponse> {
    const { context, maxLength = 200, style = 'medium' } = request;

    const systemPrompt = this.buildSystemPrompt(context);
    const userPrompt = this.buildUserPrompt(context, style);

    // Skip gateway in serverless environments (no local access)
    if (this.gatewayUrl.startsWith('http://127.0.0.1') || this.gatewayUrl.startsWith('http://localhost')) {
      const isServerless = process.env.VERCEL || process.env.AWS_LAMBDA_FUNCTION_NAME;
      if (isServerless) {
        console.log('Skipping local gateway in serverless env, using fallback');
        return this.generateFallbackCommentary(context);
      }
    }

    try {
      const response = await fetch(`${this.gatewayUrl}/v1/chat/completions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: 'minimax/MiniMax-M2.1',
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: userPrompt },
          ],
          max_tokens: 500,
          temperature: 0.8,
        }),
      });

      if (!response.ok) {
        throw new Error(`Gateway error: ${response.statusText}`);
      }

      const data = await response.json();
      const text = data.choices?.[0]?.message?.content || '';

      return {
        text: text.slice(0, maxLength),
        audioDuration: this.estimateAudioDuration(text),
      };
    } catch (error) {
      console.error('Commentary generation failed:', error);
      // Fallback to simple template
      return this.generateFallbackCommentary(context);
    }
  }

  // Build system prompt based on station settings
  private buildSystemPrompt(context: CommentaryContext): string {
    const { station } = context;

    let personality = '';

    switch (station.style) {
      case 'chill':
        personality = `You are a smooth, laid-back radio host. You're warm, relaxed, and speak in a calm, soothing tone. You make listeners feel comfortable and focused. You're not overly excited - you appreciate good music and share insights thoughtfully.`;
        break;
      case 'hype':
        personality = `You're an energetic, enthusiastic radio host! You get excited about great tracks, you pump up the audience, and you make every song feel like a special moment. Your energy is infectious and you love building anticipation.`;
        break;
      default:
        personality = `You're a friendly, engaging radio host who balances energy with sophistication. You're knowledgeable about music, tell interesting stories, and keep listeners entertained without being overwhelming.`;
    }

    return `${personality}

You are the AI DJ for "${station.name}" station.

Your rules:
- Keep commentary under 150 words
- Never break character - stay in radio host mode
- Make it feel natural, like real radio
- Include personal touches when appropriate
- Adapt your energy level: ${station.energy < 0.3 ? 'very chill' : station.energy < 0.7 ? 'balanced' : 'high energy'}
- If there are messages or calendar events, weave them in naturally

Remember: You're creating an immersive radio experience, not just reading track info.`;
  }

  // Build user prompt for the specific situation
  private buildUserPrompt(context: CommentaryContext, style: 'short' | 'medium' | 'long'): string {
    let prompt = `Generate ${style} radio commentary for this track:\n\n`;

    prompt += `Current Track: "${context.currentTrack.title}" by ${context.currentTrack.artist}`;
    if (context.currentTrack.album) prompt += ` from the album "${context.currentTrack.album}"`;
    if (context.currentTrack.year) prompt += ` (${context.currentTrack.year})`;
    if (context.currentTrack.genre) prompt += ` - Genre: ${context.currentTrack.genre}`;
    prompt += '\n';

    if (context.previousTrack) {
      prompt += `Previous Track: "${context.previousTrack.title}" by ${context.previousTrack.artist}\n`;
    }

    if (context.nextTrack) {
      prompt += `Up Next: "${context.nextTrack.title}" by ${context.nextTrack.artist}\n`;
    }

    if (context.isFirstTrack) {
      prompt += `\nThis is the first track of the station - welcome the listener!\n`;
    }

    if (context.isTransition) {
      prompt += `\nThis is a transition between tracks - smooth handoff!\n`;
    }

    if (context.isEnding) {
      prompt += `\nThis is the end of a set - sign off smoothly!\n`;
    }

    if (context.recentMessages && context.recentMessages.length > 0) {
      prompt += `\nMessages to read:\n${context.recentMessages.join('\n')}\n`;
    }

    if (context.calendarEvent) {
      prompt += `\nCalendar note: ${context.calendarEvent}\n`;
    }

    if (context.timeOfDay) {
      prompt += `\nTime of day: ${context.timeOfDay}\n`;
    }

    prompt += `\nGenerate the commentary now:`;

    return prompt;
  }

  // Estimate audio duration based on word count
  private estimateAudioDuration(text: string): number {
    const wordsPerMinute = 150; // Average speaking rate
    const wordCount = text.split(/\s+/).length;
    return Math.ceil((wordCount / wordsPerMinute) * 60);
  }

  // Fallback when LLM fails
  private generateFallbackCommentary(context: CommentaryContext): CommentaryResponse {
    const { currentTrack, station, isFirstTrack } = context;

    let text = '';

    if (isFirstTrack) {
      text = `Welcome to ${station.name}! Up first, we've got "${currentTrack.title}" by ${currentTrack.artist}. Let's go.`;
    } else {
      text = `You're listening to "${currentTrack.title}" by ${currentTrack.artist} on ${station.name}.`;
    }

    return {
      text,
      audioDuration: this.estimateAudioDuration(text),
    };
  }

  // Generate a playlist introduction
  async generateStationIntro(stationName: string, genres: string[]): Promise<string> {
    const prompt = `Create a short, engaging radio intro for a station called "${stationName}" that plays ${genres.join(', ')}. Keep it under 50 words. Make it feel like a real radio DJ opening.`;

    // Skip gateway in serverless environments
    if (this.gatewayUrl.startsWith('http://127.0.0.1') || this.gatewayUrl.startsWith('http://localhost')) {
      const isServerless = process.env.VERCEL || process.env.AWS_LAMBDA_FUNCTION_NAME;
      if (isServerless) {
        return `Welcome to ${stationName}! Let's get into the vibe.`;
      }
    }

    try {
      const response = await fetch(`${this.gatewayUrl}/v1/chat/completions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: 'minimax/MiniMax-M2.1',
          messages: [{ role: 'user', content: prompt }],
          max_tokens: 200,
          temperature: 0.8,
        }),
      });

      const data = await response.json();
      return data.choices?.[0]?.message?.content || `Welcome to ${stationName}!`;
    } catch {
      return `Welcome to ${stationName}! Let's get into the vibe.`;
    }
  }
}

// Factory function
export function createCommentaryGenerator(gatewayUrl?: string): CommentaryGenerator {
  return new CommentaryGenerator(gatewayUrl);
}

// Pre-built templates for different scenarios
export const COMMENTARY_TEMPLATES = {
  trackIntro: (track: TrackInfo) =>
    `Up next, we've got "${track.title}" by ${track.artist}.`,

  artistShoutout: (artist: string, station: string) =>
    `Big shoutout to all the ${artist} fans out there tuning into ${station}!`,

  transition: (from: TrackInfo, to: TrackInfo) =>
    `That was "${from.title}" by ${from.artist}. Coming up next, "${to.title}" by ${to.artist}.`,

  weather: (weather: string, station: string) =>
    `It's ${weather} outside on ${station}.`,

  calendar: (event: string) =>
    `Heads up - you've got ${event} coming up.`,
};
