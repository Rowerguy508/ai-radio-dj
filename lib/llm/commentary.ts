// AI DJ Commentary Generator using MiniMax API

import type { Station, Track } from '@/lib/store/radio';

export interface CommentaryContext {
  station: Station;
  previousTrack?: Track;
  currentTrack?: Track;
  nextTrack?: Track;
  timeOfDay: string;
  type: 'intro' | 'transition' | 'outro' | 'back-from-break';
}

export interface CommentaryResponse {
  text: string;
  ssml: string; // Text with pause markers for natural speech
  estimatedDuration: number;
}

function getTimeOfDay(): string {
  const h = new Date().getHours();
  if (h < 6) return 'late night';
  if (h < 12) return 'morning';
  if (h < 17) return 'afternoon';
  if (h < 21) return 'evening';
  return 'night';
}

export { getTimeOfDay };

export async function generateCommentary(context: CommentaryContext): Promise<CommentaryResponse> {
  const apiKey = process.env.MINIMAX_API_KEY;
  if (!apiKey) return generateFallback(context);

  const system = buildSystemPrompt(context);
  const user = buildUserPrompt(context);

  try {
    const res = await fetch('https://api.minimaxi.chat/v1/text/chatcompletion_v2?GroupId=0', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({
        model: 'MiniMax-Text-01',
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user },
        ],
        max_tokens: 500,
        temperature: 0.85,
      }),
    });

    if (!res.ok) throw new Error(`MiniMax ${res.status}`);
    const data = await res.json();
    const raw = data.choices?.[0]?.message?.content || '';
    const text = raw.replace(/[*"]/g, '').trim();

    return {
      text,
      ssml: addNaturalPauses(text),
      estimatedDuration: estimateDuration(text),
    };
  } catch (e) {
    console.error('Commentary generation failed:', e);
    return generateFallback(context);
  }
}

function buildSystemPrompt(ctx: CommentaryContext): string {
  const { station } = ctx;
  const name = station.djName || 'Ray';

  const styles: Record<string, string> = {
    chill: `You are ${name}, a smooth late-night radio DJ. Your voice is warm, unhurried, almost whispered. You take your time. You let silences breathe. Think: a vinyl bar at midnight. You use short poetic phrases, not full sentences. Mellow, intimate, genuine.`,
    hype: `You are ${name}, a high-energy radio DJ who LIVES for the music. You're animated, punchy, rhythmic in your speech. Think: festival MC meets morning show host. Short exclamations, callbacks to the crowd, infectious excitement. You make every track feel like an event.`,
    balanced: `You are ${name}, a charismatic radio host. Think: the best friend who always has the perfect playlist. Witty, warm, conversational. You tell quick stories, drop fun facts about artists, and keep the energy flowing naturally. Not too hyped, not too sleepy - just right.`,
  };

  const personality = station.djPersonality
    ? `${styles[station.style] || styles.balanced}\n\nAdditional personality notes: ${station.djPersonality}`
    : styles[station.style] || styles.balanced;

  return `${personality}

You are the DJ for "${station.name}".
${station.description ? `Station description: ${station.description}` : ''}
${station.searchQuery ? `This station plays: ${station.searchQuery}` : ''}

CRITICAL RULES:
- Output ONLY the spoken words. No stage directions, no asterisks, no quotes, no parentheses.
- Write in a spoken cadence. Use "..." for intentional pauses. Use short sentences. Vary rhythm.
- Never say "I'm an AI" or break character. You ARE a radio DJ.
- Keep it concise. Say more with less.
- Energy: ${station.energyLevel < 0.3 ? 'very mellow, almost meditative' : station.energyLevel < 0.7 ? 'conversational, easy-going' : 'high energy, pumped up'}`;
}

function buildUserPrompt(ctx: CommentaryContext): string {
  const { type, station, currentTrack, previousTrack, nextTrack, timeOfDay } = ctx;

  switch (type) {
    case 'intro':
      return `Generate a station opening. This is the very first thing the listener hears when they tune in.

Station: "${station.name}"
${station.searchQuery ? `Music style: ${station.searchQuery}` : ''}
Time: ${timeOfDay}
${nextTrack ? `First song coming up: "${nextTrack.title}" by ${nextTrack.artistName}` : ''}

Set the mood, welcome the listener, tease what's coming. Make them feel like they just found their perfect station. 3-5 sentences. Use "..." for pauses.`;

    case 'transition':
      return `Generate a track transition.

${previousTrack ? `Just played: "${previousTrack.title}" by ${previousTrack.artistName}` : ''}
${currentTrack ? `Now playing: "${currentTrack.title}" by ${currentTrack.artistName}` : ''}
${nextTrack ? `Coming up: "${nextTrack.title}" by ${nextTrack.artistName}` : ''}
Time: ${timeOfDay}

Quick transition - 1-3 sentences. Acknowledge what just played and introduce what's next. Use "..." for pauses.`;

    case 'outro':
      return `Generate a brief sign-off. The station is stopping.
Station: "${station.name}"
Time: ${timeOfDay}
1-2 sentences. Thank the listener, keep it warm.`;

    case 'back-from-break':
      return `Welcome the listener back. Short re-intro.
Station: "${station.name}"
${currentTrack ? `Now playing: "${currentTrack.title}" by ${currentTrack.artistName}` : ''}
Time: ${timeOfDay}
1-2 sentences.`;

    default:
      return 'Generate a short DJ comment.';
  }
}

// Add natural speech pauses using "..." markers
function addNaturalPauses(text: string): string {
  // The text already has "..." from the LLM prompt. Normalize them.
  let ssml = text
    .replace(/\.{3,}/g, ' ... ')     // normalize ellipses
    .replace(/\.\s+/g, '. ... ')      // add breath after sentences
    .replace(/!\s+/g, '! ... ')       // add breath after exclamations
    .replace(/\?\s+/g, '? ... ')      // add breath after questions
    .replace(/,\s+/g, ', ')           // slight pause at commas (natural)
    .replace(/\s{2,}/g, ' ')          // clean up double spaces
    .trim();

  return ssml;
}

function estimateDuration(text: string): number {
  const words = text.split(/\s+/).length;
  const pauses = (text.match(/\.\.\./g) || []).length;
  return Math.ceil((words / 150) * 60) + pauses; // ~150 wpm + 1s per pause
}

function generateFallback(ctx: CommentaryContext): CommentaryResponse {
  const { type, station, currentTrack, nextTrack } = ctx;
  let text: string;

  switch (type) {
    case 'intro':
      text = `Hey... welcome to ${station.name}. ... I'm ${station.djName || 'Ray'}, and I'll be keeping you company. ... ${nextTrack ? `Let's kick things off with ${nextTrack.artistName}.` : `Let's get into it.`} ... Here we go.`;
      break;
    case 'transition':
      text = currentTrack
        ? `... That's "${currentTrack.title}" by ${currentTrack.artistName}. ... Nice. ... ${nextTrack ? `Coming up... ${nextTrack.artistName}.` : 'More music coming your way.'}`
        : `More good music coming your way on ${station.name}. ...`;
      break;
    default:
      text = `You're listening to ${station.name}. ...`;
  }

  return { text, ssml: text, estimatedDuration: estimateDuration(text) };
}
