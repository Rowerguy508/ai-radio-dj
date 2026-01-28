'use client';

import { useState, useEffect, useRef } from 'react';
import { Play, Pause, SkipForward, SkipBack, Volume2, VolumeX, Settings } from 'lucide-react';
import { useRadioStore, Track } from '@/lib/store/radio';

export function Player() {
  const {
    isPlaying,
    currentTrack,
    volume,
    crossfadeDuration,
    setIsPlaying,
    setVolume,
    nextTrack,
  } = useRadioStore();

  const audioRef = useRef<HTMLAudioElement | null>(null);
  const [isMuted, setIsMuted] = useState(false);
  const [progress, setProgress] = useState(0);
  const [duration, setDuration] = useState(0);

  // Handle play/pause
  useEffect(() => {
    if (audioRef.current) {
      if (isPlaying) {
        audioRef.current.play();
      } else {
        audioRef.current.pause();
      }
    }
  }, [isPlaying]);

  // Handle volume
  useEffect(() => {
    if (audioRef.current) {
      audioRef.current.volume = isMuted ? 0 : volume;
    }
  }, [volume, isMuted]);

  // Track progress
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;

    const updateProgress = () => {
      setProgress(audio.currentTime);
      setDuration(audio.duration || 0);
    };

    audio.addEventListener('timeupdate', updateProgress);
    audio.addEventListener('loadedmetadata', updateProgress);

    return () => {
      audio.removeEventListener('timeupdate', updateProgress);
      audio.removeEventListener('loadedmetadata', updateProgress);
    };
  }, []);

  const handleSeek = (e: React.ChangeEvent<HTMLInputElement>) => {
    const time = parseFloat(e.target.value);
    if (audioRef.current) {
      audioRef.current.currentTime = time;
    }
    setProgress(time);
  };

  const formatTime = (seconds: number) => {
    const mins = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  };

  return (
    <div className="fixed bottom-0 left-0 right-0 bg-zinc-900 border-t border-zinc-800 p-4">
      <audio ref={audioRef} src={currentTrack?.previewUrl} />

      {/* Track Info */}
      <div className="flex items-center gap-4 mb-4">
        {currentTrack?.artworkUrl && (
          <img
            src={currentTrack.artworkUrl}
            alt={currentTrack.title}
            className="w-16 h-16 rounded-lg object-cover"
          />
        )}
        <div className="flex-1">
          <h3 className="text-white font-medium">{currentTrack?.title || 'No track playing'}</h3>
          <p className="text-zinc-400 text-sm">{currentTrack?.artistName || 'Select a station'}</p>
        </div>
      </div>

      {/* Progress Bar */}
      <div className="mb-4">
        <input
          type="range"
          min={0}
          max={duration || 100}
          value={progress}
          onChange={handleSeek}
          className="w-full h-1 bg-zinc-700 rounded-lg appearance-none cursor-pointer accent-white"
        />
        <div className="flex justify-between text-xs text-zinc-500 mt-1">
          <span>{formatTime(progress)}</span>
          <span>{formatTime(duration)}</span>
        </div>
      </div>

      {/* Controls */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <button className="p-2 text-zinc-400 hover:text-white transition-colors">
            <SkipBack size={20} />
          </button>
          <button
            onClick={() => setIsPlaying(!isPlaying)}
            className="p-3 bg-white rounded-full text-black hover:bg-zinc-200 transition-colors"
          >
            {isPlaying ? <Pause size={24} fill="currentColor" /> : <Play size={24} fill="currentColor" />}
          </button>
          <button
            onClick={nextTrack}
            className="p-2 text-zinc-400 hover:text-white transition-colors"
          >
            <SkipForward size={20} />
          </button>
        </div>

        <div className="flex items-center gap-2">
          <button
            onClick={() => setIsMuted(!isMuted)}
            className="p-2 text-zinc-400 hover:text-white transition-colors"
          >
            {isMuted ? <VolumeX size={20} /> : <Volume2 size={20} />}
          </button>
          <input
            type="range"
            min={0}
            max={1}
            step={0.1}
            value={isMuted ? 0 : volume}
            onChange={(e) => setVolume(parseFloat(e.target.value))}
            className="w-24 h-1 bg-zinc-700 rounded-lg appearance-none cursor-pointer accent-white"
          />
        </div>
      </div>
    </div>
  );
}
