'use client';

import { createContext, useContext, useEffect, useState, ReactNode, useCallback } from 'react';
import { useRadioStore, Track } from '@/lib/store/radio';

interface SpotifyUser {
  id: string;
  display_name: string;
  email: string;
  images: { url: string }[];
  product: string;
}

interface SpotifyTrack {
  id: string;
  name: string;
  artists: { name: string }[];
  album: {
    name: string;
    images: { url: string }[];
  };
  duration_ms: number;
  preview_url: string | null;
  uri: string;
}

interface SpotifyPlaylist {
  id: string;
  name: string;
  description: string | null;
  images: { url: string }[];
  tracks: { total: number };
}

interface SpotifyContextType {
  user: SpotifyUser | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  isPremium: boolean;
  playlists: SpotifyPlaylist[];
  connectSpotify: () => void;
  disconnect: () => void;
  createRadioStation: (mood: 'chill' | 'hype' | 'balanced') => Promise<void>;
  searchTracks: (query: string) => Promise<SpotifyTrack[]>;
  getRecommendations: (seedTracks: string[], energy: number) => Promise<SpotifyTrack[]>;
}

const SpotifyContext = createContext<SpotifyContextType | null>(null);

// Genre mappings for different moods
const MOOD_GENRES: Record<'chill' | 'hype' | 'balanced', string[]> = {
  chill: ['chill', 'ambient', 'acoustic', 'jazz', 'classical'],
  hype: ['hip-hop', 'electronic', 'rock', 'pop', 'dance'],
  balanced: ['indie', 'pop', 'alternative', 'r-n-b', 'soul'],
};

const MOOD_ENERGY: Record<'chill' | 'hype' | 'balanced', number> = {
  chill: 0.3,
  hype: 0.8,
  balanced: 0.5,
};

export function SpotifyProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<SpotifyUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<SpotifyPlaylist[]>([]);
  const [accessToken, setAccessToken] = useState<string | null>(null);
  const [tokenExpiry, setTokenExpiry] = useState<number>(0);

  // Check for token in URL or localStorage on mount
  useEffect(() => {
    // Check URL params first (from OAuth callback)
    const urlParams = new URLSearchParams(window.location.search);
    const urlToken = urlParams.get('spotify_token');
    const urlExpires = urlParams.get('spotify_expires');

    if (urlToken) {
      setAccessToken(urlToken);
      if (urlExpires) {
        setTokenExpiry(Date.now() + parseInt(urlExpires) * 1000);
      }
      localStorage.setItem('spotify_access_token', urlToken);
      if (urlExpires) {
        localStorage.setItem('spotify_token_expiry', (Date.now() + parseInt(urlExpires) * 1000).toString());
      }
      // Clean URL
      window.history.replaceState({}, '', window.location.pathname);
    } else {
      // Check localStorage
      const storedToken = localStorage.getItem('spotify_access_token');
      const storedExpiry = localStorage.getItem('spotify_token_expiry');
      if (storedToken && storedExpiry && parseInt(storedExpiry) > Date.now()) {
        setAccessToken(storedToken);
        setTokenExpiry(parseInt(storedExpiry));
      }
    }
  }, []);

  // Fetch user data when token is available
  useEffect(() => {
    if (accessToken) {
      fetchUserData();
      fetchPlaylists();
    }
  }, [accessToken]);

  const fetchUserData = async () => {
    if (!accessToken) return;
    
    try {
      setIsLoading(true);
      const response = await fetch('https://api.spotify.com/v1/me', {
        headers: { Authorization: `Bearer ${accessToken}` },
      });

      if (!response.ok) {
        throw new Error('Failed to fetch user data');
      }

      const userData = await response.json();
      setUser(userData);
    } catch (error) {
      console.error('Error fetching Spotify user:', error);
      // Token might be invalid, clear it
      disconnect();
    } finally {
      setIsLoading(false);
    }
  };

  const fetchPlaylists = async () => {
    if (!accessToken) return;

    try {
      const response = await fetch('https://api.spotify.com/v1/me/playlists?limit=50', {
        headers: { Authorization: `Bearer ${accessToken}` },
      });

      if (!response.ok) return;

      const data = await response.json();
      setPlaylists(data.items || []);
    } catch (error) {
      console.error('Error fetching playlists:', error);
    }
  };

  const connectSpotify = useCallback(() => {
    const clientId = process.env.NEXT_PUBLIC_SPOTIFY_CLIENT_ID;
    const redirectUri = `${window.location.origin}/api/spotify/callback`;
    const scopes = [
      'user-read-private',
      'user-read-email',
      'user-library-read',
      'playlist-read-private',
      'playlist-read-collaborative',
      'streaming',
      'user-read-playback-state',
      'user-modify-playback-state',
      'user-read-currently-playing',
    ].join(' ');

    const params = new URLSearchParams({
      client_id: clientId || '',
      response_type: 'token',
      redirect_uri: redirectUri,
      scope: scopes,
      show_dialog: 'true',
    });

    window.location.href = `https://accounts.spotify.com/authorize?${params.toString()}`;
  }, []);

  const disconnect = useCallback(() => {
    setUser(null);
    setAccessToken(null);
    setTokenExpiry(0);
    setPlaylists([]);
    localStorage.removeItem('spotify_access_token');
    localStorage.removeItem('spotify_token_expiry');
  }, []);

  const searchTracks = useCallback(async (query: string): Promise<SpotifyTrack[]> => {
    if (!accessToken) return [];

    try {
      const response = await fetch(
        `https://api.spotify.com/v1/search?q=${encodeURIComponent(query)}&type=track&limit=20`,
        { headers: { Authorization: `Bearer ${accessToken}` } }
      );

      if (!response.ok) return [];

      const data = await response.json();
      return data.tracks?.items || [];
    } catch (error) {
      console.error('Search error:', error);
      return [];
    }
  }, [accessToken]);

  const getRecommendations = useCallback(async (
    seedTracks: string[],
    energy: number
  ): Promise<SpotifyTrack[]> => {
    if (!accessToken) return [];

    try {
      const params = new URLSearchParams({
        seed_tracks: seedTracks.slice(0, 5).join(','),
        target_energy: energy.toString(),
        limit: '20',
      });

      const response = await fetch(
        `https://api.spotify.com/v1/recommendations?${params.toString()}`,
        { headers: { Authorization: `Bearer ${accessToken}` } }
      );

      if (!response.ok) return [];

      const data = await response.json();
      return data.tracks || [];
    } catch (error) {
      console.error('Recommendations error:', error);
      return [];
    }
  }, [accessToken]);

  const createRadioStation = useCallback(async (mood: 'chill' | 'hype' | 'balanced') => {
    if (!accessToken) return;

    setIsLoading(true);
    try {
      const genres = MOOD_GENRES[mood];
      const energy = MOOD_ENERGY[mood];

      // Get recommendations based on genres
      const params = new URLSearchParams({
        seed_genres: genres.slice(0, 5).join(','),
        target_energy: energy.toString(),
        target_valence: mood === 'hype' ? '0.7' : mood === 'chill' ? '0.3' : '0.5',
        limit: '30',
      });

      const response = await fetch(
        `https://api.spotify.com/v1/recommendations?${params.toString()}`,
        { headers: { Authorization: `Bearer ${accessToken}` } }
      );

      if (!response.ok) {
        throw new Error('Failed to get recommendations');
      }

      const data = await response.json();
      const spotifyTracks: SpotifyTrack[] = data.tracks || [];

      // Convert to radio store format
      const tracks: Track[] = spotifyTracks
        .filter((t: SpotifyTrack) => t.preview_url) // Only include tracks with previews
        .map((t: SpotifyTrack) => ({
          id: t.id,
          title: t.name,
          artistName: t.artists.map(a => a.name).join(', '),
          albumName: t.album.name,
          artworkUrl: t.album.images[0]?.url,
          duration: Math.floor(t.duration_ms / 1000),
          previewUrl: t.preview_url || undefined,
          spotifyUri: t.uri,
        }));

      if (tracks.length > 0) {
        setQueue(tracks);
        setCurrentTrack(tracks[0]);
        setIsPlaying(true);
      }
    } catch (error) {
      console.error('Error creating radio station:', error);
    } finally {
      setIsLoading(false);
    }
  }, [accessToken, setQueue, setCurrentTrack, setIsPlaying]);

  const contextValue: SpotifyContextType = {
    user,
    isAuthenticated: !!accessToken && !!user,
    isLoading,
    isPremium: user?.product === 'premium',
    playlists,
    connectSpotify,
    disconnect,
    createRadioStation,
    searchTracks,
    getRecommendations,
  };

  return (
    <SpotifyContext.Provider value={contextValue}>
      {children}
    </SpotifyContext.Provider>
  );
}

export function useSpotify() {
  const context = useContext(SpotifyContext);
  if (!context) {
    throw new Error('useSpotify must be used within a SpotifyProvider');
  }
  return context;
}
