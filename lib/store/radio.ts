import { create } from 'zustand';
import { persist } from 'zustand/middleware';

// Types
export interface Track {
  id: string;
  title: string;
  artistName: string;
  albumName?: string;
  artworkUrl?: string;
  duration: number; // seconds
  previewUrl?: string;
  spotifyUri?: string; // For full playback on Spotify app
}

export interface Station {
  id: string;
  name: string;
  description?: string;
  energyLevel: number; // 0-1
  style: 'chill' | 'balanced' | 'hype';
  voiceId?: string;
  voiceName?: string;
  musicGenres: string[];
  includeMessages: boolean;
  includeCalendar: boolean;
  includeNews: boolean;
  isActive: boolean;
}

export interface Voice {
  id: string;
  name: string;
  voiceId: string;
  style: number; // 0-1
  language: string;
  personality?: string;
}

export interface RadioState {
  // Playback
  isPlaying: boolean;
  currentTrack: Track | null;
  currentStation: Station | null;
  queue: Track[];
  volume: number;
  crossfadeDuration: number;

  // Stations (local storage with optional cloud sync)
  stations: Station[];
  voices: Voice[];

  // UI
  showSettings: boolean;
  showVoiceSelector: boolean;
  commentaryEnabled: boolean;

  // Actions
  setCurrentTrack: (track: Track | null) => void;
  setCurrentStation: (station: Station | null) => void;
  setIsPlaying: (playing: boolean) => void;
  setVolume: (volume: number) => void;
  setCrossfadeDuration: (duration: number) => void;
  setQueue: (queue: Track[]) => void;
  addToQueue: (track: Track) => void;
  nextTrack: () => void;
  toggleSettings: () => void;
  toggleVoiceSelector: () => void;
  toggleCommentary: () => void;

  // Local station management
  addStation: (station: Station) => void;
  updateStation: (id: string, updates: Partial<Station>) => void;
  removeStation: (id: string) => void;

  // Voice management
  addVoice: (voice: Voice) => void;
  removeVoice: (id: string) => void;

  // Cloud sync (optional)
  syncToCloud: (userId: string) => Promise<void>;
  loadFromCloud: (userId: string) => Promise<void>;
}

// Demo user ID for local-first mode
const DEMO_USER_ID = 'demo-user-raydo';

// Create the store with local persistence
export const useRadioStore = create<RadioState>()(
  persist(
    (set, get) => ({
      // Initial state
      isPlaying: false,
      currentTrack: null,
      currentStation: null,
      queue: [],
      volume: 0.7,
      crossfadeDuration: 5,
      stations: [],
      voices: [],
      showSettings: false,
      showVoiceSelector: false,
      commentaryEnabled: true,

      // Actions
      setCurrentTrack: (track) => set({ currentTrack: track }),
      setCurrentStation: (station) => set({ currentStation: station }),
      setIsPlaying: (playing) => set({ isPlaying: playing }),
      setVolume: (volume) => set({ volume }),
      setCrossfadeDuration: (duration) => set({ crossfadeDuration: duration }),
      setQueue: (queue) => set({ queue }),
      addToQueue: (track) =>
        set((state) => ({ queue: [...state.queue, track] })),

      nextTrack: () => {
        const { queue } = get();
        if (queue.length > 0) {
          const [next, ...rest] = queue;
          set({ currentTrack: next, queue: rest });
        }
      },

      toggleSettings: () => set((state) => ({ showSettings: !state.showSettings })),
      toggleVoiceSelector: () =>
        set((state) => ({ showVoiceSelector: !state.showVoiceSelector })),
      toggleCommentary: () =>
        set((state) => ({ commentaryEnabled: !state.commentaryEnabled })),

      // Local station management (no cloud sync needed for basic functionality)
      addStation: (station) => {
        set((state) => ({ stations: [...state.stations, station] }));
      },

      updateStation: (id, updates) => {
        set((state) => ({
          stations: state.stations.map((s) =>
            s.id === id ? { ...s, ...updates } : s
          ),
        }));
      },

      removeStation: (id) => {
        set((state) => ({
          stations: state.stations.filter((s) => s.id !== id),
        }));
      },

      // Voice management
      addVoice: (voice) => {
        set((state) => ({ voices: [...state.voices, voice] }));
      },

      removeVoice: (id) => {
        set((state) => ({
          voices: state.voices.filter((v) => v.id !== id),
        }));
      },

      // Cloud sync (optional - fails silently if Supabase not configured)
      syncToCloud: async (userId: string) => {
        const { stations, voices } = get();
        try {
          await fetch('/api/stations/sync', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ userId, stations, voices }),
          });
        } catch (e) {
          console.warn('Cloud sync skipped (Supabase not configured)');
        }
      },

      loadFromCloud: async (userId: string) => {
        try {
          const [stationsRes, voicesRes] = await Promise.all([
            fetch(`/api/stations?userId=${userId}`),
            fetch(`/api/voices?userId=${userId}`),
          ]);

          if (stationsRes.ok) {
            const stationsData = await stationsRes.json();
            const voicesData = await voicesRes.json();
            set({ stations: stationsData.stations || [], voices: voicesData.voices || [] });
          }
        } catch (e) {
          console.warn('Cloud load skipped (Supabase not configured), using local data');
        }
      },
    }),
    {
      name: 'raydo-radio-storage',
      partialize: (state) => ({
        stations: state.stations,
        voices: state.voices,
        volume: state.volume,
        crossfadeDuration: state.crossfadeDuration,
        commentaryEnabled: state.commentaryEnabled,
      }),
    }
  )
);

// Selectors
export const useCurrentTrack = () => useRadioStore((state) => state.currentTrack);
export const useIsPlaying = () => useRadioStore((state) => state.isPlaying);
export const useCurrentStation = () => useRadioStore((state) => state.currentStation);
export const useStations = () => useRadioStore((state) => state.stations);
export const useVoices = () => useRadioStore((state) => state.voices);
