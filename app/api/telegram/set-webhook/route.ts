import { NextRequest, NextResponse } from 'next/server';

// Set Telegram webhook
// Run: npx ngrok http 3000 (get URL)
// Then call this endpoint with your webhook URL

export async function POST(req: NextRequest) {
  try {
    const { webhookUrl, botToken } = await req.json();
    const envBotToken = process.env.TELEGRAM_BOT_TOKEN;
    const webhookSecret = process.env.TELEGRAM_WEBHOOK_SECRET;
    const isProd = process.env.NODE_ENV === 'production';
    const requestId = crypto.randomUUID();

    if (!webhookUrl) {
      return NextResponse.json({ 
        error: 'Missing webhookUrl',
        requestId,
      }, { status: 400 });
    }

    // In production, never accept bot token from request body.
    // In non-production, allow body token for local/dev setup convenience.
    const tokenToUse = envBotToken || (!isProd ? botToken : undefined);
    if (!tokenToUse) {
      return NextResponse.json({
        error: 'Telegram bot token is not configured',
        requestId,
      }, { status: 400 });
    }
    
    const response = await fetch(
      `https://api.telegram.org/bot${tokenToUse}/setWebhook`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          url: `${webhookUrl}/api/telegram`,
          ...(webhookSecret ? { secret_token: webhookSecret } : {}),
        }),
      }
    );
    
    const result = await response.json();
    
    return NextResponse.json({ ...result, requestId });
    
  } catch (error) {
    const requestId = crypto.randomUUID();
    console.error('set-webhook error', { requestId, error });
    return NextResponse.json({ error: 'Failed to set webhook', requestId }, { status: 500 });
  }
}
