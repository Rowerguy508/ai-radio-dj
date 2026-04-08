'use client';

import { useState, useEffect } from 'react';
import { Settings } from './components/Settings';
import { Player } from './components/Player';
import { StationSelector } from './components/StationSelector';
import { Visualizer } from './components/Visualizer';
import { useRadioStore } from '@/lib/store/radio';
import { AppleMusicProvider, useAppleMusic } from '@/lib/apple-music/player';
import { SpotifyProvider, useSpotify } from '@/lib/spotify/player';

type MusicSource = 'none' | 'apple-music' | 'spotify';

function AppleMusicDashboard() {
  const { user, isAuthenticated, playlists, connectAppleMusic, disconnect, createRadioStation, isLoading } = useAppleMusic();
  const [selectedMood, setSelectedMood] = useState<'chill' | 'hype' | 'balanced'>('balanced');

  if (!isAuthenticated) {
    return (
      <div className="mb-8 p-6 bg-gradient-to-r from-red-500/10 to-red-600/10 border border-red-500/20 rounded-xl">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="text-lg font-semibold text-red-400 mb-1">Connect Apple Music</h3>
            <p className="text-zinc-400">Sign in with Apple Music to stream music and create radio stations</p>
          </div>
          <button
            onClick={connectAppleMusic}
            className="px-6 py-3 bg-gradient-to-r from-red-500 to-pink-500 hover:from-red-400 hover:to-pink-400 text-white font-semibold rounded-lg transition-colors"
          >
            Connect
          </button>
        </div>
      </div>
    );
  }

  return (
    <>
      <UserHeader name={user?.name || 'Apple Music User'} source="Apple Music" onDisconnect={disconnect} />
      <RadioCreator
        selectedMood={selectedMood}
        setSelectedMood={setSelectedMood}
        onStart={() => createRadioStation(selectedMood)}
        isLoading={isLoading}
      />
      <PlaylistGrid playlists={playlists.map(p => ({
        id: p.id,
        name: p.name,
        artwork: p.artwork?.url?.replace('{w}', '200').replace('{h}', '200'),
        trackCount: p.trackCount,
      }))} />
    </>
  );
}

function SpotifyDashboard() {
  const { user, isAuthenticated, playlists, connectSpotify, disconnect, createRadioStation, isLoading } = useSpotify();
  const [selectedMood, setSelectedMood] = useState<'chill' | 'hype' | 'balanced'>('balanced');

  if (!isAuthenticated) {
    return (
      <div className="mb-8 p-6 bg-gradient-to-r from-green-500/10 to-green-600/10 border border-green-500/20 rounded-xl">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="text-lg font-semibold text-green-400 mb-1">Connect Spotify</h3>
            <p className="text-zinc-400">Sign in with Spotify to stream music and create radio stations</p>
          </div>
          <button
            onClick={connectSpotify}
            className="px-6 py-3 bg-gradient-to-r from-green-500 to-green-600 hover:from-green-400 hover:to-green-500 text-white font-semibold rounded-lg transition-colors"
          >
            Connect
          </button>
        </div>
      </div>
    );
  }

  return (
    <>
      <UserHeader
        name={user?.display_name || 'Spotify User'}
        source="Spotify"
        avatar={user?.images?.[0]?.url}
        onDisconnect={disconnect}
      />
      <RadioCreator
        selectedMood={selectedMood}
        setSelectedMood={setSelectedMood}
        onStart={() => createRadioStation(selectedMood)}
        isLoading={isLoading}
      />
      <PlaylistGrid playlists={playlists.map(p => ({
        id: p.id,
        name: p.name,
        artwork: p.images?.[0]?.url,
        trackCount: p.tracks?.total || 0,
      }))} />
    </>
  );
}

// Shared UI components

function UserHeader({ name, source, avatar, onDisconnect }: {
  name: string; source: string; avatar?: string; onDisconnect: () => void;
}) {
  return (
    <div className="mb-8 p-4 bg-zinc-900/50 rounded-xl flex items-center gap-4">
      {avatar ? (
        <img src={avatar} alt={name} className="w-12 h-12 rounded-full object-cover" />
      ) : (
        <div className="w-12 h-12 bg-gradient-to-br from-purple-500 to-pink-500 rounded-full flex items-center justify-center text-white font-bold">
          {name.charAt(0)}
        </div>
      )}
      <div className="flex-1">
        <p className="text-zinc-400 text-sm">Signed in with {source}</p>
        <p className="text-white font-medium">{name}</p>
      </div>
      <button onClick={onDisconnect} className="px-4 py-2 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-lg text-sm">
        Disconnect
      </button>
    </div>
  );
}

function RadioCreator({ selectedMood, setSelectedMood, onStart, isLoading }: {
  selectedMood: 'chill' | 'hype' | 'balanced';
  setSelectedMood: (mood: 'chill' | 'hype' | 'balanced') => void;
  onStart: () => void;
  isLoading: boolean;
}) {
  return (
    <div className="mb-8 p-6 bg-zinc-900/50 rounded-xl">
      <h3 className="text-lg font-semibold text-white mb-2">Create AI Radio Station</h3>
      <p className="text-zinc-400 text-sm mb-4">
        Select a mood and the AI DJ will provide commentary between songs from your library
      </p>
      <div className="flex gap-3 mb-4">
        {(['chill', 'balanced', 'hype'] as const).map((mood) => (
          <button
            key={mood}
            onClick={() => setSelectedMood(mood)}
            className={`px-4 py-2 rounded-lg font-medium transition-colors ${
              selectedMood === mood
                ? 'bg-purple-500 text-white'
                : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'
            }`}
          >
            {mood === 'chill' && 'Chill'}
            {mood === 'balanced' && 'Balanced'}
            {mood === 'hype' && 'Hype'}
          </button>
        ))}
      </div>
      <button
        onClick={onStart}
        disabled={isLoading}
        className="w-full py-3 bg-gradient-to-r from-purple-500 to-pink-500 hover:from-purple-400 hover:to-pink-400 text-white font-semibold rounded-lg transition-colors disabled:opacity-50"
      >
        {isLoading ? 'Creating Station...' : 'Start AI Radio'}
      </button>
    </div>
  );
}

function PlaylistGrid({ playlists }: { playlists: { id: string; name: string; artwork?: string; trackCount: number }[] }) {
  if (playlists.length === 0) return null;
  return (
    <div className="mb-8">
      <h3 className="text-lg font-semibold text-white mb-4">Your Playlists</h3>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {playlists.slice(0, 8).map((playlist) => (
          <div
            key={playlist.id}
            className="p-4 bg-zinc-900/50 rounded-xl hover:bg-zinc-800 transition-colors cursor-pointer"
          >
            {playlist.artwork && (
              <img src={playlist.artwork} alt={playlist.name} className="w-full aspect-square object-cover rounded-lg mb-3" />
            )}
            <p className="text-white font-medium truncate">{playlist.name}</p>
            <p className="text-zinc-500 text-sm">{playlist.trackCount} tracks</p>
          </div>
        ))}
      </div>
    </div>
  );
}

// Music source selector shown when no source is connected yet
function MusicSourcePicker({ onSelect }: { onSelect: (source: MusicSource) => void }) {
  return (
    <div className="mb-8">
      <h3 className="text-lg font-semibold text-white mb-2">Choose Your Music Source</h3>
      <p className="text-zinc-400 text-sm mb-6">Connect your music service to power your AI radio station</p>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <button
          onClick={() => onSelect('apple-music')}
          className="p-6 bg-zinc-900/50 rounded-xl hover:bg-zinc-800 transition-colors text-left group border border-zinc-800 hover:border-red-500/30"
        >
          <div className="w-12 h-12 bg-gradient-to-br from-red-500 to-pink-500 rounded-xl flex items-center justify-center mb-4">
            <svg width="24" height="24" viewBox="0 0 24 24" fill="white"><path d="M23.994 6.124a9.23 9.23 0 0 0-.24-2.19c-.317-1.31-1.062-2.31-2.18-3.043a5.022 5.022 0 0 0-1.877-.726 10.496 10.496 0 0 0-1.564-.15c-.04-.003-.083-.01-.124-.013H5.986c-.152.01-.303.017-.455.026-.747.043-1.49.123-2.193.4-1.336.53-2.3 1.452-2.865 2.78-.192.448-.292.925-.363 1.408-.056.392-.088.785-.1 1.18 0 .032-.007.062-.01.093v12.223c.01.14.017.283.027.424.05.815.154 1.624.497 2.373.65 1.42 1.738 2.353 3.234 2.802.42.127.856.187 1.297.228.558.05 1.118.08 1.678.08h10.49c.56 0 1.12-.02 1.677-.08.495-.052.98-.13 1.447-.312 1.286-.502 2.26-1.353 2.885-2.59.253-.5.397-1.036.49-1.586.107-.63.15-1.27.155-1.91V6.124zm-6.77 5.04c-.31.273-.632.52-.974.742a4.8 4.8 0 0 1-.974.49c-.397.157-.81.26-1.233.296-.5.042-.837-.208-.9-.706-.034-.278.003-.55.053-.82.07-.373.174-.735.285-1.096.13-.417.27-.83.404-1.247.098-.302.177-.61.226-.924.08-.51-.053-.903-.467-1.16-.137-.085-.29-.137-.446-.18-.22-.06-.447-.08-.674-.066-.534.032-1.03.184-1.503.42-.658.328-1.18.804-1.58 1.404-.346.52-.563 1.096-.69 1.71-.11.534-.164 1.074-.186 1.62-.014.33-.006.66.03.988.072.65.244 1.27.578 1.84.385.655.898 1.158 1.563 1.493.452.228.935.35 1.438.394.27.023.542.018.81-.016.688-.088 1.318-.313 1.9-.666.364-.22.7-.474 1.01-.76.027-.025.06-.046.09-.068l.012.015c-.033.076-.06.155-.098.23-.295.576-.676 1.094-1.143 1.546-.404.39-.85.728-1.34 1.01-.58.333-1.197.568-1.853.698-.537.107-1.08.146-1.628.113-.88-.054-1.713-.275-2.472-.71-.818-.47-1.44-1.12-1.872-1.926-.298-.557-.49-1.15-.589-1.773-.077-.49-.105-.983-.086-1.478.038-.98.252-1.917.67-2.803.426-.9 1.018-1.672 1.782-2.302.63-.52 1.33-.917 2.1-1.183.637-.22 1.293-.347 1.966-.384.314-.017.628-.01.94.02.65.063 1.268.222 1.83.546.42.24.764.558 1.004.97.153.263.237.55.274.857.03.245.02.49-.01.735-.056.44-.16.87-.28 1.295-.16.567-.34 1.13-.523 1.692-.114.348-.228.7-.317 1.057-.053.215-.085.435-.056.66.037.29.196.448.485.47.18.014.357-.008.534-.04.495-.094.956-.275 1.393-.518.2-.11.39-.232.574-.363.025-.018.052-.033.08-.048z"/></svg>
          </div>
          <h4 className="text-white font-semibold text-lg mb-1">Apple Music</h4>
          <p className="text-zinc-400 text-sm">Stream from your Apple Music subscription</p>
        </button>

        <button
          onClick={() => onSelect('spotify')}
          className="p-6 bg-zinc-900/50 rounded-xl hover:bg-zinc-800 transition-colors text-left group border border-zinc-800 hover:border-green-500/30"
        >
          <div className="w-12 h-12 bg-[#1DB954] rounded-xl flex items-center justify-center mb-4">
            <svg width="24" height="24" viewBox="0 0 24 24" fill="white"><path d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2zm.12-3.36C15.24 8.4 8.82 8.16 5.16 9.301c-.6.179-1.2-.181-1.38-.721-.18-.601.18-1.2.72-1.381 4.26-1.26 11.28-1.02 15.721 1.621.539.3.719 1.02.419 1.56-.299.421-1.02.599-1.559.3z"/></svg>
          </div>
          <h4 className="text-white font-semibold text-lg mb-1">Spotify</h4>
          <p className="text-zinc-400 text-sm">Stream from your Spotify subscription</p>
        </button>
      </div>
    </div>
  );
}

function HomeContent() {
  const { toggleSettings, isPlaying, currentTrack, currentStation } = useRadioStore();
  const [musicSource, setMusicSource] = useState<MusicSource>('none');
  const [isLoading, setIsLoading] = useState(true);

  // Restore music source preference
  useEffect(() => {
    const saved = localStorage.getItem('raydo-music-source') as MusicSource;
    if (saved && saved !== 'none') {
      setMusicSource(saved);
    }
    const timer = setTimeout(() => setIsLoading(false), 500);
    return () => clearTimeout(timer);
  }, []);

  const handleSelectSource = (source: MusicSource) => {
    setMusicSource(source);
    localStorage.setItem('raydo-music-source', source);
  };

  if (isLoading) {
    return (
      <div className="min-h-screen bg-black flex items-center justify-center">
        <div className="text-center">
          <div className="w-16 h-16 border-4 border-zinc-800 border-t-white rounded-full animate-spin mx-auto mb-4" />
          <p className="text-zinc-400">Loading RAY.DO...</p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-black text-white">
      {/* Header */}
      <header className="sticky top-0 z-10 bg-black/80 backdrop-blur-lg border-b border-zinc-800">
        <div className="max-w-6xl mx-auto px-6 py-4 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-gradient-to-br from-purple-500 to-pink-500 rounded-lg flex items-center justify-center">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="white"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>
            </div>
            <div>
              <h1 className="text-xl font-bold">RAY.DO</h1>
              <p className="text-xs text-zinc-500">AI Radio DJ</p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            {musicSource !== 'none' && (
              <button
                onClick={() => handleSelectSource('none')}
                className="px-3 py-1.5 text-zinc-400 hover:text-white text-sm transition-colors"
              >
                Switch Source
              </button>
            )}
            <button
              onClick={toggleSettings}
              className="p-2 text-zinc-400 hover:text-white transition-colors"
            >
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <circle cx="12" cy="12" r="3" />
                <path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42" />
              </svg>
            </button>
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-6xl mx-auto px-6 py-8 pb-32">
        {musicSource === 'none' && (
          <MusicSourcePicker onSelect={handleSelectSource} />
        )}

        {musicSource === 'apple-music' && (
          <AppleMusicDashboard />
        )}

        {musicSource === 'spotify' && (
          <SpotifyDashboard />
        )}

        {/* Now Playing */}
        {currentTrack && (
          <div className="mb-6 p-4 bg-zinc-900/50 rounded-xl flex items-center gap-4">
            {currentTrack.artworkUrl && (
              <img src={currentTrack.artworkUrl} alt={currentTrack.title} className="w-16 h-16 rounded-lg" />
            )}
            <div className="flex-1">
              <p className="text-white font-medium">{currentTrack.title}</p>
              <p className="text-zinc-400 text-sm">{currentTrack.artistName}</p>
            </div>
            <div className={`w-3 h-3 rounded-full ${isPlaying ? 'bg-green-400 animate-pulse' : 'bg-zinc-500'}`} />
          </div>
        )}

        {/* Station Selector (preset stations with demo music) */}
        <StationSelector />

        {/* Visualizer */}
        <div className="mt-6">
          <Visualizer isPlaying={isPlaying} />
        </div>

        {/* Quick Stats */}
        <div className="mt-12 grid grid-cols-1 md:grid-cols-3 gap-4">
          <div className="p-4 bg-zinc-900 rounded-lg">
            <p className="text-zinc-400 text-sm">Currently Playing</p>
            <p className="text-white font-medium mt-1">{currentStation?.name || 'No station selected'}</p>
          </div>
          <div className="p-4 bg-zinc-900 rounded-lg">
            <p className="text-zinc-400 text-sm">AI Commentary</p>
            <p className="text-white font-medium mt-1">
              {currentStation ? 'Weaving between tracks' : 'Start a station to enable'}
            </p>
          </div>
          <div className="p-4 bg-zinc-900 rounded-lg">
            <p className="text-zinc-400 text-sm">Music Source</p>
            <p className="text-white font-medium mt-1">
              {musicSource === 'apple-music' ? 'Apple Music' : musicSource === 'spotify' ? 'Spotify' : 'Not connected'}
            </p>
          </div>
        </div>
      </main>

      {/* Player */}
      <Player />

      {/* Settings Modal */}
      <Settings />
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
