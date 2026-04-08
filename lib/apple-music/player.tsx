'use client';

import { createContext, useContext, useEffect, useState, ReactNode } from 'react';
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

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<AppleMusicUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<AppleMusicPlaylist[]>([]);
  const [music, setMusic] = useState<any>(null);

  // Initialize MusicKit v3
  useEffect(() => {
    const token = process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '';

    const init = async () => {
      const MK = (window as any).MusicKit;
      if (!MK || !token) return;

      try {
        // MusicKit v3: configure() is async, returns void. Use getInstance() after.
        await MK.configure({
          developerToken: token,
          app: { name: 'RAY.DO', build: '1.0.0' },
        });
        const instance = MK.getInstance();
        setMusic(instance);

        // Check for existing auth
        if (instance.isAuthorized) {
          setUser({ name: 'Apple Music User', id: 'apple-user' });
        }
      } catch (e) {
        console.error('MusicKit init failed:', e);
      }
    };

    if ((window as any).MusicKit) {
      init();
    } else {
      document.addEventListener('musickitloaded', init);
      return () => document.removeEventListener('musickitloaded', init);
    }
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

      // Load playlists via v3 API
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

  const createRadioStation = async (mood: 'chill' | 'hype' | 'balanced') => {
    if (!music || !music.isAuthorized) {
      await connectAppleMusic();
      return;
    }

    setIsLoading(true);
    try {
      const terms: Record<string, string> = { chill: 'chill', hype: 'hip hop', balanced: 'pop' };
      const storefront = music.storefrontId || 'us';

      // MusicKit v3 search API
      const result = await music.api.music(`/v1/catalog/${storefront}/search`, {
        term: terms[mood],
        types: ['songs'],
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
      console.error('Failed to create radio:', e);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <AppleMusicContext.Provider value={{
      user, isAuthenticated: !!user, isLoading, playlists,
      connectAppleMusic, disconnect, createRadioStation,
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
