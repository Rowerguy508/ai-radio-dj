'use client';

import { useState, useEffect } from 'react';
import { Settings2, Radio, Mic, MicOff, Plus, Trash2, Pencil, Music, Headphones, Disc3 } from 'lucide-react';
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
    openStationEditor, removeStation, setDjIntroPlayed, queue,
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

  const parseSearchTerms = (raw: string): string[] => {
    const lines = raw.split('\n')
      .map(l => l.replace(/\(.*?\)/g, '').replace(/["“”„‟‘’]/g, '').trim())
      .filter(l => l.length > 1 && !/^[-–—•*]$/.test(l));
    return lines.length > 0 ? lines : [raw.trim()];
  };

  const shuffle = <T,>(arr: T[]): T[] => {
    for (let i = arr.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [arr[i], arr[j]] = [arr[j], arr[i]];
    }
    return arr;
  };

  const playStation = async (station: Station) => {
    setLoadingStation(station.id);
    setCurrentStation(station);
    setDjIntroPlayed(false);

    const styleTerms: Record<string, string> = { chill: 'chill relaxing', hype: 'upbeat energy', balanced: 'popular hits' };
    const raw = station.searchQuery || styleTerms[station.style] || 'music';
    const terms = shuffle(parseSearchTerms(raw));

    let tracks: Track[] = [];

    if (musicSource === 'apple-music' && appleMusic.music) {
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
  const gradients: Record<string, string> = {
    chill: 'from-sky-500 to-indigo-600',
    balanced: 'from-violet-500 to-fuchsia-600',
    hype: 'from-amber-500 to-red-600',
  };

  return (
    <div className="min-h-[100dvh] bg-black text-white relative overflow-hidden">
      {/* Ambient background glow from current artwork */}
      {currentTrack?.artworkUrl && isPlaying && (
        <div className="fixed inset-0 pointer-events-none z-0">
          <div
            className="absolute inset-0 animate-ambient"
            style={{
              backgroundImage: `url(${currentTrack.artworkUrl})`,
              backgroundSize: 'cover',
              backgroundPosition: 'center',
              filter: 'blur(120px) saturate(1.8)',
              opacity: 0.15,
            }}
          />
          <div className="absolute inset-0 bg-gradient-to-b from-black/60 via-black/80 to-black" />
        </div>
      )}

      {/* Header */}
      <header className="relative z-10 flex items-center justify-between px-5 sm:px-8 py-4">
        <div className="flex items-center gap-2.5">
          <div className="w-9 h-9 rounded-xl bg-gradient-to-br from-violet-500 to-fuchsia-500 flex items-center justify-center shadow-lg shadow-violet-500/25">
            <Radio size={16} />
          </div>
          <div>
            <span className="text-lg font-bold tracking-tight">RAY.DO</span>
            <span className="hidden sm:inline text-zinc-600 text-sm ml-2">AI Radio DJ</span>
          </div>
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={toggleCommentary}
            className={`p-2.5 rounded-xl transition-all duration-200 ${commentaryEnabled ? 'text-violet-400 bg-violet-500/10 shadow-inner shadow-violet-500/10' : 'text-zinc-600 hover:text-zinc-400'}`}
          >
            {commentaryEnabled ? <Mic size={18} /> : <MicOff size={18} />}
          </button>
          <button onClick={toggleSettings} className="p-2.5 text-zinc-400 hover:text-white rounded-xl transition-colors">
            <Settings2 size={18} />
          </button>
        </div>
      </header>

      <main className="relative z-10 px-5 sm:px-8 pb-44 max-w-6xl mx-auto">
        <div className="lg:grid lg:grid-cols-[1fr_320px] lg:gap-12">
          {/* Left column */}
          <div>
            {/* Now Playing Hero */}
            {currentTrack ? (
              <section className="mb-10 animate-fade-in">
                <div className="relative rounded-3xl overflow-hidden bg-zinc-900/40 border border-white/[0.06] backdrop-blur-xl">
                  {/* Inner ambient glow */}
                  {currentTrack.artworkUrl && (
                    <div
                      className="absolute inset-0 opacity-20"
                      style={{
                        backgroundImage: `url(${currentTrack.artworkUrl})`,
                        backgroundSize: 'cover',
                        backgroundPosition: 'center',
                        filter: 'blur(60px) saturate(2)',
                      }}
                    />
                  )}

                  <div className="relative p-6 sm:p-8 flex flex-col sm:flex-row items-center sm:items-start gap-6">
                    {/* Artwork */}
                    <div className="relative flex-shrink-0 group">
                      {currentTrack.artworkUrl ? (
                        <img
                          src={currentTrack.artworkUrl}
                          alt=""
                          className={`w-36 h-36 sm:w-44 sm:h-44 rounded-2xl object-cover shadow-2xl shadow-black/50 transition-transform duration-700 ${isPlaying ? 'scale-100' : 'scale-95 opacity-80'}`}
                        />
                      ) : (
                        <div className="w-36 h-36 sm:w-44 sm:h-44 rounded-2xl bg-zinc-800 flex items-center justify-center">
                          <Disc3 size={48} className={`text-zinc-700 ${isPlaying ? 'animate-spin-slow' : ''}`} />
                        </div>
                      )}
                      {isPlaying && (
                        <div className="absolute -bottom-2 left-1/2 -translate-x-1/2 flex gap-[3px] items-end h-4">
                          {[0, 1, 2, 3, 4].map(i => (
                            <div
                              key={i}
                              className="w-[3px] bg-violet-400 rounded-full animate-eq-bar"
                              style={{ animationDelay: `${i * 0.12}s`, animationDuration: `${0.8 + i * 0.1}s` }}
                            />
                          ))}
                        </div>
                      )}
                    </div>

                    {/* Track info */}
                    <div className="text-center sm:text-left min-w-0 flex-1 pt-2">
                      <p className="text-[11px] text-violet-400/80 uppercase tracking-[0.2em] font-medium mb-2">
                        {isPlaying ? 'Now Playing' : 'Paused'}
                      </p>
                      <h2 className="text-2xl sm:text-3xl font-bold leading-tight truncate">
                        {currentTrack.title}
                      </h2>
                      <p className="text-zinc-400 text-base sm:text-lg mt-1.5 truncate">
                        {currentTrack.artistName}
                      </p>
                      {currentTrack.albumName && (
                        <p className="text-zinc-600 text-sm mt-1 truncate">{currentTrack.albumName}</p>
                      )}

                      {currentStation && (
                        <div className="mt-4 inline-flex items-center gap-2 px-3 py-1.5 rounded-full bg-white/[0.06] backdrop-blur-sm border border-white/[0.06]">
                          <div className={`w-2 h-2 rounded-full bg-gradient-to-r ${gradients[currentStation.style] || gradients.balanced} ${isPlaying ? 'animate-pulse' : ''}`} />
                          <span className="text-xs text-zinc-300">{currentStation.name}</span>
                          {commentaryEnabled && (
                            <span className="text-zinc-600 text-[10px]">DJ {currentStation.djName}</span>
                          )}
                        </div>
                      )}

                      {/* Up next preview */}
                      {queue.length > 0 && (
                        <div className="mt-4 text-xs text-zinc-600">
                          Up next: <span className="text-zinc-500">{queue[0].title}</span>
                          <span className="text-zinc-700"> &middot; {queue[0].artistName}</span>
                          {queue.length > 1 && <span className="text-zinc-700"> &middot; +{queue.length - 1} more</span>}
                        </div>
                      )}
                    </div>
                  </div>
                </div>
              </section>
            ) : (
              <section className="mb-12 pt-8 sm:pt-14 animate-slide-up">
                <div className="relative">
                  <div className="absolute -top-20 -left-20 w-64 h-64 bg-violet-500/10 rounded-full blur-3xl pointer-events-none" />
                  <div className="absolute -top-10 right-0 w-48 h-48 bg-fuchsia-500/10 rounded-full blur-3xl pointer-events-none" />
                  <div className="relative">
                    <h1 className="text-4xl sm:text-6xl font-bold tracking-tight leading-[1.1]">
                      Your AI<br />
                      <span className="bg-gradient-to-r from-violet-400 via-fuchsia-400 to-violet-400 bg-clip-text text-transparent">
                        Radio Station
                      </span>
                    </h1>
                    <p className="text-zinc-500 mt-4 text-sm sm:text-base max-w-md leading-relaxed">
                      Create custom stations with your music taste. The AI DJ sets the mood, introduces tracks, and keeps the vibe going.
                    </p>
                  </div>
                </div>
              </section>
            )}

            {/* Stations Section */}
            <section className="mb-8">
              <div className="flex items-center justify-between mb-5">
                <h3 className="text-xs text-zinc-500 uppercase tracking-[0.2em] font-medium">Your Stations</h3>
                <button
                  onClick={() => openStationEditor()}
                  className="flex items-center gap-1.5 text-xs text-violet-400 hover:text-violet-300 transition-colors group"
                >
                  <Plus size={14} className="group-hover:rotate-90 transition-transform duration-200" />
                  New Station
                </button>
              </div>

              {!hasStations ? (
                <button
                  onClick={() => openStationEditor()}
                  className="w-full p-8 rounded-2xl border border-dashed border-zinc-800 hover:border-violet-500/30 text-center transition-all group animate-slide-up"
                >
                  <div className="w-14 h-14 rounded-2xl bg-zinc-900 mx-auto mb-4 flex items-center justify-center group-hover:bg-violet-500/10 group-hover:shadow-lg group-hover:shadow-violet-500/10 transition-all duration-300">
                    <Plus size={22} className="text-zinc-600 group-hover:text-violet-400 transition-colors" />
                  </div>
                  <p className="text-sm font-medium text-zinc-300">Create your first station</p>
                  <p className="text-xs text-zinc-600 mt-1.5">Pick your music, choose a DJ style</p>
                </button>
              ) : (
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                  {stations.map((station, idx) => {
                    const active = currentStation?.id === station.id;
                    const styleEmoji: Record<string, string> = { chill: '\u{1F30A}', balanced: '\u{2728}', hype: '\u{1F525}' };
                    return (
                      <div
                        key={station.id}
                        className="animate-slide-up"
                        style={{ animationDelay: `${idx * 60}ms` }}
                      >
                        <div className={`relative group rounded-2xl transition-all duration-300 ${active ? 'ring-1 ring-violet-500/30 shadow-lg shadow-violet-500/10' : ''}`}>
                          <button
                            onClick={() => playStation(station)}
                            disabled={loadingStation === station.id}
                            className={`w-full p-4 rounded-2xl text-left transition-all active:scale-[0.97] disabled:opacity-60 ${
                              active
                                ? 'bg-gradient-to-br from-zinc-900/80 to-zinc-900/60 border border-white/[0.08]'
                                : 'bg-zinc-900/40 hover:bg-zinc-900/70 border border-white/[0.04] hover:border-white/[0.08]'
                            }`}
                          >
                            <div className="flex items-start gap-3.5">
                              <div className={`w-11 h-11 rounded-xl bg-gradient-to-br ${gradients[station.style] || gradients.balanced} flex items-center justify-center flex-shrink-0 shadow-lg transition-transform duration-300 ${active && isPlaying ? 'scale-110' : 'group-hover:scale-105'}`}>
                                {loadingStation === station.id ? (
                                  <div className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                                ) : (
                                  <Radio size={14} />
                                )}
                              </div>
                              <div className="min-w-0 flex-1">
                                <div className="flex items-center gap-2">
                                  <p className="text-white text-sm font-semibold truncate">{station.name}</p>
                                  {active && isPlaying && (
                                    <div className="flex gap-[2px] items-end h-3 flex-shrink-0">
                                      {[0, 1, 2].map(i => (
                                        <div
                                          key={i}
                                          className="w-[2px] bg-violet-400/70 rounded-full animate-eq-bar"
                                          style={{ animationDelay: `${i * 0.15}s`, animationDuration: `${0.7 + i * 0.15}s` }}
                                        />
                                      ))}
                                    </div>
                                  )}
                                </div>
                                <p className="text-zinc-500 text-xs mt-0.5 truncate">
                                  {station.searchQuery || `${station.style} vibes`}
                                </p>
                                <p className="text-zinc-600 text-[11px] mt-1.5 flex items-center gap-1.5">
                                  <span>{styleEmoji[station.style] || '\u{2728}'}</span>
                                  <span>DJ {station.djName}</span>
                                  <span className="text-zinc-700">&middot;</span>
                                  <span>{Math.round(station.energyLevel * 100)}% energy</span>
                                </p>
                              </div>
                            </div>
                          </button>
                          {/* Edit / Delete overlay */}
                          <div className="absolute top-2.5 right-2.5 flex gap-1 opacity-0 group-hover:opacity-100 transition-all duration-200">
                            <button
                              onClick={(e) => { e.stopPropagation(); openStationEditor(station); }}
                              className="p-1.5 rounded-lg bg-zinc-800/90 backdrop-blur-sm text-zinc-400 hover:text-white border border-white/5 transition-colors"
                            >
                              <Pencil size={11} />
                            </button>
                            <button
                              onClick={(e) => { e.stopPropagation(); removeStation(station.id); }}
                              className="p-1.5 rounded-lg bg-zinc-800/90 backdrop-blur-sm text-zinc-400 hover:text-red-400 border border-white/5 transition-colors"
                            >
                              <Trash2 size={11} />
                            </button>
                          </div>
                        </div>
                      </div>
                    );
                  })}
                  {/* Add more button */}
                  <button
                    onClick={() => openStationEditor()}
                    className="p-4 rounded-2xl border border-dashed border-zinc-800/60 hover:border-violet-500/30 flex items-center justify-center transition-all min-h-[96px] hover:bg-violet-500/[0.03]"
                  >
                    <Plus size={18} className="text-zinc-700" />
                  </button>
                </div>
              )}
            </section>
          </div>

          {/* Right column - Music Source */}
          <div className="lg:pt-2">
            <section className="lg:sticky lg:top-6">
              <h3 className="text-xs text-zinc-500 uppercase tracking-[0.2em] font-medium mb-4">Music source</h3>

              {musicSource === 'none' ? (
                <div className="space-y-3 animate-slide-up">
                  <SourceButton
                    label="Apple Music"
                    desc="Stream from your library"
                    icon={<Music size={16} />}
                    gradient="from-red-500 to-pink-500"
                    onClick={() => selectSource('apple-music')}
                  />
                  <SourceButton
                    label="Spotify"
                    desc="Stream from your library"
                    icon={<Headphones size={16} />}
                    color="bg-[#1DB954]"
                    onClick={() => selectSource('spotify')}
                  />
                </div>
              ) : (
                <div className="rounded-2xl bg-zinc-900/40 backdrop-blur-sm border border-white/[0.06] p-5 animate-fade-in">
                  <div className="flex items-center justify-between mb-4">
                    <div className="flex items-center gap-3">
                      <div className={`w-9 h-9 rounded-xl flex items-center justify-center shadow-lg ${musicSource === 'spotify' ? 'bg-[#1DB954] shadow-green-500/20' : 'bg-gradient-to-br from-red-500 to-pink-500 shadow-red-500/20'}`}>
                        {musicSource === 'spotify' ? <Headphones size={14} /> : <Music size={14} />}
                      </div>
                      <div>
                        <p className="text-sm text-white font-medium">{musicSource === 'spotify' ? 'Spotify' : 'Apple Music'}</p>
                        <p className="text-[11px] text-zinc-600">Music source</p>
                      </div>
                    </div>
                    <button onClick={() => selectSource('none')} className="text-xs text-zinc-600 hover:text-zinc-300 transition-colors px-2 py-1 rounded-lg hover:bg-white/5">Change</button>
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

function SourceButton({ label, desc, icon, gradient, color, onClick }: {
  label: string; desc: string; icon: React.ReactNode; gradient?: string; color?: string; onClick: () => void;
}) {
  return (
    <button onClick={onClick} className="w-full flex items-center gap-4 p-4 rounded-2xl bg-zinc-900/40 hover:bg-zinc-900/70 border border-white/[0.04] hover:border-white/[0.08] transition-all active:scale-[0.98] group">
      <div className={`w-11 h-11 rounded-xl flex items-center justify-center flex-shrink-0 shadow-lg transition-transform group-hover:scale-105 ${gradient ? `bg-gradient-to-br ${gradient}` : color}`}>
        {icon}
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
    return (
      <button
        onClick={connectAppleMusic}
        disabled={isLoading}
        className="w-full py-3 rounded-xl bg-gradient-to-r from-red-500 to-pink-500 text-white text-sm font-medium active:scale-[0.98] transition-all disabled:opacity-50 shadow-lg shadow-red-500/20 hover:shadow-red-500/30"
      >
        {isLoading ? 'Connecting...' : 'Connect Apple Music'}
      </button>
    );
  }
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between text-sm">
        <span className="text-emerald-400 text-xs font-medium flex items-center gap-1.5">
          <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" />
          Connected
        </span>
        <button onClick={disconnect} className="text-zinc-600 text-xs hover:text-zinc-400 transition-colors">Disconnect</button>
      </div>
      <MoodPicker mood={mood} setMood={setMood} />
      <button
        onClick={() => createRadioStation(mood)}
        disabled={isLoading}
        className="w-full py-2.5 rounded-xl bg-white/[0.06] hover:bg-white/[0.1] text-white text-sm font-medium disabled:opacity-50 transition-all border border-white/[0.04]"
      >
        {isLoading ? 'Loading...' : 'Quick Start'}
      </button>
    </div>
  );
}

function SpotifyConnect() {
  const { isAuthenticated, connectSpotify, disconnect, createRadioStation, isLoading } = useSpotify();
  const [mood, setMood] = useState<'chill' | 'balanced' | 'hype'>('balanced');
  if (!isAuthenticated) {
    return (
      <button
        onClick={connectSpotify}
        className="w-full py-3 rounded-xl bg-[#1DB954] text-white text-sm font-medium active:scale-[0.98] transition-all shadow-lg shadow-green-500/20 hover:shadow-green-500/30"
      >
        Connect Spotify
      </button>
    );
  }
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between text-sm">
        <span className="text-emerald-400 text-xs font-medium flex items-center gap-1.5">
          <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" />
          Connected
        </span>
        <button onClick={disconnect} className="text-zinc-600 text-xs hover:text-zinc-400 transition-colors">Disconnect</button>
      </div>
      <MoodPicker mood={mood} setMood={setMood} />
      <button
        onClick={() => createRadioStation(mood)}
        disabled={isLoading}
        className="w-full py-2.5 rounded-xl bg-white/[0.06] hover:bg-white/[0.1] text-white text-sm font-medium disabled:opacity-50 transition-all border border-white/[0.04]"
      >
        {isLoading ? 'Loading...' : 'Quick Start'}
      </button>
    </div>
  );
}

function MoodPicker({ mood, setMood }: { mood: 'chill' | 'balanced' | 'hype'; setMood: (m: 'chill' | 'balanced' | 'hype') => void }) {
  return (
    <div className="flex gap-1 p-1 bg-black/40 rounded-xl">
      {(['chill', 'balanced', 'hype'] as const).map(m => (
        <button
          key={m}
          onClick={() => setMood(m)}
          className={`flex-1 py-1.5 rounded-lg text-xs font-medium transition-all duration-200 ${
            mood === m
              ? 'bg-white text-black shadow-sm'
              : 'text-zinc-500 hover:text-zinc-300'
          }`}
        >
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
