import { createClient } from '@supabase/supabase-js';

// Cloud-native database access
// All queries go through Supabase API (PostgREST)

// Server-side client with service role (for admin operations)
export function createAdminClient() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    }
  );
}

// Client-side (for browser) - uses anon key with RLS
export const createBrowserClient = () => {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );
};

// Database types (for TypeScript)
export type User = {
  id: string;
  email: string;
  name?: string;
  created_at: string;
  updated_at: string;
};

export type Voice = {
  id: string;
  user_id: string;
  name: string;
  voice_id: string;
  style: number;
  language: string;
  personality?: string;
  is_default: boolean;
  created_at: string;
};

export type Station = {
  id: string;
  user_id: string;
  voice_id?: string;
  name: string;
  description?: string;
  energy_level: number;
  style: 'chill' | 'balanced' | 'hype';
  music_genres: string[];
  include_messages: boolean;
  include_calendar: boolean;
  include_news: boolean;
  is_active: boolean;
  created_at: string;
};

export type MessageQueue = {
  id: string;
  user_id: string;
  source: string;
  content: string;
  priority: number;
  read_at?: string;
  dismissed: boolean;
  created_at: string;
};

export type ListeningLog = {
  id: string;
  user_id: string;
  station_id?: string;
  track_id: string;
  track_name: string;
  artist_name: string;
  album_art?: string;
  duration?: number;
  skipped: boolean;
  liked: boolean;
  played_at: string;
};
