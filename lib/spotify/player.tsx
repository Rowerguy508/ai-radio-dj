'use client';

import { createContext, useContext, useEffect, useState, ReactNode } from 'react';

interface SpotifyTrack {
  id: string;
  name: string;
  artists: { name: string }[];
  album: {
    name: string;
    images: { url: string }[];
  };
  preview_url: string | null;
  duration_ms: number;
}

interface SpotifyPlayerContextType {
  isConnected: boolean;
  isPlaying: boolean;
  currentTrack: SpotifyTrack | null;
  connectSpotify: () => void;
  disconnect: () => void;
  play: (trackId?: string) => void;
  pause: () => void;
  next: () => void;
  previous: () => void;
}

const SpotifyPlayerContext = createContext<SpotifyPlayerContextType | null>(null);

export function SpotifyProvider({ children }: { children: ReactNode }) {
  const [isConnected, setIsConnected] = useState(false);
  const [isPlaying, setIsPlaying] = useState(false);
  const [currentTrack, setCurrentTrack] = useState<SpotifyTrack | null>(null);
  const [token, setToken] = useState<string | null>(null);

  // Check for existing session
  useEffect(() => {
    const savedToken = localStorage.getItem('spotify_token');
    const tokenExpiry = localStorage.getItem('spotify_token_expiry');
    
    if (savedToken && tokenExpiry && Date.now() < parseInt(tokenExpiry)) {
      setToken(savedToken);
      setIsConnected(true);
    }
  }, []);

  const connectSpotify = () => {
    const clientId = process.env.NEXT_PUBLIC_SPOTIFY_CLIENT_ID;
    const redirectUri = `${window.location.origin}/api/spotify/callback`;
    const scopes = [
      'streaming',
      'user-read-email',
      'user-read-private',
      'user-read-playback-state',
      'user-modify-playback-state',
      'playlist-read-private',
    ].join(' ');
    
    const authUrl = `https://accounts.spotify.com/authorize?` +
      `client_id=${clientId}&` +
      `response_type=token&` +
      `redirect_uri=${encodeURIComponent(redirectUri)}&` +
      `scope=${encodeURIComponent(scopes)}`;
    
    window.location.href = authUrl;
  };

  const disconnect = () => {
    localStorage.removeItem('spotify_token');
    localStorage.removeItem('spotify_token_expiry');
    setToken(null);
    setIsConnected(false);
    setCurrentTrack(null);
    setIsPlaying(false);
  };

  const play = async (trackId?: string) => {
    if (!token) return;
    
    try {
      // For now, just update state - actual playback requires Spotify SDK
      setIsPlaying(true);
    } catch (e) {
      console.error('Play failed:', e);
    }
  };

  const pause = () => {
    setIsPlaying(false);
  };

  const next = () => {
    // Skip to next track logic
    console.log('Next track');
  };

  const previous = () => {
    // Previous track logic
    console.log('Previous track');
  };

  return (
    <SpotifyPlayerContext.Provider
      value={{
        isConnected,
        isPlaying,
        currentTrack,
        connectSpotify,
        disconnect,
        play,
        pause,
        next,
        previous,
      }}
    >
      {children}
    </SpotifyPlayerContext.Provider>
  );
}

export function useSpotify() {
  const context = useContext(SpotifyPlayerContext);
  if (!context) {
    throw new Error('useSpotify must be used within SpotifyProvider');
  }
  return context;
}
