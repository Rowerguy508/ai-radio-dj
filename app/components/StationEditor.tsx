'use client';

import { useState, useEffect } from 'react';
import { X } from 'lucide-react';
import { useRadioStore, Station, createDefaultStation } from '@/lib/store/radio';

const STYLE_OPTIONS = [
  { value: 'chill', label: 'Chill', desc: 'Laid-back, smooth, late-night vibe', emoji: '\u{1F30A}' },
  { value: 'balanced', label: 'Balanced', desc: 'Conversational, warm, friendly', emoji: '\u{2728}' },
  { value: 'hype', label: 'Hype', desc: 'Energetic, excited, festival energy', emoji: '\u{1F525}' },
] as const;

const ENERGY_LABELS = ['Mellow', 'Easy', 'Medium', 'High', 'Max'];

export function StationEditor() {
  const { showStationEditor, editingStation, closeStationEditor, addStation } = useRadioStore();
  const [station, setStation] = useState<Station>(createDefaultStation());

  useEffect(() => {
    if (editingStation) setStation({ ...editingStation });
  }, [editingStation]);

  if (!showStationEditor) return null;

  const update = (patch: Partial<Station>) => setStation(s => ({ ...s, ...patch }));
  const isNew = editingStation?.name === 'My Station';

  const handleSave = () => {
    if (!station.name.trim()) return;
    addStation(station);
    closeStationEditor();
  };

  const energyLabel = ENERGY_LABELS[Math.min(Math.floor(station.energyLevel * 5), 4)];

  return (
    <div className="fixed inset-0 bg-black/80 backdrop-blur-md flex items-end sm:items-center justify-center z-50 animate-fade-in" onClick={closeStationEditor}>
      <div
        className="bg-zinc-900/95 backdrop-blur-xl rounded-t-3xl sm:rounded-3xl w-full sm:max-w-lg max-h-[90dvh] overflow-y-auto p-6 sm:p-8 sm:m-4 border border-white/[0.06] shadow-2xl animate-slide-up"
        onClick={e => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between mb-7">
          <div>
            <h2 className="text-lg font-semibold text-white">
              {isNew ? 'New Station' : 'Edit Station'}
            </h2>
            <p className="text-xs text-zinc-600 mt-0.5">
              {isNew ? 'Set up your custom radio station' : 'Update your station settings'}
            </p>
          </div>
          <button onClick={closeStationEditor} className="p-2 text-zinc-500 hover:text-white rounded-xl hover:bg-white/5 transition-all">
            <X size={18} />
          </button>
        </div>

        {/* Station Name */}
        <div className="mb-6">
          <label className="block text-xs text-zinc-500 uppercase tracking-[0.15em] mb-2 font-medium">Station Name</label>
          <input
            type="text"
            value={station.name}
            onChange={e => update({ name: e.target.value })}
            placeholder="e.g. Late Night Chill"
            className="w-full bg-zinc-800/40 border border-white/[0.06] rounded-xl px-4 py-3 text-white text-sm placeholder:text-zinc-600 focus:outline-none focus:border-violet-500/40 focus:ring-1 focus:ring-violet-500/20 transition-all"
          />
        </div>

        {/* What to play */}
        <div className="mb-6">
          <label className="block text-xs text-zinc-500 uppercase tracking-[0.15em] mb-2 font-medium">What should play?</label>
          <textarea
            value={station.searchQuery}
            onChange={e => update({ searchQuery: e.target.value })}
            placeholder="e.g. 90s hip hop, lo-fi beats, indie rock, jazz piano, Radiohead, Khruangbin..."
            rows={2}
            className="w-full bg-zinc-800/40 border border-white/[0.06] rounded-xl px-4 py-3 text-white text-sm placeholder:text-zinc-600 focus:outline-none focus:border-violet-500/40 focus:ring-1 focus:ring-violet-500/20 transition-all resize-none"
          />
          <p className="text-[11px] text-zinc-600 mt-1.5">Artists, genres, moods, or vibes — one per line or comma-separated.</p>
        </div>

        {/* DJ Style */}
        <div className="mb-6">
          <label className="block text-xs text-zinc-500 uppercase tracking-[0.15em] mb-3 font-medium">DJ Style</label>
          <div className="grid grid-cols-3 gap-2">
            {STYLE_OPTIONS.map(opt => (
              <button
                key={opt.value}
                onClick={() => update({ style: opt.value })}
                className={`text-center p-3 rounded-xl border transition-all duration-200 ${
                  station.style === opt.value
                    ? 'bg-violet-500/10 border-violet-500/30 shadow-inner shadow-violet-500/10'
                    : 'bg-zinc-800/30 border-white/[0.04] hover:border-white/[0.08]'
                }`}
              >
                <span className="text-xl mb-1 block">{opt.emoji}</span>
                <p className="text-sm text-white font-medium">{opt.label}</p>
                <p className="text-[10px] text-zinc-500 mt-0.5 leading-tight">{opt.desc}</p>
              </button>
            ))}
          </div>
        </div>

        {/* Energy */}
        <div className="mb-6">
          <div className="flex justify-between text-xs mb-2">
            <span className="text-zinc-500 uppercase tracking-[0.15em] font-medium">Energy</span>
            <span className="text-violet-400 font-medium">{energyLabel}</span>
          </div>
          <div className="relative">
            <div className="absolute inset-x-0 top-1/2 -translate-y-1/2 h-1 bg-zinc-800 rounded-full">
              <div
                className="h-full bg-gradient-to-r from-sky-500 via-violet-500 to-red-500 rounded-full transition-all"
                style={{ width: `${station.energyLevel * 100}%` }}
              />
            </div>
            <input
              type="range" min={0} max={1} step={0.05}
              value={station.energyLevel}
              onChange={e => update({ energyLevel: parseFloat(e.target.value) })}
              className="relative w-full opacity-0 cursor-pointer h-6"
            />
          </div>
        </div>

        {/* DJ Name */}
        <div className="mb-6">
          <label className="block text-xs text-zinc-500 uppercase tracking-[0.15em] mb-2 font-medium">DJ Name</label>
          <input
            type="text"
            value={station.djName}
            onChange={e => update({ djName: e.target.value })}
            placeholder="Ray"
            className="w-full bg-zinc-800/40 border border-white/[0.06] rounded-xl px-4 py-3 text-white text-sm placeholder:text-zinc-600 focus:outline-none focus:border-violet-500/40 focus:ring-1 focus:ring-violet-500/20 transition-all"
          />
        </div>

        {/* DJ Personality */}
        <div className="mb-8">
          <label className="block text-xs text-zinc-500 uppercase tracking-[0.15em] mb-2 font-medium">DJ Personality <span className="text-zinc-700 normal-case tracking-normal">(optional)</span></label>
          <textarea
            value={station.djPersonality}
            onChange={e => update({ djPersonality: e.target.value })}
            placeholder="e.g. Speaks with a slight Southern accent, loves dropping music trivia, occasionally makes dad jokes..."
            rows={2}
            className="w-full bg-zinc-800/40 border border-white/[0.06] rounded-xl px-4 py-3 text-white text-sm placeholder:text-zinc-600 focus:outline-none focus:border-violet-500/40 focus:ring-1 focus:ring-violet-500/20 transition-all resize-none"
          />
        </div>

        {/* Save */}
        <button
          onClick={handleSave}
          disabled={!station.name.trim()}
          className="w-full py-3.5 bg-gradient-to-r from-violet-500 to-fuchsia-500 text-white rounded-xl text-sm font-semibold active:scale-[0.98] transition-all disabled:opacity-30 shadow-lg shadow-violet-500/20 hover:shadow-violet-500/30"
        >
          {isNew ? 'Create Station' : 'Save Changes'}
        </button>
      </div>
    </div>
  );
}
