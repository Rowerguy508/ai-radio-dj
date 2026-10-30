import { NextRequest, NextResponse } from 'next/server';
import { webhookAuthorized } from '@/lib/telegram/webhook-auth';

// Telegram webhook - receives messages and queues them for the radio DJ
export async function POST(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const expectedSecret = process.env.TELEGRAM_WEBHOOK_SECRET;
    const incomingSecret = request.headers.get('x-telegram-bot-api-secret-token');
    if (!webhookAuthorized(incomingSecret, expectedSecret)) {
      return NextResponse.json(
        { error: 'Unauthorized webhook request', requestId },
        { status: 401 }
      );
    }

    const body = await request.json();
    const { message, callback_query, my_chat_member } = body;

    if (my_chat_member) {
      return NextResponse.json({ ok: true, requestId });
    }

    const telegramUserId = message?.from?.id?.toString()
      || callback_query?.from?.id?.toString()
      || null;

    if (!telegramUserId) {
      return NextResponse.json(
        { error: 'User ID not found', requestId },
        { status: 400 }
      );
    }

    return NextResponse.json({ ok: true, requestId });
  } catch {
    console.error('Telegram webhook error:', { requestId });
    return NextResponse.json(
      { error: 'Webhook processing failed', requestId },
      { status: 500 }
    );
  }
}

