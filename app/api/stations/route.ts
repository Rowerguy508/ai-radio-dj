import { NextRequest, NextResponse } from 'next/server';
import { createAdminClient } from '@/lib/database/supabase';

// GET - Fetch user's stations
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
    const { data: stations, error } = await supabase
      .from('stations')
      .select('*')
      .eq('user_id', userId)
      .eq('is_active', true)
      .order('created_at', { ascending: false });

    if (error) throw error;

    return NextResponse.json({ stations });
  } catch (error) {
    console.error('Fetch stations error:', error);
    return NextResponse.json(
      { error: 'Failed to fetch stations' },
      { status: 500 }
    );
  }
}

// POST - Create a new station
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const {
      userId,
      name,
      description,
      energyLevel,
      style,
      voiceId,
      musicGenres,
      includeMessages,
      includeCalendar,
      includeNews,
    } = body;

    if (!userId || !name) {
      return NextResponse.json(
        { error: 'User ID and name required' },
        { status: 400 }
      );
    }

    const supabase = createAdminClient();
    const { data: station, error } = await supabase
      .from('stations')
      .insert({
        user_id: userId,
        name,
        description,
        energy_level: energyLevel ?? 0.5,
        style: style ?? 'balanced',
        voice_id: voiceId,
        music_genres: musicGenres ?? [],
        include_messages: includeMessages ?? true,
        include_calendar: includeCalendar ?? false,
        include_news: includeNews ?? true,
        is_active: true,
      })
      .select()
      .single();

    if (error) throw error;

    return NextResponse.json({ station });
  } catch (error) {
    console.error('Create station error:', error);
    return NextResponse.json(
      { error: 'Failed to create station' },
      { status: 500 }
    );
  }
}

// PATCH - Update a station
export async function PATCH(request: NextRequest) {
  try {
    const body = await request.json();
    const { id, userId, ...updates } = body;

    if (!id) {
      return NextResponse.json(
        { error: 'Station ID required' },
        { status: 400 }
      );
    }

    // Map camelCase to snake_case
    const snakeUpdates: Record<string, any> = {};
    Object.entries(updates).forEach(([key, value]) => {
      const snakeKey = key.replace(/([A-Z])/g, '_$1').toLowerCase();
      snakeUpdates[snakeKey] = value;
    });

    const supabase = createAdminClient();
    const { data: station, error } = await supabase
      .from('stations')
      .update(snakeUpdates)
      .eq('id', id)
      .select()
      .single();

    if (error) throw error;

    return NextResponse.json({ station });
  } catch (error) {
    console.error('Update station error:', error);
    return NextResponse.json(
      { error: 'Failed to update station' },
      { status: 500 }
    );
  }
}

// DELETE - Remove a station (soft delete)
export async function DELETE(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const id = searchParams.get('id');

    if (!id) {
      return NextResponse.json(
        { error: 'Station ID required' },
        { status: 400 }
      );
    }

    const supabase = createAdminClient();
    const { error } = await supabase
      .from('stations')
      .update({ is_active: false })
      .eq('id', id);

    if (error) throw error;

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Delete station error:', error);
    return NextResponse.json(
      { error: 'Failed to delete station' },
      { status: 500 }
    );
  }
}
