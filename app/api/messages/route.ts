import { NextRequest, NextResponse } from 'next/server';

// GET - Fetch pending messages
export async function GET(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const { searchParams } = new URL(request.url);
    const userId = searchParams.get('userId');
    const limitRaw = parseInt(searchParams.get('limit') || '10', 10);
    const limit = Number.isFinite(limitRaw) ? Math.min(Math.max(limitRaw, 1), 100) : 10;

    if (!userId) {
      return NextResponse.json(
        { error: 'User ID required', requestId },
        { status: 400 }
      );
    }

    // Return empty if Supabase not configured
    if (!process.env.NEXT_PUBLIC_SUPABASE_URL) {
      return NextResponse.json({ messages: [], requestId });
    }

    const { createAdminClient } = await import('@/lib/database/supabase');
    const supabase = createAdminClient();
    
    if (!supabase) {
      return NextResponse.json({ messages: [], requestId });
    }

    const { data: messages, error } = await (supabase as any)
      .from('message_queue')
      .select('*')
      .eq('user_id', userId)
      .is('read_at', null)
      .eq('dismissed', false)
      .order('priority', { ascending: false })
      .limit(limit);

    if (error) throw error;

    return NextResponse.json({ messages, requestId });
  } catch (error) {
    console.error('Fetch messages error:', { requestId, error });
    return NextResponse.json(
      { error: 'Failed to fetch messages', requestId },
      { status: 500 }
    );
  }
}

// POST - Add a new message
export async function POST(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const body = await request.json();
    const { userId, source, content, priority = 0 } = body;

    if (!userId || !content) {
      return NextResponse.json(
        { error: 'User ID and content required', requestId },
        { status: 400 }
      );
    }

    // Return success without Supabase
    if (!process.env.NEXT_PUBLIC_SUPABASE_URL) {
      return NextResponse.json({ message: { id: `local-${Date.now()}`, content }, local: true, requestId });
    }

    const { createAdminClient } = await import('@/lib/database/supabase');
    const supabase = createAdminClient();
    
    if (!supabase) {
      return NextResponse.json({ message: { id: `local-${Date.now()}`, content }, local: true, requestId });
    }

    const { data: message, error } = await (supabase as any)
      .from('message_queue')
      .insert({
        user_id: userId,
        source: source || 'telegram',
        content,
        priority,
      })
      .select()
      .single();

    if (error) throw error;

    return NextResponse.json({ message, requestId });
  } catch (error) {
    console.error('Add message error:', { requestId, error });
    return NextResponse.json(
      { error: 'Failed to add message', requestId },
      { status: 500 }
    );
  }
}

// PATCH - Mark message as read/dismissed
export async function PATCH(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const body = await request.json();
    const { messageId, action, value = true } = body;

    if (!messageId || !action) {
      return NextResponse.json(
        { error: 'Message ID and action required', requestId },
        { status: 400 }
      );
    }

    const updateData: Record<string, any> = {};
    if (action === 'read') updateData.read_at = new Date().toISOString();
    if (action === 'dismiss') updateData.dismissed = value;

    // Return success without Supabase
    if (!process.env.NEXT_PUBLIC_SUPABASE_URL) {
      return NextResponse.json({ success: true, local: true, requestId });
    }

    const { createAdminClient } = await import('@/lib/database/supabase');
    const supabase = createAdminClient();
    
    if (!supabase) {
      return NextResponse.json({ success: true, local: true, requestId });
    }

    const { data: message, error } = await (supabase as any)
      .from('message_queue')
      .update(updateData)
      .eq('id', messageId)
      .select()
      .single();

    if (error) throw error;

    return NextResponse.json({ message, requestId });
  } catch (error) {
    console.error('Update message error:', { requestId, error });
    return NextResponse.json(
      { error: 'Failed to update message', requestId },
      { status: 500 }
    );
  }
}
