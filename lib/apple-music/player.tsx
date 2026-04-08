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

  // Wait for MusicKit to be configured by musickit-init.tsx
  useEffect(() => {
    const initMusicKit = async () => {
      try {
        if (!(window as any).MusicKit) return;
        const mk = (window as any).MusicKit;

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
          // No existing session, that's fine
        }

        setMusicKit(mk);
      } catch (e) {
        console.warn('MusicKit init error:', e);
      }
    };

    // Poll for MusicKit to be ready (configured by musickit-init.tsx)
    const check = () => {
      if ((window as any).MusicKit) {
        initMusicKit();
        return true;
      }
      return false;
    };

    if (!check()) {
      const interval = setInterval(() => {
        if (check()) clearInterval(interval);
      }, 300);
      setTimeout(() => clearInterval(interval), 15000);
    }
  }, []);

  const connectAppleMusic = async () => {
    if (!musicKit) {
      alert('Apple Music not configured. Check your developer token.');
      return;
    }

    setIsLoading(true);
    try {
      await musicKit.authorize();

      setUser({
        name: 'Apple Music User',
        email: '',
        id: 'apple-user',
      });

      // Try to get playlists
      try {
        const userPlaylists = await musicKit.api.userPlaylists();
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

      // Get recommendations from Apple Music (same API as the original working code)
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
