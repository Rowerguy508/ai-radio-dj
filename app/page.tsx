'use client';

import { useState, useEffect } from 'react';
import { Settings } from './components/Settings';
import { Player } from './components/Player';
import { StationSelector } from './components/StationSelector';
import { Visualizer } from './components/Visualizer';
import { useRadioStore } from '@/lib/store/radio';
import { AppleMusicProvider, useAppleMusic } from '@/lib/apple-music/player';
import { SpotifyProvider, useSpotify } from '@/lib/spotify/player';

function AppleMusicDashboard() {
  const { user, isAuthenticated, playlists, connectAppleMusic, disconnect, createRadioStation, isLoading } = useAppleMusic();
  const { isPlaying, currentTrack } = useRadioStore();
  const [selectedMood, setSelectedMood] = useState<'chill' | 'hype' | 'balanced'>('balanced');

  if (!isAuthenticated) {
    return (
      <div className="p-6 bg-gradient-to-r from-red-500/10 to-red-600/10 border border-red-500/20 rounded-xl">
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
      <div className="p-4 bg-zinc-900/50 rounded-xl flex items-center gap-4">
        <div className="w-12 h-12 bg-gradient-to-br from-red-500 to-pink-500 rounded-full flex items-center justify-center text-white font-bold">
          {user?.name?.charAt(0) || 'A'}
        </div>
        <div className="flex-1">
          <p className="text-white font-semibold">{user?.name || 'Apple Music User'}</p>
          <p className="text-zinc-400 text-sm">Apple Music Connected</p>
        </div>
        <button
          onClick={disconnect}
          className="px-4 py-2 text-zinc-400 hover:text-white hover:bg-zinc-800 rounded-lg transition-colors"
        >
          Disconnect
        </button>
      </div>

      {/* Mood Selector */}
      <div className="grid grid-cols-3 gap-4">
        {(['chill', 'balanced', 'hype'] as const).map((mood) => (
          <button
            key={mood}
            onClick={() => {
              setSelectedMood(mood);
              createRadioStation(mood);
            }}
            disabled={isLoading}
            className={`p-4 rounded-xl border transition-all ${
              selectedMood === mood
                ? 'bg-red-500/20 border-red-500/50 text-white'
                : 'bg-zinc-900/50 border-zinc-800 text-zinc-400 hover:border-zinc-700'
            } ${isLoading ? 'opacity-50 cursor-not-allowed' : ''}`}
          >
            <div className="text-2xl mb-2">
              {mood === 'chill' ? '😌' : mood === 'hype' ? '🔥' : '⚖️'}
            </div>
            <div className="font-medium capitalize">{mood}</div>
          </button>
        ))}
      </div>
    </>
  );
}

function SpotifyDashboard() {
  const { user, isAuthenticated, isPremium, playlists, connectSpotify, disconnect, createRadioStation, isLoading } = useSpotify();
  const { isPlaying, currentTrack } = useRadioStore();
  const [selectedMood, setSelectedMood] = useState<'chill' | 'hype' | 'balanced'>('balanced');

  if (!isAuthenticated) {
    return (
      <div className="p-6 bg-gradient-to-r from-green-500/10 to-green-600/10 border border-green-500/20 rounded-xl">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="text-lg font-semibold text-green-400 mb-1">🎵 Connect Spotify</h3>
            <p className="text-zinc-400">Sign in with Spotify to stream music and get personalized recommendations</p>
          </div>
          <button
            onClick={connectSpotify}
            className="px-6 py-3 bg-gradient-to-r from-green-500 to-green-600 hover:from-green-400 hover:to-green-500 text-white font-semibold rounded-lg transition-colors"
          >
            Connect Spotify
          </button>
        </div>
      </div>
    );
  }

  return (
    <>
      {/* User Header */}
      <div className="p-4 bg-zinc-900/50 rounded-xl flex items-center gap-4">
        <div className="w-12 h-12 bg-gradient-to-br from-green-500 to-green-600 rounded-full flex items-center justify-center text-white font-bold overflow-hidden">
          {user?.images?.[0]?.url ? (
            <img src={user.images[0].url} alt={user.display_name} className="w-full h-full object-cover" />
          ) : (
            user?.display_name?.charAt(0) || 'S'
          )}
        </div>
        <div className="flex-1">
          <p className="text-white font-semibold">{user?.display_name || 'Spotify User'}</p>
          <p className="text-zinc-400 text-sm">
            Spotify {isPremium ? 'Premium' : 'Free'} Connected
            {!isPremium && <span className="text-yellow-400 ml-2">(Preview mode - Premium required for full playback)</span>}
          </p>
        </div>
        <button
          onClick={disconnect}
          className="px-4 py-2 text-zinc-400 hover:text-white hover:bg-zinc-800 rounded-lg transition-colors"
        >
          Disconnect
        </button>
      </div>

      {/* Mood Selector */}
      <div className="grid grid-cols-3 gap-4">
        {(['chill', 'balanced', 'hype'] as const).map((mood) => (
          <button
            key={mood}
            onClick={() => {
              setSelectedMood(mood);
              createRadioStation(mood);
            }}
            disabled={isLoading}
            className={`p-4 rounded-xl border transition-all ${
              selectedMood === mood
                ? 'bg-green-500/20 border-green-500/50 text-white'
                : 'bg-zinc-900/50 border-zinc-800 text-zinc-400 hover:border-zinc-700'
            } ${isLoading ? 'opacity-50 cursor-not-allowed' : ''}`}
          >
            <div className="text-2xl mb-2">
              {mood === 'chill' ? '😌' : mood === 'hype' ? '🔥' : '⚖️'}
            </div>
            <div className="font-medium capitalize">{mood}</div>
          </button>
        ))}
      </div>

      {/* User Playlists */}
      {playlists.length > 0 && (
        <div className="mt-4">
          <h4 className="text-white font-semibold mb-3">Your Playlists</h4>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3 max-h-48 overflow-y-auto">
            {playlists.slice(0, 8).map((playlist) => (
              <div
                key={playlist.id}
                className="p-3 bg-zinc-900/50 rounded-lg hover:bg-zinc-800/50 cursor-pointer transition-colors"
              >
                <div className="aspect-square bg-zinc-800 rounded mb-2 overflow-hidden">
                  {playlist.images?.[0]?.url && (
                    <img src={playlist.images[0].url} alt={playlist.name} className="w-full h-full object-cover" />
                  )}
                </div>
                <p className="text-white text-sm font-medium truncate">{playlist.name}</p>
                <p className="text-zinc-400 text-xs">{playlist.tracks?.total || 0} tracks</p>
              </div>
            ))}
          </div>
        </div>
      )}
    </>
  );
}

function MainContent() {
  const { toggleSettings, currentTrack, isPlaying } = useRadioStore();
  const [activeService, setActiveService] = useState<'apple' | 'spotify' | null>(null);
  
  const appleMusic = useAppleMusic();
  const spotify = useSpotify();

  // Determine which service to show based on connection status
  useEffect(() => {
    if (spotify.isAuthenticated) {
      setActiveService('spotify');
    } else if (appleMusic.isAuthenticated) {
      setActiveService('apple');
    } else {
      setActiveService(null);
    }
  }, [spotify.isAuthenticated, appleMusic.isAuthenticated]);

  return (
    <main className="min-h-screen bg-black text-white">
      <div className="max-w-4xl mx-auto p-6 space-y-8">
        {/* Header */}
        <header className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-bold bg-gradient-to-r from-purple-400 via-pink-400 to-red-400 text-transparent bg-clip-text">
              RAY.DO
            </h1>
            <p className="text-zinc-400 mt-1">Your AI Radio DJ</p>
          </div>
          <button
            onClick={toggleSettings}
            className="p-3 rounded-xl bg-zinc-900 hover:bg-zinc-800 transition-colors"
          >
            ⚙️
          </button>
        </header>

        {/* Music Service Tabs */}
        <div className="flex gap-2 p-1 bg-zinc-900/50 rounded-xl">
          <button
            onClick={() => setActiveService('apple')}
            className={`flex-1 py-3 px-4 rounded-lg font-medium transition-all ${
              activeService === 'apple'
                ? 'bg-gradient-to-r from-red-500/20 to-pink-500/20 text-red-400 border border-red-500/30'
                : 'text-zinc-400 hover:text-white'
            }`}
          >
            🎧 Apple Music
          </button>
          <button
            onClick={() => setActiveService('spotify')}
            className={`flex-1 py-3 px-4 rounded-lg font-medium transition-all ${
              activeService === 'spotify'
                ? 'bg-gradient-to-r from-green-500/20 to-green-600/20 text-green-400 border border-green-500/30'
                : 'text-zinc-400 hover:text-white'
            }`}
          >
            🎵 Spotify
          </button>
        </div>

        {/* Music Service Dashboard */}
        <div className="space-y-4">
          {activeService === 'apple' ? (
            <AppleMusicDashboard />
          ) : activeService === 'spotify' ? (
            <SpotifyDashboard />
          ) : (
            <div className="space-y-4">
              <AppleMusicDashboard />
              <SpotifyDashboard />
            </div>
          )}
        </div>

        {/* Station Selector (for non-streaming mode) */}
        {!appleMusic.isAuthenticated && !spotify.isAuthenticated && (
          <StationSelector />
        )}

        {/* Now Playing / Visualizer */}
        {currentTrack && (
          <div className="space-y-4">
            <Visualizer />
          </div>
        )}

        {/* Player Controls */}
        <Player />

        {/* Settings Modal */}
        <Settings />
      </div>
    </main>
  );
}

export default function Home() {
  return (
    <AppleMusicProvider>
      <SpotifyProvider>
        <MainContent />
      </SpotifyProvider>
    </AppleMusicProvider>
  );
}
