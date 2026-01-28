'use client';

import { useState, useEffect } from 'react';
import { Settings } from './components/Settings';
import { Player } from './components/Player';
import { StationSelector } from './components/StationSelector';
import { useRadioStore } from '@/lib/store/radio';

export default function Home() {
  const { toggleSettings, commentaryEnabled } = useRadioStore();
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
            <Settings size={20} />
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
