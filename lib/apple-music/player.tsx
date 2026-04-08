'use client';

import { createContext, useContext, useEffect, useState, ReactNode } from 'react';
import { useRadioStore, Track } from '@/lib/store/radio';

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
  music: any; // MusicKit instance
  connectAppleMusic: () => Promise<void>;
  disconnect: () => void;
  searchTracks: (query: string, limit?: number) => Promise<Track[]>;
  createRadioStation: (mood: 'chill' | 'hype' | 'balanced') => Promise<void>;
}

const AppleMusicContext = createContext<AppleMusicContextType | null>(null);

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<AppleMusicUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<AppleMusicPlaylist[]>([]);
  const [music, setMusic] = useState<any>(null);

  useEffect(() => {
    const token = process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '';

    const configure = () => {
      const MK = (window as any).MusicKit;
      if (!MK) return;
      try {
        const instance = MK.configure({
          developerToken: token,
          app: { name: 'RAY.DO', build: '1.0.0' },
        });
        setMusic(instance);
      } catch (e) {
        try { setMusic(MK.getInstance()); } catch {}
      }
    };

    if ((window as any).MusicKit) {
      configure();
    }
    const onLoaded = () => configure();
    document.addEventListener('musickitloaded', onLoaded);
    return () => document.removeEventListener('musickitloaded', onLoaded);
  }, []);

  const connectAppleMusic = async () => {
    if (!music) {
      alert('Apple Music is still loading. Please wait a moment and try again.');
      return;
    }
    setIsLoading(true);
    try {
      await music.authorize();
      setUser({ name: 'Apple Music User', id: 'apple-user' });
      try {
        const result = await music.api.music('/v1/me/library/playlists', { limit: 25 });
        const items = result?.data?.data || [];
        setPlaylists(items.map((p: any) => ({
          id: p.id,
          name: p.attributes?.name || 'Untitled',
          description: p.attributes?.description,
          artwork: p.attributes?.artwork,
          trackCount: p.attributes?.trackCount || 0,
        })));
      } catch {}
    } catch (e) {
      console.error('Apple Music auth failed:', e);
    } finally {
      setIsLoading(false);
    }
  };

  const disconnect = () => {
    try { music?.unauthorize(); } catch {}
    setUser(null);
    setPlaylists([]);
  };

  // Search Apple Music catalog and return Track[]
  const searchTracks = async (query: string, limit = 20): Promise<Track[]> => {
    if (!music) return [];
    try {
      const storefront = music.storefrontId || 'us';
      const result = await music.api.music(`/v1/catalog/${storefront}/search`, {
        term: query,
        types: ['songs'],
        limit,
      });
      const songs = result?.data?.results?.songs?.data || [];
      return songs.map((t: any) => ({
        id: t.id,
        title: t.attributes?.name || 'Unknown',
        artistName: t.attributes?.artistName || 'Unknown',
        albumName: t.attributes?.albumName,
        artworkUrl: t.attributes?.artwork?.url?.replace('{w}', '200').replace('{h}', '200'),
        duration: Math.floor((t.attributes?.durationInMillis || 30000) / 1000),
        previewUrl: t.attributes?.previews?.[0]?.url,
      }));
    } catch (e) {
      console.error('Apple Music search failed:', e);
      return [];
    }
  };

  const createRadioStation = async (mood: 'chill' | 'hype' | 'balanced') => {
    if (!music || !music.isAuthorized) {
      await connectAppleMusic();
      return;
    }
    setIsLoading(true);
    try {
      const terms: Record<string, string> = { chill: 'chill', hype: 'hip hop', balanced: 'pop' };
      const tracks = await searchTracks(terms[mood]);
      if (tracks.length > 0) {
        setQueue(tracks.slice(1));
        setCurrentTrack(tracks[0]);
        setIsPlaying(true);
      }
    } catch (e) {
      console.error('Failed to create radio:', e);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <AppleMusicContext.Provider value={{
      user, isAuthenticated: !!user, isLoading, playlists, music,
      connectAppleMusic, disconnect, searchTracks, createRadioStation,
    }}>
      {children}
    </AppleMusicContext.Provider>
  );
}

export function useAppleMusic() {
  const context = useContext(AppleMusicContext);
  if (!context) throw new Error('useAppleMusic must be used within AppleMusicProvider');
  return context;
}
