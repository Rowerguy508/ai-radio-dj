import { NextRequest, NextResponse } from 'next/server';
import { createAdminClient } from '@/lib/database/supabase';

// GET - Fetch user's stations
export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const userId = searchParams.get('userId');

    if (!userId) {
      return NextResponse.json({ stations: [] });
    }

    // Try Supabase, but return empty array if not configured
    try {
      const supabase = createAdminClient();
      const { data: stations, error } = await supabase
        .from('stations')
        .select('*')
        .eq('user_id', userId)
        .eq('is_active', true)
        .order('created_at', { ascending: false });

      if (error) throw error;
      return NextResponse.json({ stations: stations || [] });
    } catch (supabaseError) {
      // Supabase not configured, return empty
      console.warn('Supabase not configured, returning empty stations');
      return NextResponse.json({ stations: [] });
    }
  } catch (error) {
    console.error('Fetch stations error:', error);
    return NextResponse.json({ stations: [] });
  }
}

// POST - Create a new station
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    
    // Return success without Supabase (local-first mode)
    console.log('Station created (local mode):', body.name);
    return NextResponse.json({ 
      station: { ...body, id: body.id || `station-${Date.now()}` },
      local: true 
    });
  } catch (error) {
    console.error('Create station error:', error);
    return NextResponse.json({ error: 'Failed to create station' }, { status: 500 });
  }
}

// Sync endpoint - batch sync stations
export async function PUT(request: NextRequest) {
  try {
    const body = await request.json();
    console.log('Sync stations (local mode):', body.stations?.length, 'stations');
    return NextResponse.json({ success: true, local: true });
  } catch (error) {
    console.error('Sync error:', error);
    return NextResponse.json({ error: 'Failed to sync' }, { status: 500 });
  }
}
