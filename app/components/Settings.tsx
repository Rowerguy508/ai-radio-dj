'use client';

import { useState } from 'react';
import { X, Volume2, Mic, Sliders, Save } from 'lucide-react';
import { useRadioStore } from '@/lib/store/radio';

export function Settings() {
  const {
    showSettings,
    toggleSettings,
    commentaryEnabled,
    toggleCommentary,
    crossfadeDuration,
    setCrossfadeDuration,
    currentStation,
    updateStation,
  } = useRadioStore();

  const [localStation, setLocalStation] = useState(currentStation);

  if (!showSettings) return null;

  const handleSaveStation = () => {
    if (localStation && currentStation?.id === localStation.id) {
      updateStation(currentStation.id, localStation);
    }
  };

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-zinc-900 rounded-xl w-full max-w-md p-6 m-4">
        {/* Header */}
        <div className="flex items-center justify-between mb-6">
          <h2 className="text-xl font-bold text-white">Settings</h2>
          <button
            onClick={toggleSettings}
            className="p-2 text-zinc-400 hover:text-white transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Commentary Toggle */}
        <div className="mb-6">
          <button
            onClick={toggleCommentary}
            className="w-full flex items-center justify-between p-4 bg-zinc-800 rounded-lg"
          >
            <div className="flex items-center gap-3">
              <Mic size={20} className={commentaryEnabled ? 'text-white' : 'text-zinc-500'} />
              <span className="text-white">AI Commentary</span>
            </div>
            <div className={`w-12 h-6 rounded-full transition-colors ${
              commentaryEnabled ? 'bg-green-500' : 'bg-zinc-600'
            }`}>
              <div className={`w-5 h-5 rounded-full bg-white mt-0.5 transition-transform ${
                commentaryEnabled ? 'translate-x-6' : 'translate-x-0.5'
              }`} />
            </div>
          </button>
        </div>

        {/* Crossfade Duration */}
        <div className="mb-6">
          <div className="flex items-center gap-3 mb-3">
            <Sliders size={20} className="text-zinc-400" />
            <span className="text-white">Crossfade Duration</span>
          </div>
          <input
            type="range"
            min={0}
            max={15}
            step={1}
            value={crossfadeDuration}
            onChange={(e) => setCrossfadeDuration(parseFloat(e.target.value))}
            className="w-full h-2 bg-zinc-700 rounded-lg appearance-none cursor-pointer accent-white"
          />
          <div className="flex justify-between text-xs text-zinc-500 mt-1">
            <span>Instant</span>
            <span>{crossfadeDuration}s</span>
            <span>15s</span>
          </div>
        </div>

        {/* Station Settings */}
        {currentStation && (
          <div className="mb-6">
            <h3 className="text-sm font-medium text-zinc-400 mb-3">
              {currentStation.name} Settings
            </h3>

            {/* Energy Slider */}
            <div className="mb-4">
              <label className="block text-white text-sm mb-2">
                Energy Level: {Math.round((localStation?.energyLevel || currentStation.energyLevel) * 100)}%
              </label>
              <input
                type="range"
                min={0}
                max={1}
                step={0.05}
                value={localStation?.energyLevel ?? currentStation.energyLevel}
                onChange={(e) => setLocalStation({
                  ...localStation!,
                  energyLevel: parseFloat(e.target.value),
                })}
                className="w-full h-2 bg-zinc-700 rounded-lg appearance-none cursor-pointer accent-white"
              />
              <div className="flex justify-between text-xs text-zinc-500 mt-1">
                <span>Chill</span>
                <span>Balanced</span>
                <span>Hype</span>
              </div>
            </div>

            {/* Style Selection */}
            <div className="mb-4">
              <label className="block text-white text-sm mb-2">Commentary Style</label>
              <div className="grid grid-cols-3 gap-2">
                {(['chill', 'balanced', 'hype'] as const).map((style) => (
                  <button
                    key={style}
                    onClick={() => setLocalStation({
                      ...localStation!,
                      style,
                    })}
                    className={`py-2 px-4 rounded-lg text-sm transition-colors ${
                      (localStation?.style ?? currentStation.style) === style
                        ? 'bg-white text-black'
                        : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'
                    }`}
                  >
                    {style.charAt(0).toUpperCase() + style.slice(1)}
                  </button>
                ))}
              </div>
            </div>

            {/* Toggles */}
            <div className="space-y-2">
              <label className="flex items-center justify-between p-3 bg-zinc-800 rounded-lg cursor-pointer">
                <span className="text-white text-sm">Include Messages</span>
                <input
                  type="checkbox"
                  checked={localStation?.includeMessages ?? currentStation.includeMessages}
                  onChange={(e) => setLocalStation({
                    ...localStation!,
                    includeMessages: e.target.checked,
                  })}
                  className="w-5 h-5 rounded border-zinc-600 bg-zinc-700 text-white focus:ring-white"
                />
              </label>

              <label className="flex items-center justify-between p-3 bg-zinc-800 rounded-lg cursor-pointer">
                <span className="text-white text-sm">Include Calendar</span>
                <input
                  type="checkbox"
                  checked={localStation?.includeCalendar ?? currentStation.includeCalendar}
                  onChange={(e) => setLocalStation({
                    ...localStation!,
                    includeCalendar: e.target.checked,
                  })}
                  className="w-5 h-5 rounded border-zinc-600 bg-zinc-700 text-white focus:ring-white"
                />
              </label>

              <label className="flex items-center justify-between p-3 bg-zinc-800 rounded-lg cursor-pointer">
                <span className="text-white text-sm">Include News</span>
                <input
                  type="checkbox"
                  checked={localStation?.includeNews ?? currentStation.includeNews}
                  onChange={(e) => setLocalStation({
                    ...localStation!,
                    includeNews: e.target.checked,
                  })}
                  className="w-5 h-5 rounded border-zinc-600 bg-zinc-700 text-white focus:ring-white"
                />
              </label>
            </div>
          </div>
        )}

        {/* Save Button */}
        <button
          onClick={handleSaveStation}
          className="w-full flex items-center justify-center gap-2 py-3 bg-white text-black rounded-lg font-medium hover:bg-zinc-200 transition-colors"
        >
          <Save size={18} />
          Save Settings
        </button>
      </div>
    </div>
  );
}
