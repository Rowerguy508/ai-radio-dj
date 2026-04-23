import { create } from 'zustand';
import { persist } from 'zustand/middleware';

export interface Track {
  id: string;
  title: string;
  artistName: string;
  albumName?: string;
  artworkUrl?: string;
  duration: number;
  previewUrl?: string;
  spotifyUri?: string;
}

export interface Station {
  id: string;
  name: string;
  description?: string;
  energyLevel: number; // 0-1
  style: 'chill' | 'balanced' | 'hype';
  // Music preferences
  searchQuery: string; // What the user wants to hear (artists, genres, moods)
  // DJ personality
  djName: string;
  djPersonality: string; // Custom personality prompt
  // State
  isActive: boolean;
}

export interface RadioState {
  // Playback
  isPlaying: boolean;
  currentTrack: Track | null;
  currentStation: Station | null;
  queue: Track[];
  volume: number;
  // Whether the DJ intro has played for the current station session
  djIntroPlayed: boolean;

  // Stations (persisted to localStorage)
  stations: Station[];

  // UI
  showSettings: boolean;
  showStationEditor: boolean;
  editingStation: Station | null;
  commentaryEnabled: boolean;

  // Actions
  setCurrentTrack: (track: Track | null) => void;
  setCurrentStation: (station: Station | null) => void;
  setIsPlaying: (playing: boolean) => void;
  setVolume: (volume: number) => void;
  setQueue: (queue: Track[]) => void;
  addToQueue: (track: Track) => void;
  nextTrack: () => void;
  toggleSettings: () => void;
  toggleCommentary: () => void;
  setDjIntroPlayed: (played: boolean) => void;

  // Station editor
  openStationEditor: (station?: Station) => void;
  closeStationEditor: () => void;

  // Station management
  addStation: (station: Station) => void;
  updateStation: (id: string, updates: Partial<Station>) => void;
  removeStation: (id: string) => void;
}

export function createDefaultStation(overrides?: Partial<Station>): Station {
  return {
    id: `station-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
    name: 'My Station',
    description: '',
    energyLevel: 0.5,
    style: 'balanced',
    searchQuery: '',
    djName: 'Ray',
    djPersonality: '',
    isActive: true,
    ...overrides,
  };
}

export const useRadioStore = create<RadioState>()(
  persist(
    (set, get) => ({
      isPlaying: false,
      currentTrack: null,
      currentStation: null,
      queue: [],
      volume: 0.7,
      djIntroPlayed: false,
      stations: [],
      showSettings: false,
      showStationEditor: false,
      editingStation: null,
      commentaryEnabled: true,

      setCurrentTrack: (track) => set({ currentTrack: track }),
      setCurrentStation: (station) => set({ currentStation: station, djIntroPlayed: false }),
      setIsPlaying: (playing) => set({ isPlaying: playing }),
      setVolume: (volume) => set({ volume }),
      setQueue: (queue) => set({ queue }),
      addToQueue: (track) => set((s) => ({ queue: [...s.queue, track] })),
      setDjIntroPlayed: (played) => set({ djIntroPlayed: played }),

      nextTrack: () => {
        const { queue } = get();
        // Skip tracks without a playable URL
        const playable = queue.findIndex(t => t.previewUrl);
        if (playable >= 0) {
          const next = queue[playable];
          const rest = queue.slice(playable + 1);
          set({ currentTrack: next, queue: rest });
        } else {
          set({ isPlaying: false });
        }
      },

      toggleSettings: () => set((s) => ({ showSettings: !s.showSettings })),
      toggleCommentary: () => set((s) => ({ commentaryEnabled: !s.commentaryEnabled })),

      openStationEditor: (station) => set({
        showStationEditor: true,
        editingStation: station || createDefaultStation(),
      }),
      closeStationEditor: () => set({ showStationEditor: false, editingStation: null }),

      addStation: (station) => {
        const { stations } = get();
        const exists = stations.find(s => s.id === station.id);
        if (exists) {
          set({ stations: stations.map(s => s.id === station.id ? station : s) });
        } else {
          set({ stations: [...stations, station] });
        }
      },

      updateStation: (id, updates) => {
        set((s) => ({
          stations: s.stations.map(st => st.id === id ? { ...st, ...updates } : st),
          currentStation: s.currentStation?.id === id ? { ...s.currentStation, ...updates } : s.currentStation,
        }));
      },

      removeStation: (id) => {
        set((s) => ({
          stations: s.stations.filter(st => st.id !== id),
          currentStation: s.currentStation?.id === id ? null : s.currentStation,
        }));
      },
    }),
    {
      name: 'raydo-radio-storage',
      partialize: (state) => ({
        stations: state.stations,
        volume: state.volume,
        commentaryEnabled: state.commentaryEnabled,
      }),
    }
  )
);
