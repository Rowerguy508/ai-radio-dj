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
  music: any;
  connectAppleMusic: () => Promise<void>;
  disconnect: () => void;
  searchTracks: (query: string, limit?: number) => Promise<Track[]>;
  createRadioStation: (mood: 'chill' | 'hype' | 'balanced') => Promise<void>;
}

const AppleMusicContext = createContext<AppleMusicContextType | null>(null);

// Debug logger
function log(...args: any[]) {
  console.log('[AppleMusic]', ...args);
}

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<AppleMusicUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<AppleMusicPlaylist[]>([]);
  const [music, setMusic] = useState<any>(null);

  useEffect(() => {
    const token = process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '';
    log('Token present:', !!token, 'length:', token.length);

    const configure = async () => {
      const MK = (window as any).MusicKit;
      if (!MK) { log('MusicKit not on window'); return; }
      log('MusicKit found, configuring...');

      try {
        // MusicKit v3: configure() returns a Promise
        await MK.configure({
          developerToken: token,
          app: { name: 'RAY.DO', build: '1.0.0' },
        });
        const instance = MK.getInstance();
        log('Configured successfully, instance:', !!instance);
        log('isAuthorized:', instance?.isAuthorized);
        setMusic(instance);
      } catch (e) {
        log('Configure error:', e);
        // Try getInstance in case already configured
        try {
          const instance = MK.getInstance();
          log('Got existing instance:', !!instance);
          setMusic(instance);
        } catch (e2) {
          log('getInstance also failed:', e2);
        }
      }
    };

    if ((window as any).MusicKit) {
      configure();
    } else {
      log('Waiting for MusicKit script...');
      const onLoaded = () => { log('musickitloaded event fired'); configure(); };
      document.addEventListener('musickitloaded', onLoaded);
      // Polling fallback
      const poll = setInterval(() => {
        if ((window as any).MusicKit) {
          log('MusicKit found via polling');
          clearInterval(poll);
          configure();
        }
      }, 500);
      return () => {
        document.removeEventListener('musickitloaded', onLoaded);
        clearInterval(poll);
      };
    }
  }, []);

  const connectAppleMusic = async () => {
    log('connectAppleMusic called, music:', !!music);
    if (!music) {
      alert('Apple Music is still loading. Please wait a moment and try again.');
      return;
    }
    setIsLoading(true);
    try {
      log('Calling authorize()...');
      await music.authorize();
      log('Authorized successfully');
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
        log('Loaded', items.length, 'playlists');
      } catch (e) {
        log('Playlist load failed:', e);
      }
    } catch (e) {
      log('Auth failed:', e);
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

  const searchTracks = async (query: string, limit = 20): Promise<Track[]> => {
    log('searchTracks called, query:', query, 'music:', !!music);
    if (!music) return [];
    try {
      const storefront = music.storefrontId || 'us';
      log('Searching catalog, storefront:', storefront);
      const result = await music.api.music(`/v1/catalog/${storefront}/search`, {
        term: query,
        types: ['songs'],
        limit,
      });
      const songs = result?.data?.results?.songs?.data || [];
      const withPreviews = songs.filter((t: any) => t.attributes?.previews?.[0]?.url);
      log('Found', songs.length, 'songs,', withPreviews.length, 'with previews, term:', query);
      return withPreviews.map((t: any) => ({
        id: t.id,
        title: t.attributes?.name || 'Unknown',
        artistName: t.attributes?.artistName || 'Unknown',
        albumName: t.attributes?.albumName,
        artworkUrl: t.attributes?.artwork?.url?.replace('{w}', '200').replace('{h}', '200'),
        duration: Math.floor((t.attributes?.durationInMillis || 30000) / 1000),
        previewUrl: t.attributes?.previews?.[0]?.url,
      }));
    } catch (e) {
      log('Search failed:', e);
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
