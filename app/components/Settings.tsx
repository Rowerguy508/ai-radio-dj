'use client';

import { X, Mic } from 'lucide-react';
import { useRadioStore } from '@/lib/store/radio';

export function Settings() {
  const {
    showSettings, toggleSettings, commentaryEnabled, toggleCommentary,
    crossfadeDuration, setCrossfadeDuration, currentStation, updateStation,
  } = useRadioStore();

  if (!showSettings) return null;

  return (
    <div className="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-end sm:items-center justify-center z-50" onClick={toggleSettings}>
      <div className="bg-zinc-900 rounded-t-2xl sm:rounded-2xl w-full sm:max-w-sm p-6 sm:m-4 safe-bottom" onClick={e => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-6">
          <h2 className="text-lg font-semibold text-white">Settings</h2>
          <button onClick={toggleSettings} className="p-1.5 text-zinc-500 hover:text-white rounded-lg">
            <X size={18} />
          </button>
        </div>

        {/* AI Commentary */}
        <button onClick={toggleCommentary} className="w-full flex items-center justify-between p-3.5 bg-zinc-800/60 rounded-xl mb-4">
          <div className="flex items-center gap-3">
            <Mic size={16} className={commentaryEnabled ? 'text-violet-400' : 'text-zinc-600'} />
            <span className="text-sm text-white">AI DJ Commentary</span>
          </div>
          <div className={`w-10 h-5 rounded-full transition-colors flex items-center ${commentaryEnabled ? 'bg-violet-500 justify-end' : 'bg-zinc-700 justify-start'}`}>
            <div className="w-4 h-4 rounded-full bg-white mx-0.5" />
          </div>
        </button>

        {/* Crossfade */}
        <div className="mb-4">
          <div className="flex justify-between text-sm mb-2">
            <span className="text-zinc-400">Crossfade</span>
            <span className="text-zinc-500">{crossfadeDuration}s</span>
          </div>
          <input type="range" min={0} max={15} step={1} value={crossfadeDuration} onChange={e => setCrossfadeDuration(parseFloat(e.target.value))} className="w-full" />
        </div>

        {/* Station energy */}
        {currentStation && (
          <div className="mb-4">
            <div className="flex justify-between text-sm mb-2">
              <span className="text-zinc-400">Energy</span>
              <span className="text-zinc-500">{Math.round(currentStation.energyLevel * 100)}%</span>
            </div>
            <input type="range" min={0} max={1} step={0.05} value={currentStation.energyLevel} onChange={e => updateStation(currentStation.id, { energyLevel: parseFloat(e.target.value) })} className="w-full" />
          </div>
        )}

        <button onClick={toggleSettings} className="w-full py-2.5 bg-white text-black rounded-xl text-sm font-medium mt-2 active:scale-[0.98] transition-transform">
          Done
        </button>
      </div>
    </div>
  );
}
