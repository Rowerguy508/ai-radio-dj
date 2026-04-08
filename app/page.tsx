'use client';

import { useState, useEffect } from 'react';
import { Settings2, Radio, Mic, MicOff } from 'lucide-react';
import { Player } from './components/Player';
import { Settings } from './components/Settings';
import { useRadioStore, Station } from '@/lib/store/radio';
import { AppleMusicProvider, useAppleMusic } from '@/lib/apple-music/player';
import { SpotifyProvider, useSpotify } from '@/lib/spotify/player';

type MusicSource = 'none' | 'apple-music' | 'spotify';

const PRESETS: { name: string; desc: string; style: 'chill' | 'balanced' | 'hype'; energy: number; gradient: string; icon: string }[] = [
  { name: 'Chill', desc: 'Lo-fi, ambient, relaxed', style: 'chill', energy: 0.3, gradient: 'from-sky-500 to-indigo-600', icon: '~' },
  { name: 'Flow', desc: 'Pop, indie, easy listening', style: 'balanced', energy: 0.5, gradient: 'from-violet-500 to-purple-600', icon: '=' },
  { name: 'Hype', desc: 'Energy, electronic, upbeat', style: 'hype', energy: 0.8, gradient: 'from-amber-500 to-red-600', icon: '!' },
];

const DEMO_TRACKS = [
  { id: 'd1', title: 'Llama Whippin Intro', artistName: 'DJ Llama', albumName: 'Demo', duration: 180, artworkUrl: 'https://picsum.photos/seed/d1/400', previewUrl: 'https://cdn.jsdelivr.net/gh/captbaritone/webamp@43434d82cfe0e37286dbbe0666072dc3190a83bc/mp3/llama-2.91.mp3' },
  { id: 'd2', title: 'Bloibb FX', artistName: 'cfork', albumName: 'Demo', duration: 15, artworkUrl: 'https://picsum.photos/seed/d2/400', previewUrl: 'https://cdn.jsdelivr.net/npm/test-audio@2.1.0/audio/8000__cfork__cf-fx-bloibb.mp3' },
  { id: 'd3', title: 'Drips', artistName: 'smcameron', albumName: 'Demo', duration: 10, artworkUrl: 'https://picsum.photos/seed/d3/400', previewUrl: 'https://cdn.jsdelivr.net/npm/test-audio@2.1.0/audio/50775__smcameron__drips2.ogg' },
];

function HomeContent() {
  const {
    toggleSettings, isPlaying, currentTrack, currentStation, commentaryEnabled, toggleCommentary,
    setCurrentStation, setCurrentTrack, setIsPlaying, setQueue, addStation,
  } = useRadioStore();

  const [musicSource, setMusicSource] = useState<MusicSource>('none');
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const saved = localStorage.getItem('raydo-music-source') as MusicSource;
    if (saved && saved !== 'none') setMusicSource(saved);
    setReady(true);
  }, []);

  const selectSource = (s: MusicSource) => {
    setMusicSource(s);
    localStorage.setItem('raydo-music-source', s);
  };

  const startPreset = (preset: typeof PRESETS[0]) => {
    const station: Station = {
      id: `preset-${preset.style}`, name: `${preset.name} Radio`,
      energyLevel: preset.energy, style: preset.style, musicGenres: [],
      includeMessages: false, includeCalendar: false, includeNews: false, isActive: true,
    };
    addStation(station);
    setCurrentStation(station);
    setQueue(DEMO_TRACKS.slice(1));
    setCurrentTrack(DEMO_TRACKS[0]);
    setIsPlaying(true);
  };

  if (!ready) return <div className="min-h-screen bg-black" />;

  return (
    <div className="min-h-[100dvh] bg-black text-white">
      {/* ── Header ── */}
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

      {/* ── Main layout: stacked on mobile, side-by-side on desktop ── */}
      <main className="px-5 sm:px-8 pb-40 max-w-6xl mx-auto">
        <div className="lg:grid lg:grid-cols-[1fr_340px] lg:gap-10">

          {/* ── Left column ── */}
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
                  Pick a vibe below and let the AI DJ curate your experience with music and commentary.
                </p>
              </section>
            )}

            {/* Station Presets */}
            <section className="mb-8">
              <h3 className="text-xs text-zinc-500 uppercase tracking-widest font-medium mb-4">Choose your vibe</h3>
              <div className="grid grid-cols-3 gap-3 sm:gap-4">
                {PRESETS.map(p => {
                  const active = currentStation?.style === p.style && isPlaying;
                  return (
                    <button
                      key={p.style}
                      onClick={() => startPreset(p)}
                      className={`group relative rounded-2xl p-4 sm:p-5 text-left transition-all active:scale-95 ${
                        active ? 'ring-1 ring-white/20' : ''
                      }`}
                    >
                      <div className={`absolute inset-0 rounded-2xl bg-gradient-to-br ${p.gradient} ${active ? 'opacity-20' : 'opacity-10 group-hover:opacity-15'} transition-opacity`} />
                      <div className="relative">
                        <div className={`w-10 h-10 sm:w-12 sm:h-12 rounded-xl bg-gradient-to-br ${p.gradient} mb-3 sm:mb-4 flex items-center justify-center text-white font-bold text-lg shadow-lg`}>
                          {p.icon}
                        </div>
                        <p className="text-white font-semibold text-sm sm:text-base">{p.name}</p>
                        <p className="text-zinc-500 text-[11px] sm:text-xs mt-0.5 leading-snug">{p.desc}</p>
                        {active && (
                          <div className="mt-2 flex gap-0.5 items-end h-3">
                            {[1,2,3,4].map(i => (
                              <div key={i} className="w-0.5 bg-white/60 rounded-full animate-pulse" style={{ height: `${6 + Math.random() * 6}px`, animationDelay: `${i * 0.15}s` }} />
                            ))}
                          </div>
                        )}
                      </div>
                    </button>
                  );
                })}
              </div>
            </section>
          </div>

          {/* ── Right column (sidebar on desktop) ── */}
          <div>
            <section>
              <h3 className="text-xs text-zinc-500 uppercase tracking-widest font-medium mb-4">Music source</h3>

              {musicSource === 'none' ? (
                <div className="space-y-3">
                  <button onClick={() => selectSource('apple-music')} className="w-full flex items-center gap-4 p-4 rounded-2xl bg-zinc-900/60 hover:bg-zinc-800/60 border border-white/5 transition-all active:scale-[0.98]">
                    <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-red-500 to-pink-500 flex items-center justify-center flex-shrink-0 shadow-lg shadow-red-500/10">
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="white"><path d="M23.994 6.124a9.23 9.23 0 0 0-.24-2.19c-.317-1.31-1.062-2.31-2.18-3.043a5.022 5.022 0 0 0-1.877-.726 10.496 10.496 0 0 0-1.564-.15c-.04-.003-.083-.01-.124-.013H5.986c-.152.01-.303.017-.455.026-.747.043-1.49.123-2.193.4-1.336.53-2.3 1.452-2.865 2.78-.192.448-.292.925-.363 1.408-.056.392-.088.785-.1 1.18 0 .032-.007.062-.01.093v12.223c.01.14.017.283.027.424.05.815.154 1.624.497 2.373.65 1.42 1.738 2.353 3.234 2.802.42.127.856.187 1.297.228.558.05 1.118.08 1.678.08h10.49c.56 0 1.12-.02 1.677-.08.495-.052.98-.13 1.447-.312 1.286-.502 2.26-1.353 2.885-2.59.253-.5.397-1.036.49-1.586.107-.63.15-1.27.155-1.91V6.124z"/></svg>
                    </div>
                    <div className="text-left">
                      <p className="text-white text-sm font-medium">Apple Music</p>
                      <p className="text-zinc-500 text-xs">Stream from your library</p>
                    </div>
                  </button>
                  <button onClick={() => selectSource('spotify')} className="w-full flex items-center gap-4 p-4 rounded-2xl bg-zinc-900/60 hover:bg-zinc-800/60 border border-white/5 transition-all active:scale-[0.98]">
                    <div className="w-10 h-10 rounded-xl bg-[#1DB954] flex items-center justify-center flex-shrink-0 shadow-lg shadow-green-500/10">
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="white"><path d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2z"/></svg>
                    </div>
                    <div className="text-left">
                      <p className="text-white text-sm font-medium">Spotify</p>
                      <p className="text-zinc-500 text-xs">Stream from your library</p>
                    </div>
                  </button>
                </div>
              ) : (
                <div className="rounded-2xl bg-zinc-900/60 border border-white/5 p-4">
                  <div className="flex items-center justify-between mb-4">
                    <div className="flex items-center gap-3">
                      <div className={`w-8 h-8 rounded-lg flex items-center justify-center ${musicSource === 'spotify' ? 'bg-[#1DB954]' : 'bg-gradient-to-br from-red-500 to-pink-500'}`}>
                        <svg width="12" height="12" viewBox="0 0 24 24" fill="white"><circle cx="12" cy="12" r="12"/></svg>
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
    </div>
  );
}

// ── Music service connect sections ──

function AppleMusicConnect() {
  const { isAuthenticated, connectAppleMusic, disconnect, createRadioStation, isLoading } = useAppleMusic();
  const [mood, setMood] = useState<'chill' | 'balanced' | 'hype'>('balanced');

  if (!isAuthenticated) {
    return (
      <button onClick={connectAppleMusic} disabled={isLoading} className="w-full py-3 rounded-xl bg-gradient-to-r from-red-500 to-pink-500 text-white text-sm font-medium active:scale-[0.98] transition-transform disabled:opacity-50">
        {isLoading ? 'Connecting...' : 'Connect Apple Music'}
      </button>
    );
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between text-sm">
        <span className="text-emerald-400 text-xs font-medium">Connected</span>
        <button onClick={disconnect} className="text-zinc-600 text-xs hover:text-zinc-400">Disconnect</button>
      </div>
      <MoodPicker mood={mood} setMood={setMood} />
      <button onClick={() => createRadioStation(mood)} disabled={isLoading} className="w-full py-2.5 rounded-xl bg-white/5 hover:bg-white/10 text-white text-sm font-medium disabled:opacity-50 transition-colors">
        {isLoading ? 'Loading...' : 'Start from Apple Music'}
      </button>
    </div>
  );
}

function SpotifyConnect() {
  const { isAuthenticated, connectSpotify, disconnect, createRadioStation, isLoading } = useSpotify();
  const [mood, setMood] = useState<'chill' | 'balanced' | 'hype'>('balanced');

  if (!isAuthenticated) {
    return (
      <button onClick={connectSpotify} className="w-full py-3 rounded-xl bg-[#1DB954] text-white text-sm font-medium active:scale-[0.98] transition-transform">
        Connect Spotify
      </button>
    );
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between text-sm">
        <span className="text-emerald-400 text-xs font-medium">Connected</span>
        <button onClick={disconnect} className="text-zinc-600 text-xs hover:text-zinc-400">Disconnect</button>
      </div>
      <MoodPicker mood={mood} setMood={setMood} />
      <button onClick={() => createRadioStation(mood)} disabled={isLoading} className="w-full py-2.5 rounded-xl bg-white/5 hover:bg-white/10 text-white text-sm font-medium disabled:opacity-50 transition-colors">
        {isLoading ? 'Loading...' : 'Start from Spotify'}
      </button>
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
