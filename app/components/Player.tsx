'use client';

import { useState, useEffect, useRef, useCallback } from 'react';
import { Play, Pause, SkipForward, SkipBack, Volume2, VolumeX } from 'lucide-react';
import { useRadioStore, Track } from '@/lib/store/radio';
import { useAppleMusic } from '@/lib/apple-music/player';

export function Player() {
  const {
    isPlaying,
    currentTrack,
    queue,
    volume,
    setIsPlaying,
    setVolume,
    nextTrack,
  } = useRadioStore();
  
  const { play, pause, skip } = useAppleMusic();

  const [isMuted, setIsMuted] = useState(false);
  const [progress, setProgress] = useState(0);
  const [duration, setDuration] = useState(0);
  const [audioError, setAudioError] = useState<string | null>(null);
  const [useHtml5Audio, setUseHtml5Audio] = useState(false);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const progressInterval = useRef<NodeJS.Timeout | null>(null);

  // Detect if we should use HTML5 audio (demo tracks)
  useEffect(() => {
    if (currentTrack?.previewUrl?.includes('pixabay.com')) {
      setUseHtml5Audio(true);
    } else {
      setUseHtml5Audio(false);
    }
  }, [currentTrack]);

  // HTML5 Audio for demo tracks
  useEffect(() => {
    if (!useHtml5Audio || !currentTrack?.previewUrl) return;

    console.log('Setting up HTML5 audio for:', currentTrack.previewUrl);

    if (!audioRef.current) {
      audioRef.current = new Audio();
      audioRef.current.crossOrigin = 'anonymous';
      
      audioRef.current.addEventListener('ended', () => {
        console.log('HTML5 audio ended');
        nextTrack();
      });
      
      audioRef.current.addEventListener('canplay', () => {
        console.log('HTML5 audio can play');
      });
      
      audioRef.current.addEventListener('error', (e) => {
        console.log('HTML5 audio error:', audioRef.current?.error);
      });
    }

    audioRef.current.src = currentTrack.previewUrl;
    audioRef.current.load();

    if (isPlaying) {
      audioRef.current.play().catch(e => {
        console.log('HTML5 play error:', e);
        setAudioError('Click play to enable audio');
      });
    }

    return () => {
      if (audioRef.current) {
        audioRef.current.pause();
        audioRef.current.src = '';
      }
    };
  }, [useHtml5Audio, currentTrack, isPlaying, nextTrack]);

  // Play/Pause for HTML5 audio
  useEffect(() => {
    if (!useHtml5Audio || !audioRef.current) return;

    if (isPlaying) {
      audioRef.current.play().catch(e => {
        console.log('HTML5 play error:', e);
      });
    } else {
      audioRef.current.pause();
    }
  }, [isPlaying, useHtml5Audio]);

  // Progress tracking for HTML5 audio
  useEffect(() => {
    if (!useHtml5Audio) return;

    progressInterval.current = setInterval(() => {
      if (audioRef.current) {
        setProgress(audioRef.current.currentTime);
        setDuration(audioRef.current.duration || 0);
      }
    }, 500);

    return () => {
      if (progressInterval.current) {
        clearInterval(progressInterval.current);
      }
    };
  }, [useHtml5Audio]);

  // Volume for HTML5 audio
  useEffect(() => {
    if (audioRef.current) {
      audioRef.current.volume = isMuted ? 0 : volume;
    }
  }, [volume, isMuted]);

  const handleSeek = (e: React.ChangeEvent<HTMLInputElement>) => {
    const time = parseFloat(e.target.value);
    if (useHtml5Audio && audioRef.current) {
      audioRef.current.currentTime = time;
      setProgress(time);
    }
  };

  const handlePlayPause = useCallback(() => {
    if (useHtml5Audio) {
      if (isPlaying) {
        audioRef.current?.pause();
        setIsPlaying(false);
      } else {
        audioRef.current?.play().catch(e => {
          console.log('Play error:', e);
          setAudioError('Click failed. Try again.');
        });
        setIsPlaying(true);
      }
    } else {
      // Use Apple Music controls
      if (isPlaying) {
        pause();
        setIsPlaying(false);
      } else {
        play();
        setIsPlaying(true);
      }
    }
  }, [useHtml5Audio, isPlaying, setIsPlaying, play, pause]);

  const handleNext = useCallback(() => {
    // Dispatch skip event for tracking
    if (typeof window !== 'undefined') {
      window.dispatchEvent(new CustomEvent('raydo:skip'));
    }
    
    if (useHtml5Audio) {
      nextTrack();
    } else {
      skip();
      nextTrack();
    }
  }, [useHtml5Audio, skip, nextTrack]);

  const handlePrev = useCallback(() => {
    // Apple Music doesn't have a reliable "previous" - just restart current
    if (useHtml5Audio && audioRef.current) {
      audioRef.current.currentTime = 0;
      setProgress(0);
    }
  }, [useHtml5Audio]);

  const formatTime = (seconds: number) => {
    const mins = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  };

  const displayTrack = currentTrack || (queue.length > 0 ? queue[0] : null);

  return (
    <div className="fixed bottom-0 left-0 right-0 bg-zinc-900 border-t border-zinc-800 p-4 z-50">
      {/* Audio type indicator */}
      {useHtml5Audio && (
        <div className="mb-2 text-xs text-yellow-400">
          🎵 Demo Tracks (Pixabay)
        </div>
      )}

      {/* Error message */}
      {audioError && (
        <div className="mb-2 p-2 bg-red-500/20 text-red-400 text-xs rounded flex items-center justify-between">
          <span>{audioError}</span>
          <button onClick={() => setAudioError(null)} className="text-red-300">×</button>
        </div>
      )}

      {/* Track Info */}
      <div className="flex items-center gap-4 mb-4">
        {displayTrack?.artworkUrl && (
          <img
            src={displayTrack.artworkUrl}
            alt={displayTrack.title}
            className="w-16 h-16 rounded-lg object-cover"
            onError={(e) => {
              (e.target as HTMLImageElement).style.display = 'none';
            }}
          />
        )}
        <div className="flex-1">
          <h3 className="text-white font-medium">{displayTrack?.title || 'No track playing'}</h3>
          <p className="text-zinc-400 text-sm">{displayTrack?.artistName || 'Click Start AI Radio'}</p>
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
          <button 
            onClick={handlePrev}
            className="p-2 text-zinc-400 hover:text-white transition-colors"
          >
            <SkipBack size={20} />
          </button>
          <button
            onClick={handlePlayPause}
            className="p-3 bg-white rounded-full text-black hover:bg-zinc-200 transition-colors flex items-center justify-center"
          >
            {isPlaying ? <Pause size={24} fill="currentColor" /> : <Play size={24} fill="currentColor" />}
          </button>
          <button
            onClick={handleNext}
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
