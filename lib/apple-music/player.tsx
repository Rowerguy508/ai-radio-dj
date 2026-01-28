'use client';

import { createContext, useContext, useEffect, useState, ReactNode, useCallback, useRef } from 'react';
import { useRadioStore } from '@/lib/store/radio';

interface AppleMusicUser {
  name: string;
  email: string;
  id: string;
}

interface AppleMusicContextType {
  user: AppleMusicUser | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  error: string | null;
  playlists: any[];
  connectAppleMusic: () => Promise<void>;
  disconnect: () => void;
  createRadioStation: (mood: 'chill' | 'hype' | 'balanced') => Promise<void>;
  play: () => Promise<void>;
  pause: () => void;
  skip: () => void;
}

const AppleMusicContext = createContext<AppleMusicContextType | null>(null);

declare global {
  interface Window {
    MusicKit: any;
  }
}

export function AppleMusicProvider({ children }: { children: ReactNode }) {
  const { setQueue, setCurrentTrack, setIsPlaying, currentStation } = useRadioStore();
  const [user, setUser] = useState<AppleMusicUser | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [playlists, setPlaylists] = useState<any[]>([]);
  const [mk, setMk] = useState<any>(null);
  const [skipCount, setSkipCount] = useState(0);
  const [lastSongId, setLastSongId] = useState<string | null>(null);
  const [commentaryEnabled, setCommentaryEnabled] = useState(true);
  const commentaryAudioRef = useRef<HTMLAudioElement | null>(null);
  const isPlayingRef = useRef(false);
  
  // Skip feedback loop - store skipped song IDs
  const skippedSongsRef = useRef<Set<string>>(new Set());
  
  // Load skipped songs from localStorage
  useEffect(() => {
    if (typeof window !== 'undefined') {
      try {
        const saved = localStorage.getItem('raydo_skipped_songs');
        if (saved) {
          const parsed = JSON.parse(saved);
          skippedSongsRef.current = new Set(parsed);
        }
      } catch (e) {
        console.log('Failed to load skip history');
      }
    }
  }, []);
  
  // Save skipped songs to localStorage
  const saveSkipHistory = useCallback(() => {
    if (typeof window !== 'undefined') {
      try {
        localStorage.setItem('raydo_skipped_songs', JSON.stringify(Array.from(skippedSongsRef.current)));
      } catch (e) {
        console.log('Failed to save skip history');
      }
    }
  }, []);

  // Initialize MusicKit
  useEffect(() => {
    const token = process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN;
    
    if (!token || token.startsWith('your_') || token.length < 100) {
      console.log('No valid Apple Music token');
      return;
    }

    if (!window.MusicKit) {
      const script = document.createElement('script');
      script.src = 'https://js-cdn.music.apple.com/musickit/v3/musickit.js';
      script.async = true;
      script.onload = async () => {
        try {
          const MusicKit = window.MusicKit;
          await MusicKit.configure({
            developerToken: token,
            app: { name: 'RAY.DO', build: '1.0.0' },
          });
          const instance = MusicKit.getInstance();
          setMk(instance);
          
          // Handle play/pause state changes
          instance.addEventListener('playbackStateDidChange', (state: string) => {
            console.log('MusicKit playback state:', state);
            isPlayingRef.current = state === 'playing';
            setIsPlaying(state === 'playing');
            
            // Auto-skip to next song if current ended
            if (state === 'ended' || state === 'completed') {
              handleAutoSkip();
            }
          });
          
          // Track skips from Player component
          if (typeof window !== 'undefined') {
            window.addEventListener('raydo:skip', () => {
              setSkipCount(prev => {
                const newCount = prev + 1;
                console.log('Skip tracked, count:', newCount);
                
                // Track which song was skipped
                if (instance.nowPlayingItem?.id) {
                  skippedSongsRef.current.add(instance.nowPlayingItem.id);
                  saveSkipHistory();
                  console.log('Skipped song ID:', instance.nowPlayingItem.id);
                }
                
                return newCount;
              });
            });
          }
          
          // Listen for song changes
          instance.addEventListener('nowPlayingItemDidChange', async (item: any) => {
            if (item) {
              console.log('Song changed:', item.title, 'by', item.artistName);
              setCurrentTrack({
                id: item.id,
                title: item.title,
                artistName: item.artistName,
                artworkUrl: item.artworkURL,
                duration: item.duration,
              });
              
              // Maybe play commentary after song starts (50% chance)
              if (commentaryEnabled && Math.random() > 0.5) {
                await playCommentary();
              }
            }
          });
          
          console.log('MusicKit initialized');
        } catch (e) {
          console.log('MusicKit configure failed:', e);
        }
      };
      document.head.appendChild(script);
    } else {
      const MusicKit = window.MusicKit;
      MusicKit.configure({
        developerToken: token,
        app: { name: 'RAY.DO', build: '1.0.0' },
      }).then(() => {
        const instance = MusicKit.getInstance();
        setMk(instance);
        console.log('MusicKit ready (cached)');
      });
    }
    
    return () => {
      if (commentaryAudioRef.current) {
        commentaryAudioRef.current.pause();
      }
    };
  }, []);

  // Auto-skip when song ends
  const handleAutoSkip = useCallback(() => {
    const music = mk || (window.MusicKit && window.MusicKit.getInstance());
    if (music && typeof (music as any).skipToNext === 'function') {
      console.log('Auto-skipping to next song...');
      (music as any).skipToNext();
    }
  }, [mk]);

  // Play AI commentary
  const playCommentary = useCallback(async () => {
    const elevenLabsKey = process.env.ELEVENLABS_API_KEY;
    if (!elevenLabsKey || elevenLabsKey.startsWith('your_')) return;
    
    // Don't interrupt music playback - commentary only plays between songs
    if (isPlayingRef.current && !commentaryAudioRef.current?.paused) return;

    // Get voice from station or use default
    const voiceId = currentStation?.voiceId || '21m00Tcm4TlvDq8ikWAM'; // Default to Alex
    
    const hour = new Date().getHours();
    let timeGreeting = '';
    if (hour >= 5 && hour < 12) timeGreeting = 'Good morning! ';
    else if (hour >= 12 && hour < 17) timeGreeting = 'Good afternoon! ';
    else if (hour >= 17 && hour < 21) timeGreeting = 'Good evening! ';
    else timeGreeting = 'Late night vibes! ';
    
    const comments = [
      timeGreeting + "Here's another track for you.",
      timeGreeting + "This one fits the vibe perfectly.",
      timeGreeting + "Keep the good vibes going.",
      timeGreeting + "Another favorite coming up.",
      "You're listening to RAY.DO.",
      "More great music coming up.",
      "This track is a perfect match for your mood.",
    ];
    
    const text = comments[Math.floor(Math.random() * comments.length)];
    
    try {
      console.log('Playing AI commentary:', text, 'with voice:', voiceId);
      const ttsResponse = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'xi-api-key': elevenLabsKey,
        },
        body: JSON.stringify({
          text,
          model_id: 'eleven_monolingual_v1',
          voice_settings: { stability: 0.5, similarity_boost: 0.75 }
        })
      });
      
      if (ttsResponse.ok) {
        const audioBlob = await ttsResponse.blob();
        const audioUrl = URL.createObjectURL(audioBlob);
        
        if (commentaryAudioRef.current) {
          commentaryAudioRef.current.pause();
        }
        
        commentaryAudioRef.current = new Audio(audioUrl);
        await commentaryAudioRef.current.play();
        console.log('AI commentary playing');
      }
    } catch (e) {
      console.log('Commentary failed:', e);
    }
  }, [commentaryEnabled]);

  // Play function
  const play = useCallback(async () => {
    const music = mk || (window.MusicKit && window.MusicKit.getInstance());
    if (music) {
      try {
        await music.play();
        isPlayingRef.current = true;
        setIsPlaying(true);
        console.log('MusicKit play');
      } catch (e) {
        console.log('Play failed:', e);
      }
    }
  }, [mk]);

  // Pause function
  const pause = useCallback(() => {
    const music = mk || (window.MusicKit && window.MusicKit.getInstance());
    if (music) {
      try {
        music.pause();
        isPlayingRef.current = false;
        setIsPlaying(false);
        console.log('MusicKit pause');
      } catch (e) {
        console.log('Pause failed:', e);
      }
    }
  }, [mk]);

  // Skip function
  const skip = useCallback(() => {
    // Dispatch skip event
    if (typeof window !== 'undefined') {
      window.dispatchEvent(new CustomEvent('raydo:skip'));
    }
    
    const music = mk || (window.MusicKit && window.MusicKit.getInstance());
    if (music) {
      if (typeof (music as any).skipToNext === 'function') {
        (music as any).skipToNext();
      } else if (music.player && typeof music.player.skipToNextItem === 'function') {
        music.player.skipToNextItem();
      }
      console.log('MusicKit skip');
    }
  }, [mk]);

  const connectAppleMusic = async () => {
    if (!mk) {
      setError('Initializing...');
      return;
    }
    
    setIsLoading(true);
    try {
      await mk.authorize();
      setUser({ name: 'Apple Music User', email: '', id: '' });
    } catch (e: any) {
      setError('Auth failed: ' + e.message);
    } finally {
      setIsLoading(false);
    }
  };

  const disconnect = () => {
    if (mk) mk.unauthorize();
    setUser(null);
    setPlaylists([]);
    setSkipCount(0);
  };

  // Weighted shuffle - popular tracks more likely to play, skipped songs deprioritized
  const weightedShuffle = <T extends { id: string; attributes?: { durationInMillis?: number; releaseDate?: string } }>(array: T[]): T[] => {
    const arr = [...array];
    
    // Calculate weights based on track duration (shorter = slightly more weight for variety)
    // and recency if release date available
    const weights = arr.map((track) => {
      let weight = 1;
      
      // Penalize skipped songs heavily
      if (skippedSongsRef.current.has(track.id)) {
        weight *= 0.1; // 90% reduction for skipped songs
      }
      
      // Slight boost for shorter tracks (3-4 min sweet spot)
      const duration = track.attributes?.durationInMillis || 180000;
      const minutes = duration / 60000;
      if (minutes >= 3 && minutes <= 4) weight *= 1.2;
      else if (minutes < 3) weight *= 1.1;
      else if (minutes > 5) weight *= 0.8;
      
      // Add randomness
      weight *= (0.6 + Math.random() * 0.8);
      
      return { item: track, weight, originalIndex: arr.indexOf(track) };
    });
    
    // Sort by weight (descending) then shuffle
    weights.sort((a, b) => b.weight - a.weight);
    
    // Fisher-Yates shuffle with weight consideration
    for (let i = weights.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [weights[i], weights[j]] = [weights[j], weights[i]];
    }
    
    return weights.map(w => w.item);
  };

  // Simple shuffle for fallback
  const simpleShuffle = <T,>(array: T[]): T[] => {
    const arr = [...array];
    for (let i = arr.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [arr[i], arr[j]] = [arr[j], arr[i]];
    }
    return arr;
  };

  const createRadioStation = async (mood: 'chill' | 'hype' | 'balanced') => {
    const music = mk || (window.MusicKit && window.MusicKit.getInstance());
    
    if (!music) {
      setError('Apple Music not ready');
      return;
    }
    
    // Ensure authorized
    if (!music.isAuthorized) {
      try {
        await music.authorize();
      } catch (e: any) {
        setError('Auth failed: ' + e.message);
        return;
      }
    }
    
    if (!music.musicUserToken) {
      console.log('No musicUserToken');
      return;
    }
    
    setIsLoading(true);
    setError(null);
    setSkipCount(0);
    
    const genres: Record<string, string[]> = {
      chill: ['chill', 'lo-fi', 'ambient', 'acoustic'],
      hype: ['hip-hop', 'electronic', 'dance', 'trap'],
      balanced: ['pop', 'rock', 'indie', 'alternative'],
    };
    
    const genreList = genres[mood];
    console.log('Fetching songs from genres:', genreList);
    
    const token = process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN;
    const elevenLabsKey = process.env.ELEVENLABS_API_KEY;
    
    try {
      let allTracks: any[] = [];
      
      // Fetch from each genre
      for (const genre of genreList) {
        const response = await fetch(
          `https://api.music.apple.com/v1/catalog/us/search?term=${encodeURIComponent(genre)}&types=songs&limit=20`,
          {
            headers: {
              'Authorization': `Bearer ${token}`,
              'Music-User-Token': music.musicUserToken
            }
          }
        );
        
        if (response.ok) {
          const data = await response.json();
          const tracks = data?.results?.songs?.data || [];
          allTracks = [...allTracks, ...tracks];
        }
      }
      
      // Remove duplicates
      const uniqueTracks = allTracks.filter((track, index, self) =>
        index === self.findIndex((t) => t.id === track.id)
      );
      
      // Shuffle
      const shuffledTracks = weightedShuffle(uniqueTracks);
      
      console.log(`Found ${shuffledTracks.length} unique tracks`);
      
      if (shuffledTracks.length > 0) {
        const songIds = shuffledTracks.map((t: any) => t.id);
        
        // Update UI
        const uiTracks = shuffledTracks.map((t: any) => ({
          id: t.id,
          title: t.attributes.name,
          artistName: t.attributes.artistName,
          artworkUrl: t.attributes.artwork?.url?.replace('{w}', '200').replace('{h}', '200'),
          duration: Math.floor(t.attributes.durationInMillis / 1000),
          previewUrl: t.attributes.previewUrl,
        }));
        
        setQueue(uiTracks);
        setCurrentTrack(uiTracks[0]);
        
        // Play opening commentary
        if (elevenLabsKey && !elevenLabsKey.startsWith('your_')) {
          const vibeDescriptions: Record<string, string> = {
            chill: "Welcome to your chill zone. Smooth vibes, laid-back beats, and ambient sounds to help you unwind. Here's your personalized mix.",
            hype: "Turn it up! High-energy tracks, bangers, and beats that'll keep you moving. Your hype mix is ready.",
            balanced: "The perfect mix of pop hits, rock anthems, and indie gems. Something for everyone, never boring. Enjoy!",
          };
          
          const voiceId = currentStation?.voiceId || '21m00Tcm4TlvDq8ikWAM';
          
          try {
            console.log('Playing intro commentary...');
            const ttsResponse = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`, {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
                'xi-api-key': elevenLabsKey,
              },
              body: JSON.stringify({
                text: vibeDescriptions[mood],
                model_id: 'eleven_monolingual_v1',
                voice_settings: { stability: 0.5, similarity_boost: 0.75 }
              })
            });
            
            if (ttsResponse.ok) {
              const audioBlob = await ttsResponse.blob();
              const audioUrl = URL.createObjectURL(audioBlob);
              
              // Play intro
              commentaryAudioRef.current = new Audio(audioUrl);
              await commentaryAudioRef.current.play();
              
              // When intro ends, start music
              commentaryAudioRef.current.onended = async () => {
                console.log('Intro ended, starting music...');
                await music.setQueue({ songs: songIds });
                await music.play();
                isPlayingRef.current = true;
                setIsPlaying(true);
              };
              
              setIsLoading(false);
              return;
            }
          } catch (ttsError) {
            console.log('ElevenLabs TTS failed:', ttsError);
          }
        }
        
        // No commentary - just play
        await music.setQueue({ songs: songIds });
        await music.play();
        isPlayingRef.current = true;
        setIsPlaying(true);
        console.log('Playing shuffled queue');
        setIsLoading(false);
        return;
      }
      
      console.log('No tracks found');
      
    } catch (e: any) {
      console.error('Apple Music error:', e);
    }
    
    // Fallback
    setIsLoading(false);
  };

  return (
    <AppleMusicContext.Provider 
      value={{ 
        user, 
        isAuthenticated: !!user, 
        isLoading, 
        error, 
        playlists, 
        connectAppleMusic, 
        disconnect, 
        createRadioStation,
        play,
        pause,
        skip,
      }}
    >
      {children}
    </AppleMusicContext.Provider>
  );
}

export function useAppleMusic() {
  const ctx = useContext(AppleMusicContext);
  if (!ctx) throw new Error('useAppleMusic requires provider');
  return ctx;
}
