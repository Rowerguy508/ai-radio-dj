'use client';

import { createContext, useContext, useEffect, useState, ReactNode } from 'react';
import { useRadioStore } from '@/lib/store/radio';

interface SpotifyUser {
  id: string;
  email: string;
  display_name: string;
  images?: { url: string }[];
}

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
  uri: string;
}

interface SpotifyPlaylist {
  id: string;
  name: string;
  description: string;
  images: { url: string }[];
  tracks: {
    total: number;
    items: { track: SpotifyTrack }[];
  };
}

interface SpotifyContextType {
  user: SpotifyUser | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  playlists: SpotifyPlaylist[];
  connectSpotify: () => void;
  disconnect: () => void;
  getPlaylistTracks: (playlistId: string) => Promise<SpotifyTrack[]>;
  createRadioStation: (mood: 'chill' | 'hype' | 'balanced') => Promise<void>;
}

const SpotifyContext = createContext<SpotifyContextType | null>(null);

export function SpotifyProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<SpotifyUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<SpotifyPlaylist[]>([]);
  const [accessToken, setAccessToken] = useState<string | null>(null);

  // Check for token on load
  useEffect(() => {
    const token = localStorage.getItem('spotify_access_token');
    const expiry = localStorage.getItem('spotify_token_expiry');
    
    if (token && expiry && Date.now() < parseInt(expiry)) {
      setAccessToken(token);
      fetchUserProfile(token);
    }
    
    // Handle OAuth callback
    const params = new URLSearchParams(window.location.search);
    const callbackToken = params.get('spotify_token');
    const callbackExpiry = params.get('spotify_expires');
    
    if (callbackToken && callbackExpiry) {
      localStorage.setItem('spotify_access_token', callbackToken);
      localStorage.setItem('spotify_token_expiry', String(Date.now() + parseInt(callbackExpiry) * 1000));
      setAccessToken(callbackToken);
      fetchUserProfile(callbackToken);
      window.history.replaceState({}, '', '/');
    }
  }, []);

  const fetchUserProfile = async (token: string) => {
    try {
      const res = await fetch('https://api.spotify.com/v1/me', {
        headers: { Authorization: `Bearer ${token}` }
      });
      if (res.ok) {
        const userData = await res.json();
        setUser(userData);
        fetchPlaylists(token);
      } else {
        // Token expired
        disconnect();
      }
    } catch (e) {
      console.error('Failed to fetch Spotify profile:', e);
    }
  };

  const fetchPlaylists = async (token: string) => {
    try {
      const res = await fetch('https://api.spotify.com/v1/me/playlists?limit=20', {
        headers: { Authorization: `Bearer ${token}` }
      });
      if (res.ok) {
        const data = await res.json();
        setPlaylists(data.items || []);
      }
    } catch (e) {
      console.error('Failed to fetch playlists:', e);
    }
  };

  const connectSpotify = () => {
    const clientId = process.env.NEXT_PUBLIC_SPOTIFY_CLIENT_ID;
    const redirectUri = `${window.location.origin}/api/spotify/callback`;
    const scopes = [
      'user-read-email',
      'user-read-private',
      'playlist-read-private',
      'playlist-read-collaborative',
      'streaming',
      'user-library-read',
    ].join(' ');
    
    const authUrl = `https://accounts.spotify.com/authorize?` +
      `client_id=${clientId}&` +
      `response_type=token&` +
      `redirect_uri=${encodeURIComponent(redirectUri)}&` +
      `scope=${encodeURIComponent(scopes)}`;
    
    window.location.href = authUrl;
  };

  const disconnect = () => {
    localStorage.removeItem('spotify_access_token');
    localStorage.removeItem('spotify_token_expiry');
    setAccessToken(null);
    setUser(null);
    setPlaylists([]);
  };

  const getPlaylistTracks = async (playlistId: string): Promise<SpotifyTrack[]> => {
    if (!accessToken) return [];
    
    try {
      const res = await fetch(`https://api.spotify.com/v1/playlists/${playlistId}/tracks?limit=50`, {
        headers: { Authorization: `Bearer ${accessToken}` }
      });
      if (res.ok) {
        const data = await res.json();
        return data.items
          .filter((item: any) => item.track && item.track.preview_url)
          .map((item: any) => item.track);
      }
    } catch (e) {
      console.error('Failed to fetch tracks:', e);
    }
    return [];
  };

  const createRadioStation = async (mood: 'chill' | 'hype' | 'balanced') => {
    if (!accessToken || !user) {
      connectSpotify();
      return;
    }

    setIsLoading(true);
    
    try {
      // Get user's top tracks or recommended based on mood
      const seedGenres = {
        chill: ['chill', 'lo-fi', 'ambient'],
        hype: ['hip-hop', 'party', 'electronic'],
        balanced: ['pop', 'indie', 'acoustic']
      }[mood];

      // Get recommendations based on user's top artists (simplified)
      const recRes = await fetch(
        `https://api.spotify.com/v1/recommendations?seed_genres=${seedGenres[0]}&limit=20`,
        { headers: { Authorization: `Bearer ${accessToken}` }}
      );

      if (recRes.ok) {
        const recData = await recRes.json();
        const tracks = recData.tracks.filter((t: any) => t.preview_url);
        
        // Convert to our format and queue
        const radioTracks = tracks.map((t: any) => ({
          id: t.id,
          title: t.name,
          artistName: t.artists.map((a: any) => a.name).join(', '),
          albumName: t.album.name,
          artworkUrl: t.album.images[0]?.url || '',
          duration: Math.floor(t.duration_ms / 1000),
          previewUrl: t.preview_url,
          spotifyUri: t.uri,
        }));

        setQueue(radioTracks);
        setCurrentTrack(radioTracks[0]);
        setIsPlaying(true);
      }
    } catch (e) {
      console.error('Failed to create radio:', e);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <SpotifyContext.Provider
      value={{
        user,
        isAuthenticated: !!user && !!accessToken,
        isLoading,
        playlists,
        connectSpotify,
        disconnect,
        getPlaylistTracks,
        createRadioStation,
      }}
    >
      {children}
    </SpotifyContext.Provider>
  );
}

export function useSpotify() {
  const context = useContext(SpotifyContext);
  if (!context) {
    throw new Error('useSpotify must be used within SpotifyProvider');
  }
  return context;
}
