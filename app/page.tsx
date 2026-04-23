'use client';

import { useState, useEffect } from 'react';
import { Settings2, Radio, Mic, MicOff, Plus, Trash2, Pencil } from 'lucide-react';
import { Player } from './components/Player';
import { Settings } from './components/Settings';
import { StationEditor } from './components/StationEditor';
import { useRadioStore, Station, createDefaultStation, Track } from '@/lib/store/radio';
import { AppleMusicProvider, useAppleMusic } from '@/lib/apple-music/player';
import { SpotifyProvider, useSpotify } from '@/lib/spotify/player';

type MusicSource = 'none' | 'apple-music' | 'spotify';

const DEMO_TRACKS: Track[] = [
  { id: 'd1', title: 'Llama Whippin Intro', artistName: 'DJ Llama', albumName: 'Demo', duration: 180, artworkUrl: 'https://picsum.photos/seed/d1/400', previewUrl: 'https://cdn.jsdelivr.net/gh/captbaritone/webamp@43434d82cfe0e37286dbbe0666072dc3190a83bc/mp3/llama-2.91.mp3' },
  { id: 'd2', title: 'Bloibb FX', artistName: 'cfork', albumName: 'Demo', duration: 15, artworkUrl: 'https://picsum.photos/seed/d2/400', previewUrl: 'https://cdn.jsdelivr.net/npm/test-audio@2.1.0/audio/8000__cfork__cf-fx-bloibb.mp3' },
  { id: 'd3', title: 'Drips', artistName: 'smcameron', albumName: 'Demo', duration: 10, artworkUrl: 'https://picsum.photos/seed/d3/400', previewUrl: 'https://cdn.jsdelivr.net/npm/test-audio@2.1.0/audio/50775__smcameron__drips2.ogg' },
];

function HomeContent() {
  const {
    toggleSettings, isPlaying, currentTrack, currentStation, commentaryEnabled, toggleCommentary,
    setCurrentStation, setCurrentTrack, setIsPlaying, setQueue, stations, addStation,
    openStationEditor, removeStation, setDjIntroPlayed,
  } = useRadioStore();

  const appleMusic = useAppleMusic();
  const spotify = useSpotify();

  const [musicSource, setMusicSource] = useState<MusicSource>('none');
  const [ready, setReady] = useState(false);
  const [loadingStation, setLoadingStation] = useState<string | null>(null);

  useEffect(() => {
    const saved = localStorage.getItem('raydo-music-source') as MusicSource;
    if (saved && saved !== 'none') setMusicSource(saved);
    setReady(true);
  }, []);

  const selectSource = (s: MusicSource) => {
    setMusicSource(s);
    localStorage.setItem('raydo-music-source', s);
  };

  // Clean multi-line/descriptive search input into simple search terms
  const parseSearchTerms = (raw: string): string[] => {
    const lines = raw.split('\n')
      .map(l => l.replace(/\(.*?\)/g, '').replace(/[“”””“”‘’]/g, '').trim())
      .filter(l => l.length > 1 && !/^[-–—•*]$/.test(l));
    return lines.length > 0 ? lines : [raw.trim()];
  };

  // Shuffle array in-place (Fisher-Yates)
  const shuffle = <T,>(arr: T[]): T[] => {
    for (let i = arr.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [arr[i], arr[j]] = [arr[j], arr[i]];
    }
    return arr;
  };

  // Play a station: search for tracks using the connected music source
  const playStation = async (station: Station) => {
    setLoadingStation(station.id);
    setCurrentStation(station);
    setDjIntroPlayed(false);

    const styleTerms: Record<string, string> = { chill: 'chill relaxing', hype: 'upbeat energy', balanced: 'popular hits' };
    const raw = station.searchQuery || styleTerms[station.style] || 'music';
    const terms = shuffle(parseSearchTerms(raw));

    let tracks: Track[] = [];

    if (musicSource === 'apple-music' && appleMusic.music) {
      // Try multiple terms until we get results, combine for variety
      const seen = new Set<string>();
      for (const term of terms.slice(0, 4)) {
        const results = await appleMusic.searchTracks(term, 25);
        for (const t of results) {
          if (t.previewUrl && !seen.has(t.id)) {
            seen.add(t.id);
            tracks.push(t);
          }
        }
        if (tracks.length >= 20) break;
      }
      shuffle(tracks);
    }
    // TODO: Add Spotify searchTracks similarly

    if (tracks.length === 0) {
      console.log('No playable tracks found, using demo tracks. musicSource:', musicSource, 'appleMusicReady:', !!appleMusic.music);
      tracks = DEMO_TRACKS;
    }

    setQueue(tracks.slice(1));
    setCurrentTrack(tracks[0]);
    setIsPlaying(true);
    setLoadingStation(null);
  };

  if (!ready) return <div className="min-h-screen bg-black" />;

  const hasStations = stations.length > 0;

  return (
    <div className="min-h-[100dvh] bg-black text-white">
      {/* Header */}
      <header className="flex items-center justify-between px-5 sm:px-8 py-4">
        <div className="flex items-center gap-2.5">
          <div className="w-9 h-9 rounded-xl bg-gradient-to-br from-violet-500 to-fuchsia-500 flex items-center justify-center shadow-lg shadow-violet-500/20">
            <Radio size={16} />
          </div>
          <div>
            <span className="text-lg font-bold tracking-tight">RAY.DO</span>
            <span className="hidden sm:inline text-zinc-600 text-sm ml-2">AI Radio DJ</span>
          </div>
        </div>
        <div className="flex items-center gap-1">
          <button onClick={toggleCommentary} className={`p-2.5 rounded-xl transition-colors ${commentaryEnabled ? 'text-violet-400 bg-violet-500/10' : 'text-zinc-600'}`}>
            {commentaryEnabled ? <Mic size={18} /> : <MicOff size={18} />}
          </button>
          <button onClick={toggleSettings} className="p-2.5 text-zinc-400 hover:text-white rounded-xl transition-colors">
            <Settings2 size={18} />
          </button>
        </div>
      </header>

      <main className="px-5 sm:px-8 pb-40 max-w-6xl mx-auto">
        <div className="lg:grid lg:grid-cols-[1fr_340px] lg:gap-10">
          {/* Left column */}
          <div>
            {/* Now Playing */}
            {currentTrack ? (
              <section className="mb-8">
                <div className="rounded-2xl overflow-hidden bg-gradient-to-br from-zinc-900 to-zinc-950 border border-white/5">
                  <div className="p-5 sm:p-6 flex items-start gap-5">
                    {currentTrack.artworkUrl ? (
                      <img src={currentTrack.artworkUrl} alt="" className="w-20 h-20 sm:w-28 sm:h-28 rounded-xl object-cover flex-shrink-0 shadow-2xl" />
                    ) : (
                      <div className="w-20 h-20 sm:w-28 sm:h-28 rounded-xl bg-zinc-800 flex items-center justify-center flex-shrink-0">
                        <Radio size={28} className="text-zinc-700" />
                      </div>
                    )}
                    <div className="min-w-0 pt-1">
                      <p className="text-[11px] text-violet-400 uppercase tracking-widest font-medium mb-1.5">
                        {isPlaying ? 'Now Playing' : 'Paused'}
                      </p>
                      <h2 className="text-xl sm:text-2xl font-bold leading-tight truncate">{currentTrack.title}</h2>
                      <p className="text-zinc-400 text-sm sm:text-base mt-1 truncate">{currentTrack.artistName}</p>
                      {currentStation && (
                        <div className="mt-3 inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-white/5 text-xs text-zinc-400">
                          <Radio size={10} />
                          {currentStation.name}
                        </div>
                      )}
                    </div>
                  </div>
                  {isPlaying && (
                    <div className="h-0.5 bg-zinc-800 overflow-hidden">
                      <div className="h-full bg-gradient-to-r from-violet-500 to-fuchsia-500 animate-pulse" style={{ width: '60%' }} />
                    </div>
                  )}
                </div>
              </section>
            ) : (
              <section className="mb-10 pt-6 sm:pt-10">
                <h1 className="text-3xl sm:text-5xl font-bold tracking-tight leading-tight">
                  Your AI<br />Radio Station
                </h1>
                <p className="text-zinc-500 mt-3 text-sm sm:text-base max-w-md">
                  Create custom stations with your music taste. The AI DJ sets the mood, introduces tracks, and keeps the vibe going.
                </p>
              </section>
            )}

            {/* Saved Stations */}
            <section className="mb-8">
              <div className="flex items-center justify-between mb-4">
                <h3 className="text-xs text-zinc-500 uppercase tracking-widest font-medium">Your Stations</h3>
                <button
                  onClick={() => openStationEditor()}
                  className="flex items-center gap-1.5 text-xs text-violet-400 hover:text-violet-300 transition-colors"
                >
                  <Plus size={14} />
                  New Station
                </button>
              </div>

              {!hasStations ? (
                <button
                  onClick={() => openStationEditor()}
                  className="w-full p-6 rounded-2xl border border-dashed border-zinc-800 hover:border-violet-500/30 text-center transition-all group"
                >
                  <div className="w-12 h-12 rounded-xl bg-zinc-900 mx-auto mb-3 flex items-center justify-center group-hover:bg-violet-500/10 transition-colors">
                    <Plus size={20} className="text-zinc-600 group-hover:text-violet-400" />
                  </div>
                  <p className="text-sm text-zinc-400">Create your first station</p>
                  <p className="text-xs text-zinc-600 mt-1">Pick your music, choose a DJ style</p>
                </button>
              ) : (
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                  {stations.map(station => {
                    const active = currentStation?.id === station.id;
                    const gradients: Record<string, string> = {
                      chill: 'from-sky-500 to-indigo-600',
                      balanced: 'from-violet-500 to-purple-600',
                      hype: 'from-amber-500 to-red-600',
                    };
                    return (
                      <div key={station.id} className={`relative group rounded-2xl transition-all ${active ? 'ring-1 ring-white/20' : ''}`}>
                        <button
                          onClick={() => playStation(station)}
                          disabled={loadingStation === station.id}
                          className="w-full p-4 rounded-2xl text-left bg-zinc-900/60 hover:bg-zinc-800/60 transition-all active:scale-[0.98] disabled:opacity-60"
                        >
                          <div className="flex items-start gap-3">
                            <div className={`w-10 h-10 rounded-xl bg-gradient-to-br ${gradients[station.style] || gradients.balanced} flex items-center justify-center flex-shrink-0 shadow-lg`}>
                              {loadingStation === station.id ? (
                                <div className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                              ) : (
                                <Radio size={14} />
                              )}
                            </div>
                            <div className="min-w-0 flex-1">
                              <p className="text-white text-sm font-semibold truncate">{station.name}</p>
                              <p className="text-zinc-500 text-xs mt-0.5 truncate">
                                {station.searchQuery || `${station.style} vibes`}
                              </p>
                              <p className="text-zinc-600 text-[11px] mt-1">
                                DJ {station.djName} &middot; {station.style} &middot; {Math.round(station.energyLevel * 100)}% energy
                              </p>
                            </div>
                          </div>
                          {active && isPlaying && (
                            <div className="mt-2 flex gap-0.5 items-end h-3">
                              {[1,2,3,4].map(i => (
                                <div key={i} className="w-0.5 bg-violet-400/60 rounded-full animate-pulse" style={{ height: `${6 + Math.random() * 6}px`, animationDelay: `${i * 0.15}s` }} />
                              ))}
                            </div>
                          )}
                        </button>
                        {/* Edit / Delete overlay */}
                        <div className="absolute top-2 right-2 flex gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                          <button onClick={(e) => { e.stopPropagation(); openStationEditor(station); }} className="p-1.5 rounded-lg bg-zinc-800/80 text-zinc-400 hover:text-white">
                            <Pencil size={12} />
                          </button>
                          <button onClick={(e) => { e.stopPropagation(); removeStation(station.id); }} className="p-1.5 rounded-lg bg-zinc-800/80 text-zinc-400 hover:text-red-400">
                            <Trash2 size={12} />
                          </button>
                        </div>
                      </div>
                    );
                  })}
                  {/* Add more button */}
                  <button
                    onClick={() => openStationEditor()}
                    className="p-4 rounded-2xl border border-dashed border-zinc-800 hover:border-violet-500/30 flex items-center justify-center transition-all min-h-[88px]"
                  >
                    <Plus size={18} className="text-zinc-600" />
                  </button>
                </div>
              )}
            </section>
          </div>

          {/* Right column - Music Source */}
          <div>
            <section>
              <h3 className="text-xs text-zinc-500 uppercase tracking-widest font-medium mb-4">Music source</h3>

              {musicSource === 'none' ? (
                <div className="space-y-3">
                  <SourceButton label="Apple Music" desc="Stream from your library" gradient="from-red-500 to-pink-500" onClick={() => selectSource('apple-music')} />
                  <SourceButton label="Spotify" desc="Stream from your library" color="bg-[#1DB954]" onClick={() => selectSource('spotify')} />
                </div>
              ) : (
                <div className="rounded-2xl bg-zinc-900/60 border border-white/5 p-4">
                  <div className="flex items-center justify-between mb-4">
                    <div className="flex items-center gap-3">
                      <div className={`w-8 h-8 rounded-lg flex items-center justify-center ${musicSource === 'spotify' ? 'bg-[#1DB954]' : 'bg-gradient-to-br from-red-500 to-pink-500'}`}>
                        <Radio size={12} className="text-white" />
                      </div>
                      <span className="text-sm text-white font-medium">{musicSource === 'spotify' ? 'Spotify' : 'Apple Music'}</span>
                    </div>
                    <button onClick={() => selectSource('none')} className="text-xs text-zinc-500 hover:text-zinc-300 transition-colors">Change</button>
                  </div>
                  {musicSource === 'apple-music' && <AppleMusicConnect />}
                  {musicSource === 'spotify' && <SpotifyConnect />}
                </div>
              )}
            </section>
          </div>
        </div>
      </main>

      <Player />
      <Settings />
      <StationEditor />
    </div>
  );
}

function SourceButton({ label, desc, gradient, color, onClick }: { label: string; desc: string; gradient?: string; color?: string; onClick: () => void }) {
  return (
    <button onClick={onClick} className="w-full flex items-center gap-4 p-4 rounded-2xl bg-zinc-900/60 hover:bg-zinc-800/60 border border-white/5 transition-all active:scale-[0.98]">
      <div className={`w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0 shadow-lg ${gradient ? `bg-gradient-to-br ${gradient}` : color}`}>
        <Radio size={14} className="text-white" />
      </div>
      <div className="text-left">
        <p className="text-white text-sm font-medium">{label}</p>
        <p className="text-zinc-500 text-xs">{desc}</p>
      </div>
    </button>
  );
}

function AppleMusicConnect() {
  const { isAuthenticated, connectAppleMusic, disconnect, createRadioStation, isLoading } = useAppleMusic();
  const [mood, setMood] = useState<'chill' | 'balanced' | 'hype'>('balanced');
  if (!isAuthenticated) {
    return <button onClick={connectAppleMusic} disabled={isLoading} className="w-full py-3 rounded-xl bg-gradient-to-r from-red-500 to-pink-500 text-white text-sm font-medium active:scale-[0.98] transition-transform disabled:opacity-50">{isLoading ? 'Connecting...' : 'Connect Apple Music'}</button>;
  }
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between text-sm"><span className="text-emerald-400 text-xs font-medium">Connected</span><button onClick={disconnect} className="text-zinc-600 text-xs hover:text-zinc-400">Disconnect</button></div>
      <MoodPicker mood={mood} setMood={setMood} />
      <button onClick={() => createRadioStation(mood)} disabled={isLoading} className="w-full py-2.5 rounded-xl bg-white/5 hover:bg-white/10 text-white text-sm font-medium disabled:opacity-50 transition-colors">{isLoading ? 'Loading...' : 'Start from Apple Music'}</button>
    </div>
  );
}

function SpotifyConnect() {
  const { isAuthenticated, connectSpotify, disconnect, createRadioStation, isLoading } = useSpotify();
  const [mood, setMood] = useState<'chill' | 'balanced' | 'hype'>('balanced');
  if (!isAuthenticated) {
    return <button onClick={connectSpotify} className="w-full py-3 rounded-xl bg-[#1DB954] text-white text-sm font-medium active:scale-[0.98] transition-transform">Connect Spotify</button>;
  }
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between text-sm"><span className="text-emerald-400 text-xs font-medium">Connected</span><button onClick={disconnect} className="text-zinc-600 text-xs hover:text-zinc-400">Disconnect</button></div>
      <MoodPicker mood={mood} setMood={setMood} />
      <button onClick={() => createRadioStation(mood)} disabled={isLoading} className="w-full py-2.5 rounded-xl bg-white/5 hover:bg-white/10 text-white text-sm font-medium disabled:opacity-50 transition-colors">{isLoading ? 'Loading...' : 'Start from Spotify'}</button>
    </div>
  );
}

function MoodPicker({ mood, setMood }: { mood: 'chill' | 'balanced' | 'hype'; setMood: (m: 'chill' | 'balanced' | 'hype') => void }) {
  return (
    <div className="flex gap-1.5 p-1 bg-black/30 rounded-xl">
      {(['chill', 'balanced', 'hype'] as const).map(m => (
        <button key={m} onClick={() => setMood(m)} className={`flex-1 py-1.5 rounded-lg text-xs font-medium transition-all ${mood === m ? 'bg-white text-black shadow-sm' : 'text-zinc-500 hover:text-zinc-300'}`}>
          {m.charAt(0).toUpperCase() + m.slice(1)}
        </button>
      ))}
    </div>
  );
}

export default function Home() {
  return (
    <AppleMusicProvider>
      <SpotifyProvider>
        <HomeContent />
      </SpotifyProvider>
    </AppleMusicProvider>
  );
}
