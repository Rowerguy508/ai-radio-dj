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

// Get the MusicKit instance that was configured by musickit-init.tsx
function getMusicInstance(): any | null {
  // First check our stored instance
  if ((window as any).__musicKitInstance) {
    return (window as any).__musicKitInstance;
  }
  // Fallback: try MusicKit.getInstance()
  try {
    const MK = (window as any).MusicKit;
    if (MK) return MK.getInstance();
  } catch {}
  return null;
}

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<AppleMusicUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<AppleMusicPlaylist[]>([]);
  const [instance, setInstance] = useState<any>(null);

  // Wait for MusicKit to be configured
  useEffect(() => {
    const onReady = () => {
      const mk = getMusicInstance();
      if (mk) {
        setInstance(mk);
        // Check if already authorized from a previous session
        if (mk.isAuthorized) {
          setUser({ name: 'Apple Music User', id: 'apple-user' });
          loadPlaylists(mk);
        }
      }
    };

    // Check immediately
    const mk = getMusicInstance();
    if (mk) {
      onReady();
    } else {
      // Wait for the musickitconfigured event from musickit-init.tsx
      window.addEventListener('musickitconfigured', onReady);
      return () => window.removeEventListener('musickitconfigured', onReady);
    }
  }, []);

  const loadPlaylists = async (mk: any) => {
    try {
      // MusicKit JS v1 uses mk.api.library.playlists()
      // MusicKit JS v3 uses mk.api.music('/v1/me/library/playlists')
      // Try v3 first, fallback to v1
      let items: any[] = [];
      try {
        const result = await mk.api.music('/v1/me/library/playlists', { limit: 20 });
        items = result?.data?.data || [];
      } catch {
        // v1 fallback
        try {
          items = await mk.api.library.playlists() || [];
        } catch {}
      }

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
    let mk = instance || getMusicInstance();
    if (!mk) {
      alert('Apple Music is not available. Make sure your developer token is configured in Vercel environment variables.');
      return;
    }

    setIsLoading(true);
    try {
      // This opens Apple's OAuth popup
      await mk.authorize();
      setInstance(mk);
      setUser({ name: 'Apple Music User', id: 'apple-user' });
      await loadPlaylists(mk);
    } catch (e: any) {
      console.error('Apple Music auth failed:', e);
      if (e?.message?.includes('token') || e?.name === 'AUTHORIZATION_ERROR') {
        alert('Apple Music authorization failed. Your developer token may be invalid or expired.');
      } else {
        alert('Apple Music authorization was cancelled or failed.');
      }
    } finally {
      setIsLoading(false);
    }
  }, [instance]);

  const disconnect = useCallback(() => {
    const mk = instance || getMusicInstance();
    if (mk) {
      try { mk.unauthorize(); } catch {}
    }
    setUser(null);
    setPlaylists([]);
  }, [instance]);

  const createRadioStation = useCallback(async (mood: 'chill' | 'hype' | 'balanced') => {
    const mk = instance || getMusicInstance();
    if (!mk || !mk.isAuthorized) {
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

      // Search for tracks
      let songs: any[] = [];
      try {
        // v3 API
        const result = await mk.api.music(`/v1/catalog/${mk.storefrontId || 'us'}/search`, {
          term: genreSeeds[mood],
          types: 'songs',
          limit: 20,
        });
        songs = result?.data?.results?.songs?.data || [];
      } catch {
        // v1 fallback
        try {
          const result = await mk.api.search(genreSeeds[mood], { types: 'songs', limit: 20 });
          songs = result?.songs?.data || [];
        } catch {}
      }

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
  }, [instance, connectAppleMusic, setQueue, setCurrentTrack, setIsPlaying]);

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
