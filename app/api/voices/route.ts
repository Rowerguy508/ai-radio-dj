import { NextRequest, NextResponse } from 'next/server';
import { createAdminClient } from '@/lib/database/supabase';

// GET - Fetch user's voices
export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const userId = searchParams.get('userId');

    if (!userId) {
      return NextResponse.json(
        { error: 'User ID required' },
        { status: 400 }
      );
    }

    const supabase = createAdminClient();
    const { data: voices, error } = await supabase
      .from('voices')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false });

    if (error) throw error;

    return NextResponse.json({ voices });
  } catch (error) {
    console.error('Fetch voices error:', error);
    return NextResponse.json(
      { error: 'Failed to fetch voices' },
      { status: 500 }
    );
  }
}

// POST - Create a new voice
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const {
      userId,
      name,
      voiceId,
      style,
      language,
      personality,
      isDefault,
    } = body;

    if (!userId || !name || !voiceId) {
      return NextResponse.json(
        { error: 'User ID, name, and voiceId required' },
        { status: 400 }
      );
    }

    const supabase = createAdminClient();
    const { data: voice, error } = await supabase
      .from('voices')
      .insert({
        user_id: userId,
        name,
        voice_id: voiceId,
        style: style ?? 0.5,
        language: language ?? 'en',
        personality,
        is_default: isDefault ?? false,
      })
      .select()
      .single();

    if (error) throw error;

    return NextResponse.json({ voice });
  } catch (error) {
    console.error('Create voice error:', error);
    return NextResponse.json(
      { error: 'Failed to create voice' },
      { status: 500 }
    );
  }
}

// DELETE - Remove a voice
export async function DELETE(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const id = searchParams.get('id');

    if (!id) {
      return NextResponse.json(
        { error: 'Voice ID required' },
        { status: 400 }
      );
    }

    const supabase = createAdminClient();
    const { error } = await supabase
      .from('voices')
      .delete()
      .eq('id', id);

    if (error) throw error;

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Delete voice error:', error);
    return NextResponse.json(
      { error: 'Failed to delete voice' },
      { status: 500 }
    );
  }
}
