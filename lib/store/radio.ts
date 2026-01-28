import { create } from 'zustand';

// Types
export interface Track {
  id: string;
  title: string;
  artistName: string;
  albumName?: string;
  artworkUrl?: string;
  duration: number; // seconds
  previewUrl?: string;
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

  // Stations (loaded from cloud)
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

  // Cloud sync actions (call API to persist)
  addStation: (station: Station) => Promise<void>;
  updateStation: (id: string, updates: Partial<Station>) => Promise<void>;
  removeStation: (id: string) => Promise<void>;

  // Voice management
  addVoice: (voice: Voice) => Promise<void>;
  removeVoice: (id: string) => Promise<void>;

  // Cloud sync
  loadFromCloud: (userId: string) => Promise<void>;
}

// Create the store (no local persistence - everything in cloud)
export const useRadioStore = create<RadioState>((set, get) => ({
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

  // Cloud-synced station management
  addStation: async (station) => {
    set((state) => ({ stations: [...state.stations, station] }));
    // TODO: Sync to Supabase
    await fetch('/api/stations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(station),
    });
  },

  updateStation: async (id, updates) => {
    set((state) => ({
      stations: state.stations.map((s) =>
        s.id === id ? { ...s, ...updates } : s
      ),
    }));
    // TODO: Sync to Supabase
    await fetch(`/api/stations/${id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(updates),
    });
  },

  removeStation: async (id) => {
    set((state) => ({
      stations: state.stations.filter((s) => s.id !== id),
    }));
    // TODO: Sync to Supabase
    await fetch(`/api/stations/${id}`, { method: 'DELETE' });
  },

  // Cloud-synced voice management
  addVoice: async (voice) => {
    set((state) => ({ voices: [...state.voices, voice] }));
    await fetch('/api/voices', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(voice),
    });
  },

  removeVoice: async (id) => {
    set((state) => ({
      voices: state.voices.filter((v) => v.id !== id),
    }));
    await fetch(`/api/voices/${id}`, { method: 'DELETE' });
  },

  // Load all data from cloud
  loadFromCloud: async (userId) => {
    const [stationsRes, voicesRes] = await Promise.all([
      fetch(`/api/stations?userId=${userId}`),
      fetch(`/api/voices?userId=${userId}`),
    ]);

    const stations = await stationsRes.json();
    const voices = await voicesRes.json();

    set({ stations: stations.stations || [], voices: voices.voices || [] });
  },
}));

// Selectors
export const useCurrentTrack = () => useRadioStore((state) => state.currentTrack);
export const useIsPlaying = () => useRadioStore((state) => state.isPlaying);
export const useCurrentStation = () => useRadioStore((state) => state.currentStation);
export const useStations = () => useRadioStore((state) => state.stations);
export const useVoices = () => useRadioStore((state) => state.voices);
