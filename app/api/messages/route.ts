import { NextRequest, NextResponse } from 'next/server';

const ALLOWED_SOURCES = new Set(['telegram', 'telegram-callback', 'manual', 'calendar']);

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
    const { userId, source, content, priority = 0 } = body as {
      userId?: string;
      source?: string;
      content?: string;
      priority?: number;
    };

    if (!userId || typeof userId !== 'string') {
      return NextResponse.json(
        { error: 'User ID is required', requestId },
        { status: 400 }
      );
    }

    if (!content || typeof content !== 'string') {
      return NextResponse.json(
        { error: 'Content is required', requestId },
        { status: 400 }
      );
    }

    const trimmedContent = content.trim();
    if (trimmedContent.length === 0 || trimmedContent.length > 1000) {
      return NextResponse.json(
        { error: 'Content must be between 1 and 1000 characters', requestId },
        { status: 400 }
      );
    }

    const normalizedSource = source || 'telegram';
    if (!ALLOWED_SOURCES.has(normalizedSource)) {
      return NextResponse.json(
        { error: 'Invalid message source', requestId },
        { status: 400 }
      );
    }

    const normalizedPriority = Number.isFinite(priority)
      ? Math.min(Math.max(Number(priority), -10), 10)
      : 0;

    if (!Number.isFinite(normalizedPriority)) {
      return NextResponse.json(
        { error: 'Priority must be a number', requestId },
        { status: 400 }
      );
    }

    // Return success without Supabase
    if (!process.env.NEXT_PUBLIC_SUPABASE_URL) {
      return NextResponse.json({ message: { id: `local-${Date.now()}`, content: trimmedContent }, local: true, requestId });
    }

    const { createAdminClient } = await import('@/lib/database/supabase');
    const supabase = createAdminClient();
    
    if (!supabase) {
      return NextResponse.json({ message: { id: `local-${Date.now()}`, content: trimmedContent }, local: true, requestId });
    }

    const { data: message, error } = await (supabase as any)
      .from('message_queue')
      .insert({
        user_id: userId,
        source: normalizedSource,
        content: trimmedContent,
        priority: normalizedPriority,
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
    const { messageId, action, value = true } = body as {
      messageId?: string;
      action?: 'read' | 'dismiss';
      value?: boolean;
    };

    if (!messageId || !action) {
      return NextResponse.json(
        { error: 'Message ID and action required', requestId },
        { status: 400 }
      );
    }

    if (action !== 'read' && action !== 'dismiss') {
      return NextResponse.json(
        { error: 'Invalid action. Use "read" or "dismiss"', requestId },
        { status: 400 }
      );
    }

    if (action === 'dismiss' && typeof value !== 'boolean') {
      return NextResponse.json(
        { error: 'Dismiss value must be boolean', requestId },
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
