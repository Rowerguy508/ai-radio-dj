import { NextRequest, NextResponse } from 'next/server';
import { authorizeRequest } from '@/lib/auth/api';

// GET - Fetch user's voices
export async function GET(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const auth = await authorizeRequest(request, requestId);
    if (auth.errorResponse) return auth.errorResponse;

    const { searchParams } = new URL(request.url);
    const userId = searchParams.get('userId');

    if (!userId) {
      return NextResponse.json(
        { error: 'User ID required', requestId },
        { status: 400 }
      );
    }

    if (auth.userId && auth.userId !== userId) {
      return NextResponse.json({ error: 'Forbidden user scope', requestId }, { status: 403 });
    }

    // Return empty if Supabase not configured
    if (!process.env.NEXT_PUBLIC_SUPABASE_URL) {
      return NextResponse.json({ voices: [], requestId });
    }

    try {
      const { createAdminClient } = await import('@/lib/database/supabase');
      const supabase = createAdminClient();
      
      if (!supabase) {
        return NextResponse.json({ voices: [], requestId });
      }

      const { data: voices, error } = await (supabase as any)
        .from('voices')
        .select('*')
        .eq('user_id', userId)
        .order('created_at', { ascending: false });

      if (error) throw error;

      return NextResponse.json({ voices, requestId });
    } catch {
      return NextResponse.json({ voices: [], requestId });
    }
  } catch (error) {
    console.error('Fetch voices error:', { requestId, error });
    return NextResponse.json(
      { error: 'Failed to fetch voices', requestId },
      { status: 500 }
    );
  }
}

// POST - Create a new voice
export async function POST(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const auth = await authorizeRequest(request, requestId);
    if (auth.errorResponse) return auth.errorResponse;

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
        { error: 'User ID, name, and voiceId required', requestId },
        { status: 400 }
      );
    }

    if (auth.userId && auth.userId !== userId) {
      return NextResponse.json({ error: 'Forbidden user scope', requestId }, { status: 403 });
    }

    // Return success without Supabase
    if (!process.env.NEXT_PUBLIC_SUPABASE_URL) {
      return NextResponse.json({
        voice: {
          id: `local-${Date.now()}`,
          user_id: userId,
          name,
          voice_id: voiceId,
          style: style ?? 0.5,
          language: language ?? 'en',
          personality,
          is_default: isDefault ?? false,
        },
        local: true,
        requestId,
      });
    }

    const { createAdminClient } = await import('@/lib/database/supabase');
    const supabase = createAdminClient();
    
    if (!supabase) {
      return NextResponse.json({
        voice: {
          id: `local-${Date.now()}`,
          user_id: userId,
          name,
          voice_id: voiceId,
          style: style ?? 0.5,
          language: language ?? 'en',
          personality,
          is_default: isDefault ?? false,
        },
        local: true,
        requestId,
      });
    }

    const { data: voice, error } = await (supabase as any)
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

    return NextResponse.json({ voice, requestId });
  } catch (error) {
    console.error('Create voice error:', { requestId, error });
    return NextResponse.json(
      { error: 'Failed to create voice', requestId },
      { status: 500 }
    );
  }
}

// DELETE - Remove a voice
export async function DELETE(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const auth = await authorizeRequest(request, requestId);
    if (auth.errorResponse) return auth.errorResponse;

    const { searchParams } = new URL(request.url);
    const id = searchParams.get('id');
    const userId = searchParams.get('userId');

    if (!id || !userId) {
      return NextResponse.json(
        { error: 'Voice ID and userId required', requestId },
        { status: 400 }
      );
    }

    if (auth.userId && auth.userId !== userId) {
      return NextResponse.json({ error: 'Forbidden user scope', requestId }, { status: 403 });
    }

    // Return success without Supabase
    if (!process.env.NEXT_PUBLIC_SUPABASE_URL) {
      return NextResponse.json({ success: true, local: true, requestId });
    }

    const { createAdminClient } = await import('@/lib/database/supabase');
    const supabase = createAdminClient();
    
    if (!supabase) {
      return NextResponse.json({ success: true, local: true, requestId });
    }

    const { error } = await (supabase as any)
      .from('voices')
      .delete()
      .eq('id', id)
      .eq('user_id', userId);

    if (error) throw error;

    return NextResponse.json({ success: true, requestId });
  } catch (error) {
    console.error('Delete voice error:', { requestId, error });
    return NextResponse.json(
      { error: 'Failed to delete voice', requestId },
      { status: 500 }
    );
  }
}
