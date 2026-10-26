import { NextResponse } from 'next/server';

// The bot webhook is registered out of band by the owner.
// This route stays so older clients receive a refusal and never call Telegram.
export function POST() {
  return NextResponse.json({ error: 'Not found' }, { status: 404 });
}
