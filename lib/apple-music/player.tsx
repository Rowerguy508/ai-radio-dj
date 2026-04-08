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

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<AppleMusicUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<AppleMusicPlaylist[]>([]);
  const [musicKit, setMusicKit] = useState<any>(null);

  // Initialize MusicKit: wait for script, configure, check session
  useEffect(() => {
    const initMusicKit = async () => {
      if (!(window as any).MusicKit) return;
      const mk = (window as any).MusicKit;

      try {
        // Configure (safe to call multiple times - MusicKit handles it)
        mk.configure({
          developerToken: process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '',
          app: {
            name: 'RAY.DO',
            build: '1.0.0',
          },
        });
      } catch (e) {
        // Already configured, that's fine
      }

      // Check for existing session
      try {
        const musicUserToken = await mk.getMusicUserToken();
        if (musicUserToken) {
          setUser({
            name: 'Apple Music User',
            email: '',
            id: 'apple-user',
          });
        }
      } catch (e) {
        // No existing session
      }

      setMusicKit(mk);
    };

    // MusicKit script is loaded async in layout.tsx
    // We need to wait for it, then configure
    if ((window as any).MusicKit) {
      initMusicKit();
    } else {
      // Listen for the native MusicKit loaded event
      const onLoaded = () => initMusicKit();
      document.addEventListener('musickitloaded', onLoaded);

      // Also poll as a fallback (some browsers don't fire the event reliably)
      const interval = setInterval(() => {
        if ((window as any).MusicKit) {
          clearInterval(interval);
          initMusicKit();
        }
      }, 500);

      return () => {
        document.removeEventListener('musickitloaded', onLoaded);
        clearInterval(interval);
      };
    }
  }, []);

  const connectAppleMusic = async () => {
    let mk = musicKit;

    // If musicKit isn't set yet, wait for the script to load
    if (!mk) {
      if (!(window as any).MusicKit) {
        // Wait up to 5 seconds for the script
        await new Promise<void>((resolve) => {
          const onLoaded = () => { document.removeEventListener('musickitloaded', onLoaded); resolve(); };
          document.addEventListener('musickitloaded', onLoaded);
          setTimeout(() => { document.removeEventListener('musickitloaded', onLoaded); resolve(); }, 5000);
        });
      }

      if ((window as any).MusicKit) {
        mk = (window as any).MusicKit;
        try {
          mk.configure({
            developerToken: process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '',
            app: { name: 'RAY.DO', build: '1.0.0' },
          });
        } catch {}
        setMusicKit(mk);
      }
    }

    if (!mk) {
      alert('Could not load Apple Music. Check your internet connection and try again.');
      return;
    }

    setIsLoading(true);
    try {
      await mk.authorize();

      setUser({
        name: 'Apple Music User',
        email: '',
        id: 'apple-user',
      });

      try {
        const userPlaylists = await mk.api.userPlaylists();
        setPlaylists(userPlaylists.map((p: any) => ({
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
    if (musicKit) {
      try { musicKit.unauthorize(); } catch {}
    }
    setUser(null);
    setPlaylists([]);
  };

  const createRadioStation = async (mood: 'chill' | 'hype' | 'balanced') => {
    if (!musicKit) {
      await connectAppleMusic();
      return;
    }

    setIsLoading(true);

    try {
      const genreMappings = {
        chill: ['chill', 'lo-fi', 'ambient', 'jazz'],
        hype: ['hip-hop', 'electronic', 'pop', 'dance'],
        balanced: ['pop', 'rock', 'indie', 'acoustic'],
      };

      const genres = genreMappings[mood];

      const recommendations = await musicKit.api.recommendations({
        types: ['songs'],
        'genre-names': [genres[0]],
        limit: 20,
      });

      const tracks = recommendations[0]?.contents || [];

      const radioTracks = tracks.map((t: any) => ({
        id: t.id,
        title: t.attributes.name,
        artistName: t.attributes.artistName,
        albumName: t.attributes.albumName,
        artworkUrl: t.attributes.artwork?.url?.replace('{w}', '200').replace('{h}', '200'),
        duration: Math.floor(t.attributes.durationInMillis / 1000),
        previewUrl: t.attributes.previewUrl,
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
