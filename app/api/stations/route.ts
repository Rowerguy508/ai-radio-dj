import { NextRequest, NextResponse } from 'next/server';
import { authorizeRequest } from '@/lib/auth/api';

const ALLOWED_STYLES = new Set(['chill', 'balanced', 'hype']);

// GET - Fetch user's stations
export async function GET(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const auth = await authorizeRequest(request, requestId);
    if (auth.errorResponse) return auth.errorResponse;

    const { searchParams } = new URL(request.url);
    const userId = searchParams.get('userId');

    if (!userId) {
      return NextResponse.json({ stations: [], requestId });
    }

    // Return empty if Supabase not configured
    if (!process.env.NEXT_PUBLIC_SUPABASE_URL) {
      return NextResponse.json({ stations: [], requestId });
    }

    try {
      const { createAdminClient } = await import('@/lib/database/supabase');
      const supabase = createAdminClient();
      
      if (!supabase) {
        return NextResponse.json({ stations: [], requestId });
      }

      const { data: stations, error } = await (supabase as any)
        .from('stations')
        .select('*')
        .eq('user_id', userId)
        .eq('is_active', true)
        .order('created_at', { ascending: false });

      if (error) throw error;
      return NextResponse.json({ stations: stations || [], requestId });
    } catch {
      // Supabase not configured, return empty
      console.warn('Supabase not configured, returning empty stations', { requestId });
      return NextResponse.json({ stations: [], requestId });
    }
  } catch (error) {
    console.error('Fetch stations error:', { requestId, error });
    return NextResponse.json({ stations: [], requestId });
  }
}

// POST - Create a new station
export async function POST(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const auth = await authorizeRequest(request, requestId);
    if (auth.errorResponse) return auth.errorResponse;

    const body = await request.json() as Record<string, unknown>;

    const name = typeof body.name === 'string' ? body.name.trim() : '';
    const style = typeof body.style === 'string' ? body.style : 'balanced';
    const energyLevel = typeof body.energyLevel === 'number' ? body.energyLevel : 0.5;

    if (!name || name.length > 100) {
      return NextResponse.json({ error: 'Station name must be 1-100 characters', requestId }, { status: 400 });
    }

    if (!ALLOWED_STYLES.has(style)) {
      return NextResponse.json({ error: 'Station style is invalid', requestId }, { status: 400 });
    }

    if (!Number.isFinite(energyLevel) || energyLevel < 0 || energyLevel > 1) {
      return NextResponse.json({ error: 'Energy level must be between 0 and 1', requestId }, { status: 400 });
    }
    
    // Return success without Supabase (local-first mode)
    console.log('Station created (local mode):', name);
    return NextResponse.json({ 
      station: { ...body, id: body.id || `station-${Date.now()}` },
      local: true,
      requestId,
    });
  } catch (error) {
    console.error('Create station error:', { requestId, error });
    return NextResponse.json({ error: 'Failed to create station', requestId }, { status: 500 });
  }
}

// Sync endpoint - batch sync stations
export async function PUT(request: NextRequest) {
  const requestId = crypto.randomUUID();
  try {
    const body = await request.json();
    console.log('Sync stations (local mode):', body.stations?.length, 'stations');
    return NextResponse.json({ success: true, local: true, requestId });
  } catch (error) {
    console.error('Sync error:', { requestId, error });
    return NextResponse.json({ error: 'Failed to sync', requestId }, { status: 500 });
  }
}
