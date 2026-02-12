'use client';

import { createContext, useContext, useEffect, useState, ReactNode, useCallback } from 'react';
import { useRadioStore, Track } from '@/lib/store/radio';

interface AppleMusicUser {
  name: string;
  email: string;
  id: string;
}

interface AppleMusicTrack {
  id: string;
  attributes: {
    name: string;
    artistName: string;
    albumName: string;
    artwork: { url: string };
    durationInMillis: number;
    previews?: { url: string }[];
  };
}

interface AppleMusicPlaylist {
  id: string;
  attributes: {
    name: string;
    description?: { standard: string };
    artwork?: { url: string };
  };
  relationships?: {
    tracks?: { data: AppleMusicTrack[] };
  };
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

// Genre mappings for different moods
const MOOD_GENRES: Record<'chill' | 'hype' | 'balanced', string[]> = {
  chill: ['chill', 'ambient', 'acoustic', 'lo-fi', 'jazz'],
  hype: ['hip-hop', 'electronic', 'rock', 'pop', 'dance'],
  balanced: ['indie', 'pop', 'alternative', 'r&b', 'soul'],
};

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying } = useRadioStore();
  const [user, setUser] = useState<AppleMusicUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [playlists, setPlaylists] = useState<AppleMusicPlaylist[]>([]);
  const [musicKit, setMusicKit] = useState<any>(null);
  const [isConfigured, setIsConfigured] = useState(false);

  // Initialize MusicKit when window loads
  useEffect(() => {
    const initMusicKit = async () => {
      if (typeof window === 'undefined' || !window.MusicKit) {
        // MusicKit not loaded yet, wait for it
        const checkMusicKit = setInterval(() => {
          if (window.MusicKit) {
            clearInterval(checkMusicKit);
            configureMusicKit();
          }
        }, 100);
        
        // Stop checking after 10 seconds
        setTimeout(() => clearInterval(checkMusicKit), 10000);
        return;
      }
      
      await configureMusicKit();
    };

    const configureMusicKit = async () => {
      try {
        const developerToken = process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN;
        
        if (!developerToken) {
          console.warn('Apple Music developer token not configured');
          return;
        }

        await window.MusicKit.configure({
          developerToken,
          app: {
            name: 'AI Radio DJ',
            build: '1.0.0',
          },
        });

        const instance = window.MusicKit.getInstance();
        setMusicKit(instance);
        setIsConfigured(true);

        // Check if already authorized
        if (instance.isAuthorized) {
          await fetchUserData(instance);
        }
      } catch (error) {
        console.error('Error configuring MusicKit:', error);
      }
    };

    initMusicKit();
  }, []);

  const fetchUserData = async (instance: any) => {
    try {
      // MusicKit doesn't provide direct user profile access
      // Set a generic user when authorized
      setUser({
        id: 'apple-music-user',
        name: 'Apple Music User',
        email: '',
      });
      
      // Fetch user's library playlists
      const playlistsResponse = await instance.api.music('/v1/me/library/playlists');
      if (playlistsResponse?.data?.data) {
        setPlaylists(playlistsResponse.data.data);
      }
    } catch (error) {
      console.error('Error fetching user data:', error);
    }
  };

  const connectAppleMusic = useCallback(async () => {
    if (!musicKit || !isConfigured) {
      console.error('MusicKit not configured. Make sure NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN is set.');
      return;
    }

    try {
      setIsLoading(true);
      await musicKit.authorize();
      await fetchUserData(musicKit);
    } catch (error) {
      console.error('Error connecting to Apple Music:', error);
    } finally {
      setIsLoading(false);
    }
  }, [musicKit, isConfigured]);

  const disconnect = useCallback(() => {
    if (musicKit) {
      musicKit.unauthorize();
    }
    setUser(null);
    setPlaylists([]);
  }, [musicKit]);

  const createRadioStation = useCallback(async (mood: 'chill' | 'hype' | 'balanced') => {
    if (!musicKit || !musicKit.isAuthorized) {
      console.error('Not authorized with Apple Music');
      return;
    }

    setIsLoading(true);
    try {
      const genres = MOOD_GENRES[mood];
      const searchTerm = genres[Math.floor(Math.random() * genres.length)];
      
      // Search for tracks matching the mood
      const searchResponse = await musicKit.api.music(`/v1/catalog/us/search`, {
        term: searchTerm,
        types: ['songs'],
        limit: 25,
      });

      const songs = searchResponse?.data?.results?.songs?.data || [];
      
      if (songs.length === 0) {
        console.log('No songs found for mood:', mood);
        return;
      }

      // Convert to radio store format
      const tracks: Track[] = songs
        .filter((song: AppleMusicTrack) => song.attributes.previews?.[0]?.url)
        .map((song: AppleMusicTrack) => ({
          id: song.id,
          title: song.attributes.name,
          artistName: song.attributes.artistName,
          albumName: song.attributes.albumName,
          artworkUrl: song.attributes.artwork?.url?.replace('{w}', '300').replace('{h}', '300'),
          duration: Math.floor(song.attributes.durationInMillis / 1000),
          previewUrl: song.attributes.previews?.[0]?.url,
        }));

      if (tracks.length > 0) {
        // Shuffle tracks
        const shuffled = tracks.sort(() => Math.random() - 0.5);
        setQueue(shuffled);
        setCurrentTrack(shuffled[0]);
        setIsPlaying(true);
      }
    } catch (error) {
      console.error('Error creating radio station:', error);
    } finally {
      setIsLoading(false);
    }
  }, [musicKit, setQueue, setCurrentTrack, setIsPlaying]);

  const contextValue: AppleMusicContextType = {
    user,
    isAuthenticated: !!user && musicKit?.isAuthorized,
    isLoading,
    playlists,
    connectAppleMusic,
    disconnect,
    createRadioStation,
  };

  return (
    <AppleMusicContext.Provider value={contextValue}>
      {children}
    </AppleMusicContext.Provider>
  );
}

export function useAppleMusic() {
  const context = useContext(AppleMusicContext);
  if (!context) {
    throw new Error('useAppleMusic must be used within an AppleMusicProvider');
  }
  return context;
}

// Add MusicKit types to window
declare global {
  interface Window {
    MusicKit: any;
  }
}
