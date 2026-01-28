'use client';

import { createContext, useContext, useEffect, useState, ReactNode } from 'react';
import { useRadioStore } from '@/lib/store/radio';

interface AppleMusicUser {
  name: string;
  email: string;
  id: string;
}

interface AppleMusicTrack {
  id: string;
  title: string;
  artistName: string;
  albumName: string;
  artwork: { url: string };
  durationInMillis: number;
  previewUrl?: string;
  playParams?: { catalogId: string };
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

// Apple Music developer token generator (simplified - use MusicKit for production)
function generateDeveloperToken(): string {
  const keyId = process.env.NEXT_PUBLIC_APPLE_MUSIC_KEY_ID;
  const teamId = process.env.NEXT_PUBLIC_APPLE_MUSIC_TEAM_ID;
  const secretKey = process.env.APPLE_MUSIC_PRIVATE_KEY;
  
  // In production, use MusicKit JS for authentication
  // This is a placeholder for the token generation logic
  return '';
}

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<AppleMusicUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<AppleMusicPlaylist[]>([]);
  const [musicKit, setMusicKit] = useState<any>(null);

  // Initialize MusicKit
  useEffect(() => {
    const initMusicKit = async () => {
      if ((window as any).MusicKit) {
        const mk = (window as any).MusicKit;
        
        // Configure MusicKit
        mk.configure({
          developerToken: generateDeveloperToken(),
          app: {
            name: 'RAY.DO',
            build: '1.0.0',
          },
        });

        // Check for existing session
        const musicUserToken = await mk.getMusicUserToken();
        if (musicUserToken) {
          const userInfo = await mk.api.userInformation();
          setUser({
            name: userInfo.attributes?.name || 'Apple Music User',
            email: userInfo.attributes?.email || '',
            id: userInfo.id,
          });
          setPlaylists(await mk.api.userPlaylists());
        }

        setMusicKit(mk);
      }
    };

    // Load MusicKit script
    const script = document.createElement('script');
    script.src = 'https://assets.applemusickit.com/apple-musickit.js';
    script.onload = initMusicKit;
    document.head.appendChild(script);

    return () => {
      if (musicKit) {
        musicKit.unconfigure();
      }
    };
  }, []);

  const connectAppleMusic = async () => {
    if (!musicKit) {
      alert('Apple Music not configured. Add your developer credentials.');
      return;
    }

    setIsLoading(true);
    try {
      // MusicKit handles the OAuth flow
      await musicKit.authorize();
      
      // Get user info
      const userInfo = await musicKit.api.userInformation();
      setUser({
        name: userInfo.attributes?.name || 'Apple Music User',
        email: userInfo.attributes?.email || '',
        id: userInfo.id,
      });

      // Get playlists
      const userPlaylists = await musicKit.api.userPlaylists();
      setPlaylists(userPlaylists.map((p: any) => ({
        id: p.id,
        name: p.attributes.name,
        description: p.attributes.description,
        artwork: p.attributes.artwork,
        trackCount: p.attributes.trackCount,
      })));
    } catch (e) {
      console.error('Apple Music auth failed:', e);
    } finally {
      setIsLoading(false);
    }
  };

  const disconnect = () => {
    if (musicKit) {
      musicKit.unauthorize();
    }
    setUser(null);
    setPlaylists([]);
  };

  const createRadioStation = async (mood: 'chill' | 'hype' | 'balanced') => {
    if (!musicKit) {
      connectAppleMusic();
      return;
    }

    setIsLoading(true);
    
    try {
      // Create station based on mood
      const genreMappings = {
        chill: ['chill', 'lo-fi', 'ambient', 'jazz'],
        hype: ['hip-hop', 'electronic', 'pop', 'dance'],
        balanced: ['pop', 'rock', 'indie', 'acoustic'],
      };

      const genres = genreMappings[mood];
      
      // Get recommendations from Apple Music
      const recommendations = await musicKit.api.recommendations({
        types: ['songs'],
        'genre-names': [genres[0]],
        limit: 20,
      });

      const tracks = recommendations[0]?.contents || [];
      
      // Convert to our format
      const radioTracks = tracks.map((t: any) => ({
        id: t.id,
        title: t.attributes.name,
        artistName: t.attributes.artistName,
        albumName: t.attributes.albumName,
        artworkUrl: t.attributes.artwork?.url?.replace('{w}', '200').replace('{h}', '200'),
        duration: Math.floor(t.attributes.durationInMillis / 1000),
        previewUrl: t.attributes.previewUrl,
        appleMusicId: t.attributes.playParams?.catalogId,
      }));

      setQueue(radioTracks);
      setCurrentTrack(radioTracks[0]);
      setIsPlaying(true);
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
