'use client';

import { createContext, useContext, useEffect, useState, useCallback, ReactNode } from 'react';
import { useRadioStore } from '@/lib/store/radio';

interface AppleMusicUser {
  name: string;
  id: string;
}

interface AppleMusicPlaylist {
  id: string;
  name: string;
  description?: { label: string };
  artwork?: { url: string };
  trackCount: number;
}

interface AppleMusicContextType {
  user: AppleMusicUser | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  playlists: AppleMusicPlaylist[];
  connectAppleMusic: () => Promise<void>;
  disconnect: () => void;
  createRadioStation: (mood: 'chill' | 'hype' | 'balanced') => Promise<void>;
}

const AppleMusicContext = createContext<AppleMusicContextType | null>(null);

function getMusicKitInstance(): any | null {
  try {
    const MK = (window as any).MusicKit;
    if (!MK) return null;
    return MK.getInstance();
  } catch {
    return null;
  }
}

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<AppleMusicUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<AppleMusicPlaylist[]>([]);
  const [ready, setReady] = useState(false);

  // Wait for MusicKit to be configured and get an instance
  useEffect(() => {
    const check = () => {
      const instance = getMusicKitInstance();
      if (instance) {
        setReady(true);
        // If already authorized, restore session
        if (instance.isAuthorized) {
          setUser({ name: 'Apple Music User', id: 'apple-user' });
          loadPlaylists(instance);
        }
        return true;
      }
      return false;
    };

    if (check()) return;

    // Poll until MusicKit is ready (script loads async)
    const interval = setInterval(() => {
      if (check()) clearInterval(interval);
    }, 300);
    const timeout = setTimeout(() => clearInterval(interval), 15000);

    return () => {
      clearInterval(interval);
      clearTimeout(timeout);
    };
  }, []);

  const loadPlaylists = async (instance: any) => {
    try {
      const result = await instance.api.music('/v1/me/library/playlists', { limit: 20 });
      const items = result?.data?.data || [];
      setPlaylists(items.map((p: any) => ({
        id: p.id,
        name: p.attributes?.name || 'Untitled',
        description: p.attributes?.description,
        artwork: p.attributes?.artwork,
        trackCount: p.attributes?.trackCount || 0,
      })));
    } catch (e) {
      console.warn('Could not load Apple Music playlists:', e);
    }
  };

  const connectAppleMusic = useCallback(async () => {
    const instance = getMusicKitInstance();
    if (!instance) {
      alert('Apple Music is not available. Make sure you have a developer token configured.');
      return;
    }

    setIsLoading(true);
    try {
      await instance.authorize();
      setUser({ name: 'Apple Music User', id: 'apple-user' });
      await loadPlaylists(instance);
    } catch (e) {
      console.error('Apple Music auth failed:', e);
      alert('Apple Music authorization failed. Check your developer token.');
    } finally {
      setIsLoading(false);
    }
  }, []);

  const disconnect = useCallback(() => {
    const instance = getMusicKitInstance();
    if (instance) {
      try { instance.unauthorize(); } catch {}
    }
    setUser(null);
    setPlaylists([]);
  }, []);

  const createRadioStation = useCallback(async (mood: 'chill' | 'hype' | 'balanced') => {
    const instance = getMusicKitInstance();
    if (!instance || !instance.isAuthorized) {
      await connectAppleMusic();
      return;
    }

    setIsLoading(true);
    try {
      const genreSeeds: Record<string, string> = {
        chill: 'chill',
        hype: 'hip-hop',
        balanced: 'pop',
      };

      // Search for tracks by genre
      const result = await instance.api.music('/v1/catalog/us/search', {
        term: genreSeeds[mood],
        types: 'songs',
        limit: 20,
      });

      const songs = result?.data?.results?.songs?.data || [];

      const radioTracks = songs.map((t: any) => ({
        id: t.id,
        title: t.attributes?.name || 'Unknown',
        artistName: t.attributes?.artistName || 'Unknown',
        albumName: t.attributes?.albumName,
        artworkUrl: t.attributes?.artwork?.url?.replace('{w}', '200').replace('{h}', '200'),
        duration: Math.floor((t.attributes?.durationInMillis || 30000) / 1000),
        previewUrl: t.attributes?.previews?.[0]?.url,
      }));

      if (radioTracks.length > 0) {
        setQueue(radioTracks.slice(1));
        setCurrentTrack(radioTracks[0]);
        setIsPlaying(true);
      }
    } catch (e) {
      console.error('Failed to create radio station:', e);
    } finally {
      setIsLoading(false);
    }
  }, [connectAppleMusic, setQueue, setCurrentTrack, setIsPlaying]);

  return (
    <AppleMusicContext.Provider
      value={{
        user,
        isAuthenticated: !!user,
        isLoading,
        playlists,
        connectAppleMusic,
        disconnect,
        createRadioStation,
      }}
    >
      {children}
    </AppleMusicContext.Provider>
  );
}

export function useAppleMusic() {
  const context = useContext(AppleMusicContext);
  if (!context) {
    throw new Error('useAppleMusic must be used within AppleMusicProvider');
  }
  return context;
}
