'use client';

import { useState, useEffect } from 'react';
import { Settings } from './components/Settings';
import { Player } from './components/Player';
import { StationSelector } from './components/StationSelector';
import { Visualizer } from './components/Visualizer';
import { useRadioStore } from '@/lib/store/radio';

export default function Home() {
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
          <p className="text-zinc-400">Loading AI Radio DJ...</p>
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
              <span className="text-xl">🎵</span>
            </div>
            <div>
              <h1 className="text-xl font-bold">AI Radio DJ</h1>
              <p className="text-xs text-zinc-500">Your personal AI-hosted station</p>
            </div>
          </div>

          <button
            onClick={toggleSettings}
            className="p-2 text-zinc-400 hover:text-white transition-colors"
          >
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z" />
              <circle cx="12" cy="12" r="3" />
            </svg>
          </button>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-6xl mx-auto px-6 py-8 pb-32">
        {/* Welcome Message */}
        {!commentaryEnabled && (
          <div className="mb-8 p-4 bg-zinc-900 rounded-lg">
            <p className="text-zinc-400">
              💡 AI Commentary is disabled. Enable it in settings to hear track descriptions, news updates, and personalized commentary.
            </p>
          </div>
        )}

        <StationSelector />

        {/* Visualizer */}
        <div className="mt-6">
          <Visualizer isPlaying={isPlaying} />
        </div>

        {/* Quick Stats */}
        <div className="mt-12 grid grid-cols-1 md:grid-cols-3 gap-4">
          <div className="p-4 bg-zinc-900 rounded-lg">
            <p className="text-zinc-400 text-sm">Currently Playing</p>
            <p className="text-white font-medium mt-1">Select a station to start</p>
          </div>
          <div className="p-4 bg-zinc-900 rounded-lg">
            <p className="text-zinc-400 text-sm">AI Personality</p>
            <p className="text-white font-medium mt-1">Adaptive based on vibe</p>
          </div>
          <div className="p-4 bg-zinc-900 rounded-lg">
            <p className="text-zinc-400 text-sm">Message Injection</p>
            <p className="text-white font-medium mt-1">Ready for Telegram & Calendar</p>
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
