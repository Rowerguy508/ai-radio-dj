'use client';

import { useState, useEffect } from 'react';
import { X } from 'lucide-react';
import { useRadioStore, Station, createDefaultStation } from '@/lib/store/radio';

const STYLE_OPTIONS = [
  { value: 'chill', label: 'Chill', desc: 'Laid-back, smooth, late-night vibe' },
  { value: 'balanced', label: 'Balanced', desc: 'Conversational, warm, friendly' },
  { value: 'hype', label: 'Hype', desc: 'Energetic, excited, festival energy' },
] as const;

export function StationEditor() {
  const { showStationEditor, editingStation, closeStationEditor, addStation } = useRadioStore();
  const [station, setStation] = useState<Station>(createDefaultStation());

  useEffect(() => {
    if (editingStation) setStation({ ...editingStation });
  }, [editingStation]);

  if (!showStationEditor) return null;

  const update = (patch: Partial<Station>) => setStation(s => ({ ...s, ...patch }));

  const handleSave = () => {
    if (!station.name.trim()) return;
    addStation(station);
    closeStationEditor();
  };

  return (
    <div className="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-end sm:items-center justify-center z-50" onClick={closeStationEditor}>
      <div className="bg-zinc-900 rounded-t-2xl sm:rounded-2xl w-full sm:max-w-lg max-h-[90dvh] overflow-y-auto p-6 sm:m-4" onClick={e => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-6">
          <h2 className="text-lg font-semibold text-white">
            {editingStation?.name === 'My Station' ? 'New Station' : 'Edit Station'}
          </h2>
          <button onClick={closeStationEditor} className="p-1.5 text-zinc-500 hover:text-white rounded-lg">
            <X size={18} />
          </button>
        </div>

        {/* Station Name */}
        <div className="mb-5">
          <label className="block text-xs text-zinc-500 uppercase tracking-wider mb-2">Station Name</label>
          <input
            type="text"
            value={station.name}
            onChange={e => update({ name: e.target.value })}
            placeholder="e.g. Late Night Chill"
            className="w-full bg-zinc-800/60 border border-white/5 rounded-xl px-4 py-3 text-white text-sm placeholder:text-zinc-600 focus:outline-none focus:border-violet-500/30"
          />
        </div>

        {/* What to play */}
        <div className="mb-5">
          <label className="block text-xs text-zinc-500 uppercase tracking-wider mb-2">What should play?</label>
          <textarea
            value={station.searchQuery}
            onChange={e => update({ searchQuery: e.target.value })}
            placeholder="e.g. 90s hip hop, lo-fi beats, indie rock, jazz piano, Radiohead, Khruangbin..."
            rows={2}
            className="w-full bg-zinc-800/60 border border-white/5 rounded-xl px-4 py-3 text-white text-sm placeholder:text-zinc-600 focus:outline-none focus:border-violet-500/30 resize-none"
          />
          <p className="text-[11px] text-zinc-600 mt-1">Artists, genres, moods, or vibes. The DJ will find matching tracks.</p>
        </div>

        {/* DJ Style */}
        <div className="mb-5">
          <label className="block text-xs text-zinc-500 uppercase tracking-wider mb-3">DJ Style</label>
          <div className="space-y-2">
            {STYLE_OPTIONS.map(opt => (
              <button
                key={opt.value}
                onClick={() => update({ style: opt.value })}
                className={`w-full text-left p-3 rounded-xl border transition-all ${
                  station.style === opt.value
                    ? 'bg-violet-500/10 border-violet-500/30'
                    : 'bg-zinc-800/40 border-white/5 hover:border-white/10'
                }`}
              >
                <p className="text-sm text-white font-medium">{opt.label}</p>
                <p className="text-xs text-zinc-500">{opt.desc}</p>
              </button>
            ))}
          </div>
        </div>

        {/* Energy */}
        <div className="mb-5">
          <div className="flex justify-between text-xs mb-2">
            <span className="text-zinc-500 uppercase tracking-wider">Energy</span>
            <span className="text-zinc-600">{Math.round(station.energyLevel * 100)}%</span>
          </div>
          <input
            type="range" min={0} max={1} step={0.05}
            value={station.energyLevel}
            onChange={e => update({ energyLevel: parseFloat(e.target.value) })}
            className="w-full"
          />
          <div className="flex justify-between text-[10px] text-zinc-600 mt-1">
            <span>Mellow</span><span>Medium</span><span>High</span>
          </div>
        </div>

        {/* DJ Name */}
        <div className="mb-5">
          <label className="block text-xs text-zinc-500 uppercase tracking-wider mb-2">DJ Name</label>
          <input
            type="text"
            value={station.djName}
            onChange={e => update({ djName: e.target.value })}
            placeholder="Ray"
            className="w-full bg-zinc-800/60 border border-white/5 rounded-xl px-4 py-3 text-white text-sm placeholder:text-zinc-600 focus:outline-none focus:border-violet-500/30"
          />
        </div>

        {/* DJ Personality (advanced, optional) */}
        <div className="mb-6">
          <label className="block text-xs text-zinc-500 uppercase tracking-wider mb-2">DJ Personality (optional)</label>
          <textarea
            value={station.djPersonality}
            onChange={e => update({ djPersonality: e.target.value })}
            placeholder="e.g. Speaks with a slight Southern accent, loves dropping music trivia, occasionally makes dad jokes..."
            rows={2}
            className="w-full bg-zinc-800/60 border border-white/5 rounded-xl px-4 py-3 text-white text-sm placeholder:text-zinc-600 focus:outline-none focus:border-violet-500/30 resize-none"
          />
        </div>

        {/* Save */}
        <button
          onClick={handleSave}
          disabled={!station.name.trim()}
          className="w-full py-3 bg-white text-black rounded-xl text-sm font-semibold active:scale-[0.98] transition-transform disabled:opacity-30"
        >
          Save Station
        </button>
      </div>
    </div>
  );
}
