import { NextRequest, NextResponse } from 'next/server';
import { createAdminClient } from '@/lib/database/supabase';

// GET - Fetch pending messages
export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const userId = searchParams.get('userId');
    const limit = parseInt(searchParams.get('limit') || '10');

    if (!userId) {
      return NextResponse.json(
        { error: 'User ID required' },
        { status: 400 }
      );
    }

    const supabase = createAdminClient();
    const { data: messages, error } = await supabase
      .from('message_queue')
      .select('*')
      .eq('user_id', userId)
      .is('read_at', null)
      .eq('dismissed', false)
      .order('priority', { ascending: false })
      .limit(limit);

    if (error) throw error;

    return NextResponse.json({ messages });
  } catch (error) {
    console.error('Fetch messages error:', error);
    return NextResponse.json(
      { error: 'Failed to fetch messages' },
      { status: 500 }
    );
  }
}

// POST - Add a new message
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { userId, source, content, priority = 0 } = body;

    if (!userId || !content) {
      return NextResponse.json(
        { error: 'User ID and content required' },
        { status: 400 }
      );
    }

    const supabase = createAdminClient();
    const { data: message, error } = await supabase
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

    return NextResponse.json({ message });
  } catch (error) {
    console.error('Add message error:', error);
    return NextResponse.json(
      { error: 'Failed to add message' },
      { status: 500 }
    );
  }
}

// PATCH - Mark message as read/dismissed
export async function PATCH(request: NextRequest) {
  try {
    const body = await request.json();
    const { messageId, action, value = true } = body;

    if (!messageId || !action) {
      return NextResponse.json(
        { error: 'Message ID and action required' },
        { status: 400 }
      );
    }

    const updateData: Record<string, any> = {};
    if (action === 'read') updateData.read_at = new Date().toISOString();
    if (action === 'dismiss') updateData.dismissed = value;

    const supabase = createAdminClient();
    const { data: message, error } = await supabase
      .from('message_queue')
      .update(updateData)
      .eq('id', messageId)
      .select()
      .single();

    if (error) throw error;

    return NextResponse.json({ message });
  } catch (error) {
    console.error('Update message error:', error);
    return NextResponse.json(
      { error: 'Failed to update message' },
      { status: 500 }
    );
  }
}
