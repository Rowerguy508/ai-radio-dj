'use client';

import { X, Mic } from 'lucide-react';
import { useRadioStore } from '@/lib/store/radio';

export function Settings() {
  const {
    showSettings, toggleSettings, commentaryEnabled, toggleCommentary,
    currentStation, updateStation,
  } = useRadioStore();

  if (!showSettings) return null;

  return (
    <div className="fixed inset-0 bg-black/80 backdrop-blur-md flex items-end sm:items-center justify-center z-50 animate-fade-in" onClick={toggleSettings}>
      <div className="bg-zinc-900/95 backdrop-blur-xl rounded-t-3xl sm:rounded-3xl w-full sm:max-w-sm p-6 sm:p-7 sm:m-4 border border-white/[0.06] shadow-2xl animate-slide-up" onClick={e => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-6">
          <h2 className="text-lg font-semibold text-white">Settings</h2>
          <button onClick={toggleSettings} className="p-2 text-zinc-500 hover:text-white rounded-xl hover:bg-white/5 transition-all">
            <X size={18} />
          </button>
        </div>

        <button onClick={toggleCommentary} className="w-full flex items-center justify-between p-4 bg-zinc-800/30 rounded-xl mb-4 border border-white/[0.04] hover:border-white/[0.08] transition-all">
          <div className="flex items-center gap-3">
            <Mic size={16} className={commentaryEnabled ? 'text-violet-400' : 'text-zinc-600'} />
            <div className="text-left">
              <span className="text-sm text-white block">AI DJ Commentary</span>
              <span className="text-[11px] text-zinc-600">{commentaryEnabled ? 'DJ will introduce tracks' : 'Music only, no DJ'}</span>
            </div>
          </div>
          <div className={`w-11 h-6 rounded-full transition-all duration-200 flex items-center ${commentaryEnabled ? 'bg-violet-500 justify-end' : 'bg-zinc-700 justify-start'}`}>
            <div className="w-5 h-5 rounded-full bg-white mx-0.5 shadow-sm" />
          </div>
        </button>

        {currentStation && (
          <div className="mb-4 p-4 bg-zinc-800/30 rounded-xl border border-white/[0.04]">
            <div className="flex justify-between text-sm mb-3">
              <span className="text-zinc-400">Energy</span>
              <span className="text-violet-400 font-medium">{Math.round(currentStation.energyLevel * 100)}%</span>
            </div>
            <div className="relative">
              <div className="absolute inset-x-0 top-1/2 -translate-y-1/2 h-1 bg-zinc-700 rounded-full">
                <div
                  className="h-full bg-gradient-to-r from-sky-500 via-violet-500 to-red-500 rounded-full transition-all"
                  style={{ width: `${currentStation.energyLevel * 100}%` }}
                />
              </div>
              <input
                type="range" min={0} max={1} step={0.05}
                value={currentStation.energyLevel}
                onChange={e => updateStation(currentStation.id, { energyLevel: parseFloat(e.target.value) })}
                className="relative w-full opacity-0 cursor-pointer h-6"
              />
            </div>
          </div>
        )}

        <button
          onClick={toggleSettings}
          className="w-full py-3 bg-white/[0.08] hover:bg-white/[0.12] text-white rounded-xl text-sm font-medium mt-2 active:scale-[0.98] transition-all border border-white/[0.06]"
        >
          Done
        </button>
      </div>
    </div>
  );
}
