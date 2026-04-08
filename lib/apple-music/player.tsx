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
  const [musicInstance, setMusicInstance] = useState<any>(null);

  // This mirrors the exact pattern from the original working code (commit 09b110b):
  // Load MusicKit script ourselves, configure on load, store the instance.
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
        setMusicInstance(instance);
      } catch (e) {
        console.error('MusicKit.configure failed:', e);
        // If already configured, try getInstance
        try {
          setMusicInstance(MK.getInstance());
        } catch {}
      }
    };

    // If MusicKit is already on the page (from layout.tsx script tag), configure now
    if ((window as any).MusicKit) {
      configure();
    }

    // Also listen for the musickitloaded event (fires when the script finishes loading)
    const onLoaded = () => configure();
    document.addEventListener('musickitloaded', onLoaded);

    return () => {
      document.removeEventListener('musickitloaded', onLoaded);
    };
  }, []);

  const connectAppleMusic = async () => {
    if (!musicInstance) {
      alert('Apple Music is still loading. Please wait a moment and try again.');
      return;
    }

    setIsLoading(true);
    try {
      await musicInstance.authorize();
      setUser({ name: 'Apple Music User', id: 'apple-user' });

      try {
        const userPlaylists = await musicInstance.api.library.playlists();
        setPlaylists((userPlaylists || []).map((p: any) => ({
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
    try { musicInstance?.unauthorize(); } catch {}
    setUser(null);
    setPlaylists([]);
  };

  const createRadioStation = async (mood: 'chill' | 'hype' | 'balanced') => {
    if (!musicInstance || !musicInstance.isAuthorized) {
      await connectAppleMusic();
      return;
    }

    setIsLoading(true);
    try {
      const terms: Record<string, string> = { chill: 'chill', hype: 'hip hop', balanced: 'pop' };
      const results = await musicInstance.api.search(terms[mood], { types: 'songs', limit: 20 });
      const songs = results?.songs?.data || [];

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
