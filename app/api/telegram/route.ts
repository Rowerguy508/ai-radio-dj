import { NextRequest, NextResponse } from 'next/server';

// Telegram bot webhook for RAY.DO control
// Token stored in TELEGRAM_BOT_TOKEN env var

interface TelegramUpdate {
  update_id: number;
  message?: {
    chat: { id: number };
    text?: string;
    from?: { first_name: string };
  };
}

export async function POST(req: NextRequest) {
  try {
    const update: TelegramUpdate = await req.json();
    
    // Handle /start command
    if (update.message?.text === '/start') {
      return NextResponse.json({
        method: 'sendMessage',
        chat_id: update.message.chat.id,
        text: `🎵 *RAY.DO - AI Radio DJ* 🎵\n\nYour personal AI-hosted radio station.\n\nCommands:\n/play - Start playing\n/pause - Pause playback\n/next - Skip to next track\n/stop - Stop playing\n/stations - List stations`,
        parse_mode: 'Markdown',
      });
    }
    
    // Handle /play command
    if (update.message?.text === '/play') {
      return NextResponse.json({
        method: 'sendMessage',
        chat_id: update.message.chat.id,
        text: '▶️ RAY.DO is now playing! Check your browser to hear the music.',
      });
    }
    
    // Handle /pause command
    if (update.message?.text === '/pause') {
      return NextResponse.json({
        method: 'sendMessage',
        chat_id: update.message.chat.id,
        text: '⏸️ Playback paused.',
      });
    }
    
    // Handle /next command
    if (update.message?.text === '/next') {
      return NextResponse.json({
        method: 'sendMessage',
        chat_id: update.message.chat.id,
        text: '⏭️ Skipping to next track...',
      });
    }
    
    // Handle /stations command
    if (update.message?.text === '/stations') {
      return NextResponse.json({
        method: 'sendMessage',
        chat_id: update.message.chat.id,
        text: `🎧 *Available Stations:*\n\n🌀 Chill Focus\\- Lo\\-fi & Ambient\\n⚡ Hype Mode\\- Hip\\-hop & Electronic\\n☕ Morning Coffee\\- Pop & Acoustic\\n🎵 Deep Dive\\- Techno & House\n\nOpen the app to select a station!`,
        parse_mode: 'Markdown',
      });
    }
    
    // Default response
    return NextResponse.json({
      method: 'sendMessage',
      chat_id: update.message?.chat.id || 0,
      text: 'RAY.DO: Use /play, /pause, /next, or /stations to control playback.',
    });
    
  } catch (error) {
    return NextResponse.json({ error: 'Invalid request' }, { status: 400 });
  }
}
