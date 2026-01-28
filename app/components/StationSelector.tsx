'use client';

import { useState } from 'react';
import { Plus, Zap, Wind, Coffee, Music, Settings, Play, Pause } from 'lucide-react';
import { useRadioStore, Station } from '@/lib/store/radio';

const STATION_TEMPLATES = [
  {
    name: 'Chill Focus',
    energy: 0.3,
    style: 'chill' as const,
    icon: Wind,
    color: 'from-blue-500 to-cyan-500',
    genres: ['lo-fi', 'ambient', 'jazz'],
  },
  {
    name: 'Hype Mode',
    energy: 0.8,
    style: 'hype' as const,
    icon: Zap,
    color: 'from-orange-500 to-red-500',
    genres: ['hip-hop', 'electronic', 'rock'],
  },
  {
    name: 'Morning Coffee',
    energy: 0.5,
    style: 'balanced' as const,
    icon: Coffee,
    color: 'from-yellow-500 to-amber-500',
    genres: ['pop', 'indie', 'acoustic'],
  },
  {
    name: 'Deep Dive',
    energy: 0.4,
    style: 'chill' as const,
    icon: Music,
    color: 'from-purple-500 to-pink-500',
    genres: ['electronic', 'techno', 'house'],
  },
];

export function StationSelector() {
  const { stations, currentStation, setCurrentStation, isPlaying, setIsPlaying, addStation } = useRadioStore();
  const [showCreate, setShowCreate] = useState(false);

  const handleSelectStation = (station: Station) => {
    setCurrentStation(station);
    setIsPlaying(true);
  };

  const handleCreateFromTemplate = (template: typeof STATION_TEMPLATES[0]) => {
    const newStation: Station = {
      id: `station-${Date.now()}`,
      name: template.name,
      energyLevel: template.energy,
      style: template.style,
      musicGenres: template.genres,
      includeMessages: true,
      includeCalendar: false,
      includeNews: true,
      isActive: true,
    };
    addStation(newStation);
    setShowCreate(false);
    setCurrentStation(newStation);
    setIsPlaying(true);
  };

  return (
    <div className="p-6">
      <div className="flex items-center justify-between mb-6">
        <h2 className="text-2xl font-bold text-white">Your Stations</h2>
        <button
          onClick={() => setShowCreate(!showCreate)}
          className="p-2 bg-zinc-800 rounded-lg hover:bg-zinc-700 transition-colors"
        >
          <Plus size={20} className="text-white" />
        </button>
      </div>

      {/* Station Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {/* Custom Stations */}
        {stations.map((station) => (
          <StationCard
            key={station.id}
            station={station}
            isActive={currentStation?.id === station.id}
            isPlaying={isPlaying && currentStation?.id === station.id}
            onClick={() => handleSelectStation(station)}
          />
        ))}

        {/* Template Stations (when creating) */}
        {showCreate &&
          STATION_TEMPLATES.map((template, index) => (
            <TemplateCard
              key={index}
              template={template}
              onClick={() => handleCreateFromTemplate(template)}
            />
          ))}
      </div>
    </div>
  );
}

interface StationCardProps {
  station: Station;
  isActive: boolean;
  isPlaying: boolean;
  onClick: () => void;
}

function StationCard({ station, isActive, isPlaying, onClick }: StationCardProps) {
  const energyGradient = station.energyLevel < 0.4
    ? 'from-blue-500 to-cyan-500'
    : station.energyLevel > 0.7
      ? 'from-orange-500 to-red-500'
      : 'from-purple-500 to-pink-500';

  return (
    <button
      onClick={onClick}
      className={`relative overflow-hidden rounded-xl p-6 text-left transition-all ${
        isActive
          ? 'ring-2 ring-white bg-zinc-800'
          : 'bg-zinc-900 hover:bg-zinc-800'
      }`}
    >
      {/* Background Gradient */}
      <div className={`absolute inset-0 bg-gradient-to-br ${energyGradient} opacity-10`} />

      {/* Content */}
      <div className="relative">
        <div className="flex items-center justify-between mb-4">
          <span className={`inline-block w-3 h-3 rounded-full ${
            isPlaying ? 'bg-green-500 animate-pulse' : 'bg-zinc-600'
          }`} />
          {isPlaying && (
            <div className="flex gap-1">
              {[1, 2, 3].map((i) => (
                <div
                  key={i}
                  className="w-1 bg-white animate-pulse"
                  style={{
                    height: `${Math.random() * 16 + 8}px`,
                    animationDelay: `${i * 0.1}s`,
                  }}
                />
              ))}
            </div>
          )}
        </div>

        <h3 className="text-lg font-semibold text-white mb-1">{station.name}</h3>
        <p className="text-zinc-400 text-sm">
          {station.energyLevel < 0.4 ? 'Chill' : station.energyLevel > 0.7 ? 'Hype' : 'Balanced'} • {station.style}
        </p>

        {/* Vibe Meter */}
        <div className="mt-4">
          <div className="flex items-center gap-2 text-xs text-zinc-500 mb-1">
            <span>Energy</span>
          </div>
          <div className="h-1.5 bg-zinc-700 rounded-full overflow-hidden">
            <div
              className={`h-full bg-gradient-to-r ${energyGradient} transition-all duration-300`}
              style={{ width: `${station.energyLevel * 100}%` }}
            />
          </div>
        </div>
      </div>
    </button>
  );
}

interface TemplateCardProps {
  template: typeof STATION_TEMPLATES[0];
  onClick: () => void;
}

function TemplateCard({ template, onClick }: TemplateCardProps) {
  const Icon = template.icon;

  return (
    <button
      onClick={onClick}
      className="relative overflow-hidden rounded-xl p-6 text-left bg-zinc-800 hover:bg-zinc-700 transition-all group"
    >
      <div className={`absolute inset-0 bg-gradient-to-br ${template.color} opacity-10 group-hover:opacity-20 transition-opacity`} />

      <div className="relative">
        <div className={`inline-flex p-2 rounded-lg bg-gradient-to-br ${template.color} mb-4`}>
          <Icon size={20} className="text-white" />
        </div>

        <h3 className="text-lg font-semibold text-white mb-1">{template.name}</h3>
        <p className="text-zinc-400 text-sm">
          {template.genres.join(', ')}
        </p>
        <p className="text-zinc-500 text-xs mt-2">Click to create station</p>
      </div>
    </button>
  );
}
