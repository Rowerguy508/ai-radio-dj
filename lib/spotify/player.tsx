'use client';

import { createContext, useContext, useEffect, useState, useCallback, ReactNode } from 'react';
import { useRadioStore } from '@/lib/store/radio';

interface SpotifyUser {
  id: string;
  email: string;
  display_name: string;
  images?: { url: string }[];
}

interface SpotifyPlaylist {
  id: string;
  name: string;
  description: string;
  images: { url: string }[];
  tracks: {
    total: number;
  };
}

interface SpotifyContextType {
  user: SpotifyUser | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  playlists: SpotifyPlaylist[];
  connectSpotify: () => void;
  disconnect: () => void;
  createRadioStation: (mood: 'chill' | 'hype' | 'balanced') => Promise<void>;
}

const SpotifyContext = createContext<SpotifyContextType | null>(null);

// PKCE helpers
function generateRandomString(length: number): string {
  const possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const values = crypto.getRandomValues(new Uint8Array(length));
  return values.reduce((acc, x) => acc + possible[x % possible.length], '');
}

async function sha256(plain: string): Promise<ArrayBuffer> {
  const encoder = new TextEncoder();
  const data = encoder.encode(plain);
  return window.crypto.subtle.digest('SHA-256', data);
}

function base64encode(input: ArrayBuffer): string {
  const bytes = new Uint8Array(input);
  let binary = '';
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary)
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

export function SpotifyProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<SpotifyUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<SpotifyPlaylist[]>([]);
  const [accessToken, setAccessToken] = useState<string | null>(null);

  // On load: check for stored token or handle OAuth callback
  useEffect(() => {
    const token = localStorage.getItem('spotify_access_token');
    const expiry = localStorage.getItem('spotify_token_expiry');

    if (token && expiry && Date.now() < parseInt(expiry)) {
      setAccessToken(token);
      fetchUserProfile(token);
      return;
    }

    // Handle PKCE callback - code comes in query params
    const params = new URLSearchParams(window.location.search);
    const code = params.get('code');
    const storedVerifier = localStorage.getItem('spotify_code_verifier');

    if (code && storedVerifier) {
      exchangeCodeForToken(code, storedVerifier);
      // Clean up URL
      window.history.replaceState({}, '', '/');
    }
  }, []);

  const exchangeCodeForToken = async (code: string, codeVerifier: string) => {
    const clientId = process.env.NEXT_PUBLIC_SPOTIFY_CLIENT_ID;
    if (!clientId) return;

    try {
      const res = await fetch('https://accounts.spotify.com/api/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          client_id: clientId,
          grant_type: 'authorization_code',
          code,
          redirect_uri: `${window.location.origin}/api/spotify/callback`,
          code_verifier: codeVerifier,
        }),
      });

      if (res.ok) {
        const data = await res.json();
        const token = data.access_token;
        const expiresIn = data.expires_in || 3600;

        localStorage.setItem('spotify_access_token', token);
        localStorage.setItem('spotify_token_expiry', String(Date.now() + expiresIn * 1000));
        localStorage.removeItem('spotify_code_verifier');

        setAccessToken(token);
        fetchUserProfile(token);
      } else {
        console.error('Token exchange failed:', await res.text());
      }
    } catch (e) {
      console.error('Token exchange error:', e);
    }
  };

  const fetchUserProfile = async (token: string) => {
    try {
      const res = await fetch('https://api.spotify.com/v1/me', {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (res.ok) {
        const userData = await res.json();
        setUser(userData);
        fetchPlaylists(token);
      } else {
        disconnect();
      }
    } catch (e) {
      console.error('Failed to fetch Spotify profile:', e);
    }
  };

  const fetchPlaylists = async (token: string) => {
    try {
      const res = await fetch('https://api.spotify.com/v1/me/playlists?limit=20', {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (res.ok) {
        const data = await res.json();
        setPlaylists(data.items || []);
      }
    } catch (e) {
      console.error('Failed to fetch playlists:', e);
    }
  };

  const connectSpotify = useCallback(async () => {
    const clientId = process.env.NEXT_PUBLIC_SPOTIFY_CLIENT_ID;
    if (!clientId) {
      alert('Spotify Client ID not configured.');
      return;
    }

    // Generate PKCE challenge
    const codeVerifier = generateRandomString(64);
    const hashed = await sha256(codeVerifier);
    const codeChallenge = base64encode(hashed);

    localStorage.setItem('spotify_code_verifier', codeVerifier);

    const redirectUri = `${window.location.origin}/api/spotify/callback`;
    const scopes = [
      'user-read-email',
      'user-read-private',
      'playlist-read-private',
      'playlist-read-collaborative',
      'user-library-read',
    ].join(' ');

    const authUrl = new URL('https://accounts.spotify.com/authorize');
    authUrl.searchParams.set('client_id', clientId);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('redirect_uri', redirectUri);
    authUrl.searchParams.set('scope', scopes);
    authUrl.searchParams.set('code_challenge_method', 'S256');
    authUrl.searchParams.set('code_challenge', codeChallenge);

    window.location.href = authUrl.toString();
  }, []);

  const disconnect = useCallback(() => {
    localStorage.removeItem('spotify_access_token');
    localStorage.removeItem('spotify_token_expiry');
    localStorage.removeItem('spotify_code_verifier');
    setAccessToken(null);
    setUser(null);
    setPlaylists([]);
  }, []);

  const createRadioStation = useCallback(async (mood: 'chill' | 'hype' | 'balanced') => {
    if (!accessToken || !user) {
      connectSpotify();
      return;
    }

    setIsLoading(true);
    try {
      const seedGenres: Record<string, string> = {
        chill: 'chill',
        hype: 'hip-hop',
        balanced: 'pop',
      };

      const recRes = await fetch(
        `https://api.spotify.com/v1/recommendations?seed_genres=${seedGenres[mood]}&limit=20`,
        { headers: { Authorization: `Bearer ${accessToken}` } }
      );

      if (recRes.ok) {
        const recData = await recRes.json();
        const tracks = (recData.tracks || []).filter((t: any) => t.preview_url);

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

        if (radioTracks.length > 0) {
          setQueue(radioTracks.slice(1));
          setCurrentTrack(radioTracks[0]);
          setIsPlaying(true);
        }
      }
    } catch (e) {
      console.error('Failed to create radio:', e);
    } finally {
      setIsLoading(false);
    }
  }, [accessToken, user, connectSpotify, setQueue, setCurrentTrack, setIsPlaying]);

  return (
    <SpotifyContext.Provider
      value={{
        user,
        isAuthenticated: !!user && !!accessToken,
        isLoading,
        playlists,
        connectSpotify,
        disconnect,
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
