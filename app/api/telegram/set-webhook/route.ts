import { NextRequest, NextResponse } from 'next/server';

// Set Telegram webhook
// Run: npx ngrok http 3000 (get URL)
// Then call this endpoint with your webhook URL

export async function POST(req: NextRequest) {
  try {
    const { webhookUrl, botToken } = await req.json();
    
    if (!webhookUrl || !botToken) {
      return NextResponse.json({ 
        error: 'Missing webhookUrl or botToken' 
      }, { status: 400 });
    }
    
    const response = await fetch(
      `https://api.telegram.org/bot${botToken}/setWebhook`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          url: `${webhookUrl}/api/telegram`,
        }),
      }
    );
    
    const result = await response.json();
    
    return NextResponse.json(result);
    
  } catch (error) {
    return NextResponse.json({ error: String(error) }, { status: 500 });
  }
}
