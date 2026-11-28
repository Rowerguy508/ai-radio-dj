import { NextResponse } from 'next/server';

// No session auth exists yet. These handlers stay closed and never
// construct a database client, regardless of any caller-supplied user id.
function notFound() {
  return NextResponse.json({ error: 'Not found' }, { status: 404 });
}

export function GET() {
  return notFound();
}

export function POST() {
  return notFound();
}

export function PATCH() {
  return notFound();
}
