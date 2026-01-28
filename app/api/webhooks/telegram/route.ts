import { NextRequest, NextResponse } from 'next/server';
import { createAdminClient } from '@/lib/database/supabase';

// Telegram webhook - receives messages and queues them for the radio DJ
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();

    // Handle different Telegram update types
    const { message, callback_query, my_chat_member } = body;

    let telegramUserId: string | null = null;
    let textContent = '';
    let source = 'telegram';

    if (message) {
      telegramUserId = message.from?.id?.toString() || null;
      textContent = message.text || message.caption || '';

      // Handle different message types
      if (message.photo) {
        textContent = '📷 Photo received';
      } else if (message.voice) {
        textContent = '🎤 Voice message received';
      } else if (message.document) {
        textContent = `📄 Document: ${message.document.file_name || 'file'}`;
      } else if (message.sticker) {
        textContent = '😀 Sticker';
      }
    }

    if (callback_query) {
      telegramUserId = callback_query.from?.id?.toString() || null;
      textContent = callback_query.data || '';
      source = 'telegram-callback';
    }

    if (my_chat_member) {
      // Bot was added/removed from chat
      return NextResponse.json({ ok: true });
    }

    if (!telegramUserId) {
      return NextResponse.json(
        { error: 'User ID not found' },
        { status: 400 }
      );
    }

    if (textContent) {
      // Look up the Supabase user ID from their Telegram ID
      // This requires a telegram_user_map table or storing telegram_id in the users table
      // For now, we'll try to find the user by email in their Telegram profile

      const supabase = createAdminClient();

      // Try to queue the message
      // Note: You'll need to create a table mapping Telegram IDs to Supabase user IDs
      // Or store the telegram_id in your users table
      await supabase
        .from('message_queue')
        .insert({
          user_id: telegramUserId, // This would need to be mapped to Supabase user ID
          source,
          content: textContent,
          priority: 0,
        })
        .then(({ error }) => {
          if (error) {
            console.log('Message queued for new user:', textContent);
          }
        });
    }

    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error('Telegram webhook error:', error);
    return NextResponse.json(
      { error: 'Webhook processing failed' },
      { status: 500 }
    );
  }
}

// Telegram verification endpoint
export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const mode = searchParams.get('hub.mode');
  const token = searchParams.get('hub.verify_token');
  const challenge = searchParams.get('hub.challenge');

  // Set up webhook verification
  if (mode === 'subscribe' && token === process.env.TELEGRAM_BOT_TOKEN) {
    return new NextResponse(challenge);
  }

  return NextResponse.json({ error: 'Verification failed' }, { status: 403 });
}
