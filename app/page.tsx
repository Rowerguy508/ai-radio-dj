'use client';

import { useState, useEffect } from 'react';
import { Settings } from './components/Settings';
import { Player } from './components/Player';
import { StationSelector } from './components/StationSelector';
import { Visualizer } from './components/Visualizer';
import { useRadioStore } from '@/lib/store/radio';
import { AppleMusicProvider, useAppleMusic } from '@/lib/apple-music/player';

function AppleMusicDashboard() {
  const { user, isAuthenticated, playlists, connectAppleMusic, disconnect, createRadioStation, isLoading } = useAppleMusic();
  const { isPlaying, currentTrack } = useRadioStore();
  const [selectedMood, setSelectedMood] = useState<'chill' | 'hype' | 'balanced'>('balanced');

  if (!isAuthenticated) {
    return (
      <div className="mb-8 p-6 bg-gradient-to-r from-red-500/10 to-red-600/10 border border-red-500/20 rounded-xl">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="text-lg font-semibold text-red-400 mb-1">🎧 Connect Apple Music</h3>
            <p className="text-zinc-400">Sign in with Apple Music to stream real music and create personalized radio stations</p>
          </div>
            <button
              onClick={connectAppleMusic}
              className="px-6 py-3 bg-gradient-to-r from-red-500 to-pink-500 hover:from-red-400 hover:to-pink-400 text-white font-semibold rounded-lg transition-colors"
            >
              Connect Apple Music
            </button>
        </div>
      </div>
    );
  }

  return (
    <>
      {/* User Header */}
      <div className="mb-8 p-4 bg-zinc-900/50 rounded-xl flex items-center gap-4">
        <div className="w-12 h-12 bg-gradient-to-br from-red-500 to-pink-500 rounded-full flex items-center justify-center text-white font-bold">
          {user?.name?.charAt(0) || 'A'}
        </div>
        <div className="flex-1">
          <p className="text-zinc-400 text-sm">Signed in with Apple Music</p>
          <p className="text-white font-medium">{user?.name}</p>
        </div>
        <button
          onClick={disconnect}
          className="px-4 py-2 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-lg text-sm"
        >
          Disconnect
        </button>
      </div>

      {/* Radio Station Creator */}
      <div className="mb-8 p-6 bg-zinc-900/50 rounded-xl">
        <h3 className="text-lg font-semibold text-white mb-4">🎵 Create AI Radio Station</h3>
        <p className="text-zinc-400 text-sm mb-4">
          Select a mood and the AI DJ will weave commentary between songs from your Apple Music library
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
              {mood === 'chill' && '🌀 Chill'}
              {mood === 'balanced' && '⚖️ Balanced'}
              {mood === 'hype' && '⚡ Hype'}
            </button>
          ))}
        </div>

        <button
          onClick={() => createRadioStation(selectedMood)}
          disabled={isLoading}
          className="w-full py-3 bg-gradient-to-r from-purple-500 to-pink-500 hover:from-purple-400 hover:to-pink-400 text-white font-semibold rounded-lg transition-colors disabled:opacity-50"
        >
          {isLoading ? 'Creating Station...' : '🚀 Start AI Radio'}
        </button>
      </div>

      {/* User's Playlists */}
      {playlists.length > 0 && (
        <div className="mb-8">
          <h3 className="text-lg font-semibold text-white mb-4">📚 Your Playlists</h3>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            {playlists.slice(0, 8).map((playlist) => (
              <div
                key={playlist.id}
                className="p-4 bg-zinc-900/50 rounded-xl hover:bg-zinc-800 transition-colors cursor-pointer group"
              >
                {playlist.artwork && (
                  <img 
                    src={playlist.artwork.url.replace('{w}', '200').replace('{h}', '200')}
                    alt={playlist.name}
                    className="w-full aspect-square object-cover rounded-lg mb-3"
                  />
                )}
                <p className="text-white font-medium truncate">{playlist.name}</p>
                <p className="text-zinc-500 text-sm">{playlist.trackCount} tracks</p>
              </div>
            ))}
          </div>
        </div>
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
    </>
  );
}

function HomeContent() {
  const { toggleSettings, commentaryEnabled, isPlaying } = useRadioStore();
  const [isLoading, setIsLoading] = useState(true);

  // Simulate initial loading
  useEffect(() => {
    const timer = setTimeout(() => setIsLoading(false), 1000);
    return () => clearTimeout(timer);
  }, []);

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
            <div className="w-10 h-10 bg-gradient-to-br from-red-500 to-pink-500 rounded-lg flex items-center justify-center">
              <span className="text-xl">🎵</span>
            </div>
            <div>
              <h1 className="text-xl font-bold">RAY.DO</h1>
              <p className="text-xs text-zinc-500">AI Radio DJ with Apple Music</p>
            </div>
          </div>

          <button
            onClick={toggleSettings}
            className="p-2 text-zinc-400 hover:text-white transition-colors"
          >
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <circle cx="12" cy="12" r="3" />
            </svg>
          </button>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-6xl mx-auto px-6 py-8 pb-32">
        <AppleMusicDashboard />

        {/* Visualizer */}
        <div className="mt-6">
          <Visualizer isPlaying={isPlaying} />
        </div>

        {/* Quick Stats */}
        <div className="mt-12 grid grid-cols-1 md:grid-cols-3 gap-4">
          <div className="p-4 bg-zinc-900 rounded-lg">
            <p className="text-zinc-400 text-sm">Currently Playing</p>
            <p className="text-white font-medium mt-1">AI Radio Station</p>
          </div>
          <div className="p-4 bg-zinc-900 rounded-lg">
            <p className="text-zinc-400 text-sm">AI Commentary</p>
            <p className="text-white font-medium mt-1">Weaving between tracks</p>
          </div>
          <div className="p-4 bg-zinc-900 rounded-lg">
            <p className="text-zinc-400 text-sm">Music Source</p>
            <p className="text-white font-medium mt-1">Your Apple Music Library</p>
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
      <HomeContent />
    </AppleMusicProvider>
  );
}
