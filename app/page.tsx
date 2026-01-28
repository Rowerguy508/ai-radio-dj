'use client';

import { useState, useEffect, useRef } from 'react';
import { Settings } from './components/Settings';
import { Player } from './components/Player';
import { StationSelector } from './components/StationSelector';
import { Visualizer } from './components/Visualizer';
import { useRadioStore } from '@/lib/store/radio';
import { AppleMusicProvider, useAppleMusic } from '@/lib/apple-music/player';

const GENRES = [
  'pop', 'rock', 'hip-hop', 'electronic', 'jazz', 'classical', 'r&b', 
  'country', 'indie', 'alternative', 'metal', 'punk', 'reggae', 'blues',
  'lo-fi', 'chill', 'ambient', 'dance', 'latin', 'folk', 'acoustic',
  // Latin genres
  'salsa', 'reggae', 'bachata', 'merengue', 'cumbia', 'latin pop', 
  'latin rock', 'timba', 'bolero', 'vallenato', 'banda', 'ranchera',
  'norteño', 'corridos', 'urbano latino', 'dembow', 'latin hip-hop'
];

const POPULAR_ARTISTS = [
  'Drake', 'Taylor Swift', 'The Weeknd', 'Bad Bunny', 'Ed Sheeran',
  'Dua Lipa', 'Post Malone', 'Billie Eilish', 'Harry Styles', 'Beyoncé',
  'Kendrick Lamar', 'Ariana Grande', 'Bruno Mars', 'SZA', 'Travis Scott',
  // Latin artists
  'J Balvin', 'Daddy Yankee', 'Ozuna', 'Karol G', 'Rauw Alejandro',
  'Romeo Santos', 'Aventura', 'Marc Anthony', 'Shakira', 'Enrique Iglesias',
  'Wisin', 'Yandel', 'Farruko', 'Natti Natasha', 'Becky G', 'Maluma',
  'Feid', 'Peso Pluma', 'Grupo Frontera', 'Fuerza Regida', 'Los Tigres del Norte',
  'Calibre 50', 'Junior H', 'Natanael Cano', 'Yng Lvcas', 'Xavi'
];

function AppleMusicDashboard() {
  const { user, isAuthenticated, playlists = [], connectAppleMusic, disconnect, createRadioStation, isLoading, error } = useAppleMusic();
  const { isPlaying, currentTrack } = useRadioStore();
  const [selectedMood, setSelectedMood] = useState<'chill' | 'hype' | 'balanced'>('balanced');
  const [selectedGenres, setSelectedGenres] = useState<string[]>(['pop']);
  const [artistQuery, setArtistQuery] = useState('');
  const [customArtists, setCustomArtists] = useState<string[]>([]);
  const [showCustomize, setShowCustomize] = useState(false);
  const [timeSuggestion, setTimeSuggestion] = useState<'chill' | 'hype' | 'balanced' | null>(null);

  // Time-based mood suggestion
  useEffect(() => {
    const hour = new Date().getHours();
    
    // Morning (5-11): chill/start fresh
    if (hour >= 5 && hour < 11) {
      setTimeSuggestion('chill');
    }
    // Afternoon (11-17): balanced/energetic
    else if (hour >= 11 && hour < 17) {
      setTimeSuggestion('balanced');
    }
    // Evening/Night (17-5): hype/wind down based on preference
    else {
      setTimeSuggestion('hype');
    }
  }, []);

  if (!isAuthenticated) {
    return (
      <>
        {/* Apple Music */}
        <div className="mb-4 p-6 bg-gradient-to-r from-red-500/10 to-red-600/10 border border-red-500/20 rounded-xl">
          <div className="flex items-center justify-between">
            <div>
              <h3 className="text-lg font-semibold text-red-400 mb-1">🎧 Apple Music</h3>
              <p className="text-zinc-400">Sign in with Apple Music to stream real music</p>
            </div>
              <button
                onClick={connectAppleMusic}
                className="px-6 py-3 bg-gradient-to-r from-red-500 to-pink-500 hover:from-red-400 hover:to-pink-400 text-white font-semibold rounded-lg transition-colors"
              >
                Connect
              </button>
          </div>
          {error && (
            <div className="mt-4 p-3 bg-red-500/20 border border-red-500/30 rounded-lg">
              <p className="text-red-400 text-sm">{error}</p>
            </div>
          )}
        </div>

        {/* Spotify - Coming Soon */}
        <div className="mb-8 p-6 bg-gradient-to-r from-green-500/10 to-green-600/10 border border-green-500/20 rounded-xl opacity-75">
          <div className="flex items-center justify-between">
            <div>
              <h3 className="text-lg font-semibold text-green-400 mb-1">🎵 Spotify</h3>
              <p className="text-zinc-400">Connect your Spotify library for AI radio</p>
            </div>
              <button
                onClick={() => alert('Spotify integration coming soon!')}
                className="px-6 py-3 bg-zinc-800 text-zinc-500 font-semibold rounded-lg cursor-not-allowed"
              >
                Coming Soon
              </button>
          </div>
        </div>
      </>
    );
  }

  const handleGenreToggle = (genre: string) => {
    setSelectedGenres(prev => 
      prev.includes(genre) 
        ? prev.filter(g => g !== genre)
        : [...prev, genre].slice(0, 3)
    );
  };

  const handleAddArtist = () => {
    if (artistQuery.trim() && !customArtists.includes(artistQuery.trim())) {
      setCustomArtists(prev => [...prev, artistQuery.trim()].slice(0, 5));
      setArtistQuery('');
    }
  };

  const handleRemoveArtist = (artist: string) => {
    setCustomArtists(prev => prev.filter(a => a !== artist));
  };

  const handleCreateStation = () => {
    // Combine mood, genres, and artists
    const stationConfig = {
      mood: selectedMood,
      genres: selectedGenres,
      artists: customArtists
    };
    console.log('Creating station with:', stationConfig);
    createRadioStation(selectedMood);
  };

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

      {/* Station Customizer */}
      <div className="mb-8 p-6 bg-zinc-900/50 rounded-xl">
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-lg font-semibold text-white">🎛️ Customize Your Station</h3>
          <button 
            onClick={() => setShowCustomize(!showCustomize)}
            className="text-zinc-400 hover:text-white text-sm"
          >
            {showCustomize ? 'Hide' : 'Customize'}
          </button>
        </div>

        {showCustomize && (
          <div className="space-y-6">
            {/* Mood Selection */}
            <div>
              <p className="text-zinc-400 text-sm mb-2">🎭 Mood</p>
              <div className="flex gap-3 flex-wrap">
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
              {timeSuggestion && timeSuggestion !== selectedMood && (
                <button
                  onClick={() => setSelectedMood(timeSuggestion)}
                  className="mt-2 text-xs text-purple-400 hover:text-purple-300 transition-colors"
                >
                  💡 {timeSuggestion === 'chill' ? 'Morning vibes?' : timeSuggestion === 'hype' ? 'Night owl energy?' : 'Afternoon mix?'} Click to apply
                </button>
              )}
            </div>

            {/* Genre Selection */}
            <div>
              <p className="text-zinc-400 text-sm mb-2">🎸 Genres (select up to 3)</p>
              <div className="flex gap-2 flex-wrap">
                {GENRES.slice(0, 15).map((genre) => (
                  <button
                    key={genre}
                    onClick={() => handleGenreToggle(genre)}
                    className={`px-3 py-1 rounded-full text-sm transition-colors ${
                      selectedGenres.includes(genre)
                        ? 'bg-red-500 text-white'
                        : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'
                    }`}
                  >
                    {genre}
                  </button>
                ))}
              </div>
              <p className="text-zinc-500 text-xs mt-2">Selected: {selectedGenres.join(', ') || 'none'}</p>
            </div>

            {/* Custom Artists */}
            <div>
              <p className="text-zinc-400 text-sm mb-2">👤 Add Artists</p>
              <div className="flex gap-2 mb-2">
                <input
                  type="text"
                  value={artistQuery}
                  onChange={(e) => setArtistQuery(e.target.value)}
                  onKeyDown={(e) => e.key === 'Enter' && handleAddArtist()}
                  placeholder="Search for an artist..."
                  className="flex-1 bg-zinc-800 text-white px-4 py-2 rounded-lg focus:outline-none focus:ring-2 focus:ring-red-500"
                />
                <button
                  onClick={handleAddArtist}
                  className="px-4 py-2 bg-zinc-700 hover:bg-zinc-600 text-white rounded-lg"
                >
                  Add
                </button>
              </div>
              
              {/* Popular Artists Quick Add */}
              <div className="mb-3">
                <p className="text-zinc-500 text-xs mb-2">Popular:</p>
                <div className="flex gap-2 flex-wrap">
                  {POPULAR_ARTISTS.slice(0, 8).map((artist) => (
                    <button
                      key={artist}
                      onClick={() => {
                        if (!customArtists.includes(artist)) {
                          setCustomArtists(prev => [...prev, artist].slice(0, 5));
                        }
                      }}
                      className="px-2 py-1 bg-zinc-800 hover:bg-zinc-700 text-zinc-400 text-xs rounded"
                    >
                      + {artist}
                    </button>
                  ))}
                </div>
              </div>

              {/* Selected Artists */}
              {customArtists.length > 0 && (
                <div className="flex gap-2 flex-wrap">
                  {customArtists.map((artist) => (
                    <span key={artist} className="flex items-center gap-2 px-3 py-1 bg-red-500/20 text-red-400 rounded-full text-sm">
                      {artist}
                      <button onClick={() => handleRemoveArtist(artist)} className="hover:text-white">×</button>
                    </span>
                  ))}
                </div>
              )}
            </div>
          </div>
        )}
      </div>

      {/* Quick Start */}
      <div className="mb-8 p-6 bg-zinc-900/50 rounded-xl">
        <h3 className="text-lg font-semibold text-white mb-4">🚀 Quick Start AI Radio</h3>
        <p className="text-zinc-400 text-sm mb-4">
          {customArtists.length > 0 
            ? `AI Radio with ${selectedGenres.join(', ')} + ${customArtists.join(', ')}`
            : `AI Radio mixing ${selectedGenres.join(', ')} songs`
          }
          {' '}- {selectedMood} mood with AI commentary
        </p>
        
        <button
          onClick={handleCreateStation}
          disabled={isLoading || selectedGenres.length === 0}
          className="w-full py-3 bg-gradient-to-r from-purple-500 to-pink-500 hover:from-purple-400 hover:to-pink-400 text-white font-semibold rounded-lg transition-colors disabled:opacity-50"
        >
          {isLoading ? 'Creating Station...' : '🎵 Start AI Radio'}
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
                className="p-4 bg-zinc-900/50 rounded-xl hover:bg-zinc-800 transition-colors cursor-pointer"
              >
                {playlist.artwork && (
                  <img 
                    src={playlist.artwork.url?.replace('{w}', '200').replace('{h}', '200')}
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
  const { toggleSettings, isPlaying } = useRadioStore();
  const [isLoading, setIsLoading] = useState(true);

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
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <circle cx="12" cy="12" r="3" />
            </svg>
          </button>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-6xl mx-auto px-6 py-8 pb-32">
        <AppleMusicDashboard />
        <Visualizer isPlaying={isPlaying} />
      </main>

      <Player />
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
