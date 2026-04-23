'use client';

import { createContext, useContext, useEffect, useState, useCallback, useRef, ReactNode } from 'react';
import { useRadioStore, Track } from '@/lib/store/radio';

interface AppleMusicContextType {
  user: { name: string; id: string } | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  playlists: any[];
  music: any;
  connectAppleMusic: () => Promise<void>;
  disconnect: () => void;
  searchTracks: (query: string, limit?: number) => Promise<Track[]>;
  createRadioStation: (mood: 'chill' | 'hype' | 'balanced') => Promise<void>;
  playWithMusicKit: (tracks: Track[]) => Promise<void>;
  musicKitPlay: () => Promise<void>;
  musicKitPause: () => void;
  musicKitSkip: () => Promise<void>;
  musicKitProgress: { current: number; total: number };
}

const AppleMusicContext = createContext<AppleMusicContextType | null>(null);

function log(...args: any[]) {
  console.log('[AppleMusic]', ...args);
}

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const store = useRadioStore;
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<{ name: string; id: string } | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<any[]>([]);
  const [music, setMusic] = useState<any>(null);
  const [musicKitProgress, setMusicKitProgress] = useState({ current: 0, total: 0 });
  const trackMapRef = useRef<Map<string, Track>>(new Map());

  useEffect(() => {
    const token = process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '';
    log('Token present:', !!token, 'length:', token.length);

    const configure = async () => {
      const MK = (window as any).MusicKit;
      if (!MK) { log('MusicKit not on window'); return; }
      log('MusicKit found, configuring...');

      try {
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

  // Listen to MusicKit playback events to sync with our store
  useEffect(() => {
    if (!music) return;

    const onPlaybackStateChange = (e: any) => {
      const state = e?.state ?? music.playbackState;
      log('Playback state:', state);
      // MusicKit states: 0=none, 1=loading, 2=playing, 3=paused, 4=stopped, 5=ended, 6=seeking, 8=waiting, 9=stalled, 10=completed
      const playing = state === 2;
      store.getState().setIsPlaying(playing);
    };

    const onNowPlayingChange = () => {
      const item = music.nowPlayingItem;
      if (!item) return;

      const id = item.id || item._songId || '';
      const mapped = trackMapRef.current.get(id);

      const track: Track = mapped || {
        id,
        title: item.attributes?.name || item.title || 'Unknown',
        artistName: item.attributes?.artistName || item.artistName || 'Unknown',
        albumName: item.attributes?.albumName || item.albumName,
        artworkUrl: item.attributes?.artwork?.url?.replace('{w}', '400').replace('{h}', '400')
          || item.artworkURL,
        duration: Math.floor((item.attributes?.durationInMillis || item.playbackDuration || 30000) / 1000),
      };

      log('Now playing:', track.title, '-', track.artistName);
      store.getState().setCurrentTrack(track);
    };

    const onPlaybackTimeChange = (e: any) => {
      setMusicKitProgress({
        current: e?.currentPlaybackTime ?? music.currentPlaybackTime ?? 0,
        total: e?.currentPlaybackDuration ?? music.currentPlaybackDuration ?? 0,
      });
    };

    music.addEventListener('playbackStateDidChange', onPlaybackStateChange);
    music.addEventListener('nowPlayingItemDidChange', onNowPlayingChange);
    music.addEventListener('playbackTimeDidChange', onPlaybackTimeChange);

    return () => {
      music.removeEventListener('playbackStateDidChange', onPlaybackStateChange);
      music.removeEventListener('nowPlayingItemDidChange', onNowPlayingChange);
      music.removeEventListener('playbackTimeDidChange', onPlaybackTimeChange);
    };
  }, [music]);

  // Sync volume
  useEffect(() => {
    if (music) {
      music.volume = useRadioStore.getState().volume;
    }
  }, [music]);

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
      log('Found', songs.length, 'songs for term:', query);
      return songs.map((t: any) => ({
        id: t.id,
        title: t.attributes?.name || 'Unknown',
        artistName: t.attributes?.artistName || 'Unknown',
        albumName: t.attributes?.albumName,
        artworkUrl: t.attributes?.artwork?.url?.replace('{w}', '400').replace('{h}', '400'),
        duration: Math.floor((t.attributes?.durationInMillis || 30000) / 1000),
        previewUrl: t.attributes?.previews?.[0]?.url,
      }));
    } catch (e) {
      log('Search failed:', e);
      return [];
    }
  };

  // Play tracks using MusicKit's native player (full songs, auto-advance, Safari compatible)
  const playWithMusicKit = useCallback(async (tracks: Track[]) => {
    if (!music || !music.isAuthorized || tracks.length === 0) {
      log('Cannot use MusicKit playback, falling back');
      return;
    }

    log('Setting MusicKit queue with', tracks.length, 'tracks');

    // Store track metadata for the nowPlayingItemDidChange handler
    trackMapRef.current.clear();
    tracks.forEach(t => trackMapRef.current.set(t.id, t));

    try {
      await music.setQueue({ songs: tracks.map(t => t.id) });
      log('Queue set, starting playback...');
      await music.play();
      log('MusicKit playback started');
      store.getState().setUsingMusicKit(true);
    } catch (e) {
      log('MusicKit playback failed:', e);
      store.getState().setUsingMusicKit(false);
      throw e;
    }
  }, [music]);

  const musicKitPlay = useCallback(async () => {
    if (music) {
      try { await music.play(); } catch (e) { log('play failed:', e); }
    }
  }, [music]);

  const musicKitPause = useCallback(() => {
    if (music) music.pause();
  }, [music]);

  const musicKitSkip = useCallback(async () => {
    if (music) {
      try { await music.skipToNextItem(); } catch (e) { log('skip failed:', e); }
    }
  }, [music]);

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
        await playWithMusicKit(tracks);
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
      playWithMusicKit, musicKitPlay, musicKitPause, musicKitSkip, musicKitProgress,
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
