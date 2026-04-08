'use client';

import { createContext, useContext, useEffect, useState, ReactNode } from 'react';
import { useRadioStore } from '@/lib/store/radio';

interface AppleMusicUser {
  name: string;
  email: string;
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

// Ensure MusicKit is loaded and configured, returns the MusicKit namespace or null
async function ensureMusicKit(): Promise<any | null> {
  const MK = (window as any).MusicKit;

  // Already available
  if (MK) {
    try {
      // Try to get instance (means it's already configured)
      MK.getInstance();
    } catch {
      // Not configured yet - configure now
      const token = process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '';
      if (!token) {
        console.error('NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN is not set');
        return null;
      }
      try {
        await MK.configure({
          developerToken: token,
          app: { name: 'RAY.DO', build: '1.0.0' },
        });
      } catch (e) {
        console.error('MusicKit.configure() failed:', e);
        return null;
      }
    }
    return MK;
  }

  // Script not loaded yet - wait for it
  return new Promise((resolve) => {
    const onLoaded = async () => {
      document.removeEventListener('musickitloaded', onLoaded);
      clearTimeout(timeout);
      clearInterval(poll);

      const loadedMK = (window as any).MusicKit;
      if (!loadedMK) { resolve(null); return; }

      const token = process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '';
      if (!token) { resolve(null); return; }

      try {
        await loadedMK.configure({
          developerToken: token,
          app: { name: 'RAY.DO', build: '1.0.0' },
        });
        resolve(loadedMK);
      } catch (e) {
        console.error('MusicKit.configure() failed:', e);
        resolve(null);
      }
    };

    document.addEventListener('musickitloaded', onLoaded);

    // Poll fallback
    const poll = setInterval(() => {
      if ((window as any).MusicKit) {
        clearInterval(poll);
        onLoaded();
      }
    }, 300);

    // Give up after 10 seconds
    const timeout = setTimeout(() => {
      clearInterval(poll);
      document.removeEventListener('musickitloaded', onLoaded);
      console.error('MusicKit script failed to load within 10 seconds');
      resolve(null);
    }, 10000);
  });
}

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<AppleMusicUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<AppleMusicPlaylist[]>([]);

  // On mount, try to initialize and check for existing session
  useEffect(() => {
    ensureMusicKit().then(mk => {
      if (!mk) return;
      try {
        const instance = mk.getInstance();
        if (instance?.isAuthorized) {
          setUser({ name: 'Apple Music User', email: '', id: 'apple-user' });
        }
      } catch {}
    });
  }, []);

  const connectAppleMusic = async () => {
    setIsLoading(true);
    try {
      const mk = await ensureMusicKit();
      if (!mk) {
        alert('Could not initialize Apple Music. Check that your developer token is valid.');
        return;
      }

      const instance = mk.getInstance();
      await instance.authorize();

      setUser({ name: 'Apple Music User', email: '', id: 'apple-user' });

      // Load playlists
      try {
        const result = await instance.api.library.playlists();
        setPlaylists((result || []).map((p: any) => ({
          id: p.id,
          name: p.attributes?.name || 'Untitled',
          description: p.attributes?.description,
          artwork: p.attributes?.artwork,
          trackCount: p.attributes?.trackCount || 0,
        })));
      } catch (e) {
        console.warn('Could not load playlists:', e);
      }
    } catch (e) {
      console.error('Apple Music auth failed:', e);
    } finally {
      setIsLoading(false);
    }
  };

  const disconnect = () => {
    try {
      const mk = (window as any).MusicKit;
      if (mk) mk.getInstance()?.unauthorize();
    } catch {}
    setUser(null);
    setPlaylists([]);
  };

  const createRadioStation = async (mood: 'chill' | 'hype' | 'balanced') => {
    const mk = (window as any).MusicKit;
    if (!mk) { await connectAppleMusic(); return; }

    let instance: any;
    try { instance = mk.getInstance(); } catch { await connectAppleMusic(); return; }
    if (!instance?.isAuthorized) { await connectAppleMusic(); return; }

    setIsLoading(true);
    try {
      const searchTerms: Record<string, string> = {
        chill: 'chill lo-fi',
        hype: 'hip-hop electronic',
        balanced: 'pop indie',
      };

      // Use the catalog search API
      const results = await instance.api.search(searchTerms[mood], { types: 'songs', limit: 20 });
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
