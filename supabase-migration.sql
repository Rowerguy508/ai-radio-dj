-- AI Radio DJ Database Migration
-- Run this in Supabase SQL Editor: https://supabase.com > Your Project > SQL Editor

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Users table (extends Supabase auth.users)
CREATE TABLE IF NOT EXISTS public.users (
  id UUID REFERENCES auth.users(id) PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  name TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Policies for users
CREATE POLICY "Users can view own data" ON public.users
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Users can insert own data" ON public.users
  FOR INSERT WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can update own data" ON public.users
  FOR UPDATE USING (auth.uid() = id);

-- AI Voice personality
CREATE TABLE IF NOT EXISTS public.voices (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  name TEXT NOT NULL,
  voice_id TEXT NOT NULL,
  style FLOAT DEFAULT 0.5,
  language TEXT DEFAULT 'en',
  personality TEXT,
  is_default BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.voices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own voices" ON public.voices
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can manage own voices" ON public.voices
  FOR ALL USING (auth.uid() = user_id);

-- Radio station configuration
CREATE TABLE IF NOT EXISTS public.stations (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  voice_id UUID REFERENCES public.voices(id) ON DELETE SET NULL,

  name TEXT NOT NULL,
  description TEXT,
  energy_level FLOAT DEFAULT 0.5,
  style TEXT CHECK (style IN ('chill', 'balanced', 'hype')),
  voice_id TEXT, -- ElevenLabs voice ID
  music_genres TEXT[] DEFAULT '{}',
  include_messages BOOLEAN DEFAULT TRUE,
  include_calendar BOOLEAN DEFAULT FALSE,
  include_news BOOLEAN DEFAULT TRUE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.stations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own stations" ON public.stations
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can manage own stations" ON public.stations
  FOR ALL USING (auth.uid() = user_id);

-- User preferences
CREATE TABLE IF NOT EXISTS public.user_preferences (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE NOT NULL,
  default_station_id UUID REFERENCES public.stations(id) ON DELETE SET NULL,
  crossfade_duration FLOAT DEFAULT 5.0,
  ducking_level FLOAT DEFAULT 0.3,
  auto_generate_commentary BOOLEAN DEFAULT TRUE,
  max_commentary_length INTEGER DEFAULT 200,
  notify_on_messages BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.user_preferences ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own preferences" ON public.user_preferences
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can manage own preferences" ON public.user_preferences
  FOR ALL USING (auth.uid() = user_id);

-- Listening history
CREATE TABLE IF NOT EXISTS public.listening_logs (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  station_id UUID REFERENCES public.stations(id) ON DELETE SET NULL,

  track_id TEXT NOT NULL,
  track_name TEXT NOT NULL,
  artist_name TEXT NOT NULL,
  album_art TEXT,
  duration INTEGER,
  skipped BOOLEAN DEFAULT FALSE,
  liked BOOLEAN DEFAULT FALSE,
  played_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.listening_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own history" ON public.listening_logs
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own history" ON public.listening_logs
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Message queue for injection into radio
CREATE TABLE IF NOT EXISTS public.message_queue (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  source TEXT NOT NULL, -- 'telegram', 'email', 'calendar'
  content TEXT NOT NULL,
  priority INTEGER DEFAULT 0,
  read_at TIMESTAMPTZ,
  dismissed BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.message_queue ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own messages" ON public.message_queue
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can manage own messages" ON public.message_queue
  FOR ALL USING (auth.uid() = user_id);

-- Calendar events for context
CREATE TABLE IF NOT EXISTS public.calendar_events (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  location TEXT,
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ NOT NULL,
  all_day BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.calendar_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own calendar" ON public.calendar_events
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can manage own calendar" ON public.calendar_events
  FOR ALL USING (auth.uid() = user_id);

-- Function to automatically create user record on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.users (id, email, name)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'name');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger for new user creation
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_stations_user ON public.stations(user_id);
CREATE INDEX IF NOT EXISTS idx_voices_user ON public.voices(user_id);
CREATE INDEX IF NOT EXISTS idx_listening_logs_user ON public.listening_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_messages_user ON public.message_queue(user_id);
CREATE INDEX IF NOT EXISTS idx_messages_unread ON public.message_queue(user_id) WHERE read_at IS NULL AND dismissed = FALSE;

-- Run this after creating tables to set up function calls
COMMENT ON FUNCTION public.handle_new_user IS 'Automatically creates a public.user record when a new auth user signs up';
