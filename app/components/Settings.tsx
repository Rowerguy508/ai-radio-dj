'use client';

import { useState } from 'react';
import { X, Volume2, Mic, Sliders, Save, User, ChevronDown } from 'lucide-react';
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
    voices,
  } = useRadioStore();

  const [localStation, setLocalStation] = useState(currentStation);
  const [showVoiceDropdown, setShowVoiceDropdown] = useState(false);

  if (!showSettings) return null;

  const handleSaveStation = () => {
    if (localStation && currentStation?.id === localStation.id) {
      updateStation(currentStation.id, localStation);
    }
  };

  const selectedVoice = voices.find(v => v.voiceId === localStation?.voiceId) || voices[0];

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-zinc-900 rounded-xl w-full max-w-md p-6 m-4 max-h-[90vh] overflow-y-auto">
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

        {/* Voice Selection */}
        <div className="mb-6">
          <label className="flex items-center gap-3 text-zinc-400 text-sm mb-2">
            <User size={18} />
            AI Voice
          </label>
          
          <div className="relative">
            <button
              onClick={() => setShowVoiceDropdown(!showVoiceDropdown)}
              className="w-full flex items-center justify-between p-4 bg-zinc-800 rounded-lg hover:bg-zinc-700 transition-colors"
            >
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 rounded-full bg-gradient-to-br from-purple-500 to-pink-500 flex items-center justify-center">
                  <span className="text-white font-medium">{selectedVoice?.name[0]}</span>
                </div>
                <div className="text-left">
                  <p className="text-white font-medium">{selectedVoice?.name}</p>
                  <p className="text-zinc-500 text-xs">{selectedVoice?.personality}</p>
                </div>
              </div>
              <ChevronDown size={18} className={`text-zinc-400 transition-transform ${showVoiceDropdown ? 'rotate-180' : ''}`} />
            </button>

            {showVoiceDropdown && (
              <div className="absolute top-full left-0 right-0 mt-2 bg-zinc-800 rounded-lg overflow-hidden z-10 shadow-xl border border-zinc-700">
                {voices.map((voice) => (
                  <button
                    key={voice.id}
                    onClick={() => {
                      setLocalStation(localStation ? { ...localStation, voiceId: voice.voiceId, voiceName: voice.name } : null);
                      setShowVoiceDropdown(false);
                    }}
                    className={`w-full flex items-center gap-3 p-3 hover:bg-zinc-700 transition-colors ${
                      localStation?.voiceId === voice.voiceId ? 'bg-zinc-700' : ''
                    }`}
                  >
                    <div className="w-8 h-8 rounded-full bg-gradient-to-br from-purple-500 to-pink-500 flex items-center justify-center">
                      <span className="text-white text-sm font-medium">{voice.name[0]}</span>
                    </div>
                    <div className="text-left">
                      <p className="text-white text-sm">{voice.name}</p>
                      <p className="text-zinc-500 text-xs">{voice.personality}</p>
                    </div>
                  </button>
                ))}
              </div>
            )}
          </div>
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
