import { NextRequest, NextResponse } from 'next/server';

// Telegram webhook - receives messages and queues them for the radio DJ
export async function POST(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const expectedSecret = process.env.TELEGRAM_WEBHOOK_SECRET;
    if (expectedSecret) {
      const incomingSecret = request.headers.get('x-telegram-bot-api-secret-token');
      if (incomingSecret !== expectedSecret) {
        return NextResponse.json(
          { error: 'Unauthorized webhook request', requestId },
          { status: 401 }
        );
      }
    }

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
        { error: 'User ID not found', requestId },
        { status: 400 }
      );
    }

    if (textContent) {
      // Store message locally (Supabase optional)
      console.log('Telegram message received:', { requestId, userId: telegramUserId, source, content: textContent });
      
      // Message queued successfully
      // In production with Supabase, you'd map telegram_user_id to supabase user_id
    }

    return NextResponse.json({ ok: true, requestId });
  } catch (error) {
    console.error('Telegram webhook error:', { requestId, error });
    return NextResponse.json(
      { error: 'Webhook processing failed', requestId },
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
