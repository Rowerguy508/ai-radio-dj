'use client';

import { useState, useEffect } from 'react';
import { Settings2, Radio, Mic, MicOff } from 'lucide-react';
import { Player } from './components/Player';
import { Settings } from './components/Settings';
import { useRadioStore, Station } from '@/lib/store/radio';
import { AppleMusicProvider, useAppleMusic } from '@/lib/apple-music/player';
import { SpotifyProvider, useSpotify } from '@/lib/spotify/player';

type MusicSource = 'none' | 'apple-music' | 'spotify';

// ── Station presets ──

const PRESETS: { name: string; style: 'chill' | 'balanced' | 'hype'; energy: number; gradient: string }[] = [
  { name: 'Chill', style: 'chill', energy: 0.3, gradient: 'from-blue-600 to-cyan-500' },
  { name: 'Balanced', style: 'balanced', energy: 0.5, gradient: 'from-violet-600 to-fuchsia-500' },
  { name: 'Hype', style: 'hype', energy: 0.8, gradient: 'from-orange-500 to-red-500' },
];

const DEMO_TRACKS = [
  { id: 'd1', title: 'Llama Whippin Intro', artistName: 'DJ Llama', albumName: 'Demo', duration: 180, artworkUrl: 'https://picsum.photos/seed/d1/200', previewUrl: 'https://cdn.jsdelivr.net/gh/captbaritone/webamp@43434d82cfe0e37286dbbe0666072dc3190a83bc/mp3/llama-2.91.mp3' },
  { id: 'd2', title: 'Bloibb FX', artistName: 'cfork', albumName: 'Demo', duration: 15, artworkUrl: 'https://picsum.photos/seed/d2/200', previewUrl: 'https://cdn.jsdelivr.net/npm/test-audio@2.1.0/audio/8000__cfork__cf-fx-bloibb.mp3' },
  { id: 'd3', title: 'Drips', artistName: 'smcameron', albumName: 'Demo', duration: 10, artworkUrl: 'https://picsum.photos/seed/d3/200', previewUrl: 'https://cdn.jsdelivr.net/npm/test-audio@2.1.0/audio/50775__smcameron__drips2.ogg' },
];

// ── Main page ──

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

  const startPresetStation = (preset: typeof PRESETS[0]) => {
    const station: Station = {
      id: `preset-${preset.style}`,
      name: `${preset.name} Radio`,
      energyLevel: preset.energy,
      style: preset.style,
      musicGenres: [],
      includeMessages: false,
      includeCalendar: false,
      includeNews: false,
      isActive: true,
    };
    addStation(station);
    setCurrentStation(station);
    setQueue(DEMO_TRACKS.slice(1));
    setCurrentTrack(DEMO_TRACKS[0]);
    setIsPlaying(true);
  };

  if (!ready) return <div className="min-h-screen bg-black" />;

  return (
    <div className="min-h-[100dvh] bg-black text-white flex flex-col">
      {/* ── Header ── */}
      <header className="flex items-center justify-between px-5 py-4 safe-top">
        <div className="flex items-center gap-2.5">
          <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-violet-500 to-fuchsia-500 flex items-center justify-center">
            <Radio size={16} />
          </div>
          <span className="text-lg font-bold tracking-tight">RAY.DO</span>
        </div>
        <div className="flex items-center gap-1">
          <button onClick={toggleCommentary} className={`p-2 rounded-lg transition-colors ${commentaryEnabled ? 'text-violet-400' : 'text-zinc-600'}`}>
            {commentaryEnabled ? <Mic size={18} /> : <MicOff size={18} />}
          </button>
          <button onClick={toggleSettings} className="p-2 text-zinc-400 hover:text-white rounded-lg transition-colors">
            <Settings2 size={18} />
          </button>
        </div>
      </header>

      {/* ── Content ── */}
      <main className="flex-1 px-5 pb-36 overflow-y-auto">

        {/* Now Playing hero */}
        {currentTrack ? (
          <section className="mb-8">
            <div className="relative rounded-2xl overflow-hidden bg-zinc-900/80 p-5">
              <div className="flex items-center gap-4">
                {currentTrack.artworkUrl ? (
                  <img src={currentTrack.artworkUrl} alt="" className="w-16 h-16 sm:w-20 sm:h-20 rounded-xl object-cover flex-shrink-0" />
                ) : (
                  <div className="w-16 h-16 sm:w-20 sm:h-20 rounded-xl bg-zinc-800 flex items-center justify-center flex-shrink-0">
                    <Radio size={24} className="text-zinc-600" />
                  </div>
                )}
                <div className="min-w-0">
                  <p className="text-xs text-zinc-500 uppercase tracking-wider mb-1">Now Playing</p>
                  <h2 className="text-white font-semibold text-lg leading-tight truncate">{currentTrack.title}</h2>
                  <p className="text-zinc-400 text-sm truncate">{currentTrack.artistName}</p>
                  {currentStation && (
                    <p className="text-violet-400 text-xs mt-1">{currentStation.name}</p>
                  )}
                </div>
              </div>
              {isPlaying && (
                <div className="absolute top-4 right-4 flex gap-0.5 items-end h-4">
                  {[1,2,3,4].map(i => (
                    <div key={i} className="w-0.5 bg-violet-400 rounded-full animate-pulse" style={{ height: `${8 + Math.random() * 8}px`, animationDelay: `${i * 0.15}s` }} />
                  ))}
                </div>
              )}
            </div>
          </section>
        ) : (
          <section className="mb-8 pt-4">
            <h2 className="text-2xl sm:text-3xl font-bold mb-1">Your AI Radio</h2>
            <p className="text-zinc-500 text-sm">Pick a vibe and let the DJ take over</p>
          </section>
        )}

        {/* Station presets */}
        <section className="mb-8">
          <h3 className="text-xs text-zinc-500 uppercase tracking-wider mb-3 px-0.5">Stations</h3>
          <div className="grid grid-cols-3 gap-3">
            {PRESETS.map(p => (
              <button
                key={p.style}
                onClick={() => startPresetStation(p)}
                className={`relative rounded-xl p-4 text-left transition-all active:scale-95 ${
                  currentStation?.style === p.style && isPlaying
                    ? 'ring-1 ring-white/20 bg-zinc-800/80'
                    : 'bg-zinc-900/60 hover:bg-zinc-800/60'
                }`}
              >
                <div className={`w-8 h-8 rounded-lg bg-gradient-to-br ${p.gradient} mb-3 flex items-center justify-center`}>
                  <Radio size={14} />
                </div>
                <p className="text-white text-sm font-medium">{p.name}</p>
                <p className="text-zinc-500 text-[11px] mt-0.5">{Math.round(p.energy * 100)}% energy</p>
              </button>
            ))}
          </div>
        </section>

        {/* Music source */}
        <section className="mb-8">
          <h3 className="text-xs text-zinc-500 uppercase tracking-wider mb-3 px-0.5">Music Source</h3>
          {musicSource === 'none' ? (
            <div className="grid grid-cols-2 gap-3">
              <button onClick={() => selectSource('apple-music')} className="p-4 rounded-xl bg-zinc-900/60 hover:bg-zinc-800/60 transition-all active:scale-95 text-left">
                <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-red-500 to-pink-500 mb-3 flex items-center justify-center">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="white"><path d="M23.994 6.124a9.23 9.23 0 0 0-.24-2.19c-.317-1.31-1.062-2.31-2.18-3.043a5.022 5.022 0 0 0-1.877-.726 10.496 10.496 0 0 0-1.564-.15c-.04-.003-.083-.01-.124-.013H5.986c-.152.01-.303.017-.455.026-.747.043-1.49.123-2.193.4-1.336.53-2.3 1.452-2.865 2.78-.192.448-.292.925-.363 1.408-.056.392-.088.785-.1 1.18 0 .032-.007.062-.01.093v12.223c.01.14.017.283.027.424.05.815.154 1.624.497 2.373.65 1.42 1.738 2.353 3.234 2.802.42.127.856.187 1.297.228.558.05 1.118.08 1.678.08h10.49c.56 0 1.12-.02 1.677-.08.495-.052.98-.13 1.447-.312 1.286-.502 2.26-1.353 2.885-2.59.253-.5.397-1.036.49-1.586.107-.63.15-1.27.155-1.91V6.124z"/></svg>
                </div>
                <p className="text-white text-sm font-medium">Apple Music</p>
              </button>
              <button onClick={() => selectSource('spotify')} className="p-4 rounded-xl bg-zinc-900/60 hover:bg-zinc-800/60 transition-all active:scale-95 text-left">
                <div className="w-8 h-8 rounded-lg bg-[#1DB954] mb-3 flex items-center justify-center">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="white"><path d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2z"/></svg>
                </div>
                <p className="text-white text-sm font-medium">Spotify</p>
              </button>
            </div>
          ) : (
            <div className="flex items-center justify-between p-4 rounded-xl bg-zinc-900/60">
              <div className="flex items-center gap-3">
                <div className={`w-8 h-8 rounded-lg flex items-center justify-center ${musicSource === 'spotify' ? 'bg-[#1DB954]' : 'bg-gradient-to-br from-red-500 to-pink-500'}`}>
                  {musicSource === 'spotify' ? (
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="white"><path d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0z"/></svg>
                  ) : (
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="white"><path d="M23.994 6.124a9.23 9.23 0 0 0-.24-2.19c-.317-1.31-1.062-2.31-2.18-3.043z"/></svg>
                  )}
                </div>
                <span className="text-sm text-white">{musicSource === 'spotify' ? 'Spotify' : 'Apple Music'}</span>
              </div>
              <button onClick={() => selectSource('none')} className="text-xs text-zinc-500 hover:text-zinc-300">Change</button>
            </div>
          )}

          {musicSource === 'apple-music' && <AppleMusicConnect />}
          {musicSource === 'spotify' && <SpotifyConnect />}
        </section>
      </main>

      {/* Player + Settings */}
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
      <button onClick={connectAppleMusic} className="mt-3 w-full py-3 rounded-xl bg-gradient-to-r from-red-500 to-pink-500 text-white text-sm font-medium active:scale-[0.98] transition-transform">
        Connect Apple Music
      </button>
    );
  }

  return (
    <div className="mt-3 space-y-3">
      <div className="flex items-center justify-between text-sm">
        <span className="text-green-400">Connected</span>
        <button onClick={disconnect} className="text-zinc-500 text-xs">Disconnect</button>
      </div>
      <div className="flex gap-2">
        {(['chill', 'balanced', 'hype'] as const).map(m => (
          <button key={m} onClick={() => setMood(m)} className={`flex-1 py-2 rounded-lg text-xs font-medium transition-colors ${mood === m ? 'bg-white text-black' : 'bg-zinc-800 text-zinc-400'}`}>
            {m.charAt(0).toUpperCase() + m.slice(1)}
          </button>
        ))}
      </div>
      <button onClick={() => createRadioStation(mood)} disabled={isLoading} className="w-full py-2.5 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-white text-sm font-medium disabled:opacity-50 transition-colors">
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
      <button onClick={connectSpotify} className="mt-3 w-full py-3 rounded-xl bg-[#1DB954] text-white text-sm font-medium active:scale-[0.98] transition-transform">
        Connect Spotify
      </button>
    );
  }

  return (
    <div className="mt-3 space-y-3">
      <div className="flex items-center justify-between text-sm">
        <span className="text-green-400">Connected</span>
        <button onClick={disconnect} className="text-zinc-500 text-xs">Disconnect</button>
      </div>
      <div className="flex gap-2">
        {(['chill', 'balanced', 'hype'] as const).map(m => (
          <button key={m} onClick={() => setMood(m)} className={`flex-1 py-2 rounded-lg text-xs font-medium transition-colors ${mood === m ? 'bg-white text-black' : 'bg-zinc-800 text-zinc-400'}`}>
            {m.charAt(0).toUpperCase() + m.slice(1)}
          </button>
        ))}
      </div>
      <button onClick={() => createRadioStation(mood)} disabled={isLoading} className="w-full py-2.5 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-white text-sm font-medium disabled:opacity-50 transition-colors">
        {isLoading ? 'Loading...' : 'Start from Spotify'}
      </button>
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
