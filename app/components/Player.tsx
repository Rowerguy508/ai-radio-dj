'use client';

import { useState, useEffect, useRef, useCallback } from 'react';
import { Play, Pause, SkipForward, SkipBack, Volume2, VolumeX, Mic, MicOff } from 'lucide-react';
import { useRadioStore } from '@/lib/store/radio';
import { useCommentary } from '@/lib/hooks/useCommentary';

export function Player() {
  const {
    isPlaying,
    currentTrack,
    queue,
    volume,
    commentaryEnabled,
    setIsPlaying,
    setVolume,
    nextTrack,
    toggleCommentary,
  } = useRadioStore();

  const { generateCommentaryAudio, resetTrackCount } = useCommentary();

  const audioRef = useRef<HTMLAudioElement | null>(null);
  const commentaryAudioRef = useRef<HTMLAudioElement | null>(null);
  const previousTrackRef = useRef(currentTrack);
  const [isMuted, setIsMuted] = useState(false);
  const [progress, setProgress] = useState(0);
  const [duration, setDuration] = useState(0);
  const [audioSrc, setAudioSrc] = useState<string | undefined>(undefined);
  const [isPlayingCommentary, setIsPlayingCommentary] = useState(false);

  // Update audio source when track changes
  useEffect(() => {
    if (currentTrack?.previewUrl !== audioSrc) {
      setAudioSrc(currentTrack?.previewUrl);
    }
  }, [currentTrack]);

  // Reset commentary count when station changes
  const currentStation = useRadioStore((s) => s.currentStation);
  useEffect(() => {
    resetTrackCount();
  }, [currentStation?.id, resetTrackCount]);

  // Play commentary between tracks, then advance
  const handleTrackEnd = useCallback(async () => {
    const prev = previousTrackRef.current;
    const nextInQueue = queue[0] || null;

    if (commentaryEnabled && currentTrack) {
      // Try to generate and play commentary
      const commentaryUrl = await generateCommentaryAudio(
        currentTrack,
        prev,
        nextInQueue,
      );

      if (commentaryUrl && commentaryAudioRef.current) {
        setIsPlayingCommentary(true);
        commentaryAudioRef.current.src = commentaryUrl;
        commentaryAudioRef.current.volume = isMuted ? 0 : volume;

        try {
          await commentaryAudioRef.current.play();
          // Wait for commentary to finish
          await new Promise<void>((resolve) => {
            const onEnd = () => {
              commentaryAudioRef.current?.removeEventListener('ended', onEnd);
              resolve();
            };
            commentaryAudioRef.current?.addEventListener('ended', onEnd);
          });
        } catch (e) {
          console.log('Commentary playback skipped:', e);
        }
        setIsPlayingCommentary(false);
      }
    }

    previousTrackRef.current = currentTrack;
    nextTrack();
  }, [commentaryEnabled, currentTrack, queue, generateCommentaryAudio, nextTrack, isMuted, volume]);

  // Handle play/pause and track changes
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;

    const handleEnded = () => handleTrackEnd();

    const handleCanPlay = () => {
      if (isPlaying && !isPlayingCommentary) {
        audio.play().catch((e) => console.log('Auto-play blocked:', e));
      }
    };

    audio.addEventListener('ended', handleEnded);
    audio.addEventListener('canplay', handleCanPlay);

    return () => {
      audio.removeEventListener('ended', handleEnded);
      audio.removeEventListener('canplay', handleCanPlay);
    };
  }, [handleTrackEnd, isPlaying, isPlayingCommentary]);

  // Handle volume
  useEffect(() => {
    const vol = isMuted ? 0 : volume;
    if (audioRef.current) audioRef.current.volume = vol;
    if (commentaryAudioRef.current) commentaryAudioRef.current.volume = vol;
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

  const handlePlayPause = async () => {
    if (!audioRef.current) {
      setIsPlaying(!isPlaying);
      return;
    }

    try {
      if (isPlaying) {
        audioRef.current.pause();
        if (commentaryAudioRef.current) commentaryAudioRef.current.pause();
      } else {
        if (isPlayingCommentary && commentaryAudioRef.current) {
          await commentaryAudioRef.current.play();
        } else {
          await audioRef.current.play();
        }
      }
      setIsPlaying(!isPlaying);
    } catch (e) {
      console.log('Play error:', e);
      audioRef.current.load();
      setTimeout(async () => {
        try {
          await audioRef.current?.play();
          setIsPlaying(true);
        } catch (e2) {
          console.log('Retry play failed:', e2);
        }
      }, 100);
    }
  };

  const handleNext = () => {
    // Skip commentary if playing
    if (isPlayingCommentary && commentaryAudioRef.current) {
      commentaryAudioRef.current.pause();
      commentaryAudioRef.current.src = '';
      setIsPlayingCommentary(false);
    }
    previousTrackRef.current = currentTrack;
    nextTrack();
  };

  const formatTime = (seconds: number) => {
    const mins = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  };

  const displayTrack = currentTrack || (queue.length > 0 ? queue[0] : null);

  return (
    <div className="fixed bottom-0 left-0 right-0 bg-zinc-900 border-t border-zinc-800 p-4 z-50">
      <audio ref={audioRef} src={audioSrc} preload="auto" />
      <audio ref={commentaryAudioRef} preload="auto" />

      {/* Commentary indicator */}
      {isPlayingCommentary && (
        <div className="mb-3 flex items-center gap-2 text-purple-400 text-sm">
          <Mic size={14} className="animate-pulse" />
          <span>AI DJ is speaking...</span>
        </div>
      )}

      {/* Track Info */}
      <div className="flex items-center gap-4 mb-4">
        {displayTrack?.artworkUrl && (
          <img
            src={displayTrack.artworkUrl}
            alt={displayTrack.title}
            className="w-14 h-14 rounded-lg object-cover"
            onError={(e) => {
              (e.target as HTMLImageElement).style.display = 'none';
            }}
          />
        )}
        <div className="flex-1 min-w-0">
          <h3 className="text-white font-medium truncate">{displayTrack?.title || 'No track playing'}</h3>
          <p className="text-zinc-400 text-sm truncate">{displayTrack?.artistName || 'Select a station to start'}</p>
        </div>
      </div>

      {/* Progress Bar */}
      <div className="mb-3">
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
            onClick={() => {/* previous track not implemented yet */}}
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
          {/* Commentary toggle */}
          <button
            onClick={toggleCommentary}
            className={`p-2 transition-colors ${commentaryEnabled ? 'text-purple-400 hover:text-purple-300' : 'text-zinc-600 hover:text-zinc-400'}`}
            title={commentaryEnabled ? 'DJ commentary on' : 'DJ commentary off'}
          >
            {commentaryEnabled ? <Mic size={18} /> : <MicOff size={18} />}
          </button>

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
