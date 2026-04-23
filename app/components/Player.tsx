'use client';

import { useState, useEffect, useRef, useCallback } from 'react';
import { Play, Pause, SkipForward, Volume2, VolumeX, Mic } from 'lucide-react';
import { useRadioStore } from '@/lib/store/radio';
import { useCommentary } from '@/lib/hooks/useCommentary';

export function Player() {
  const {
    isPlaying, currentTrack, queue, volume, commentaryEnabled, djIntroPlayed,
    setIsPlaying, setVolume, nextTrack, setDjIntroPlayed,
  } = useRadioStore();

  const { generateIntro, generateTransition, resetTrackCount } = useCommentary();
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const commentaryAudioRef = useRef<HTMLAudioElement | null>(null);
  const previousTrackRef = useRef(currentTrack);
  const introPlayedRef = useRef(false);
  const [isMuted, setIsMuted] = useState(false);
  const [progress, setProgress] = useState(0);
  const [duration, setDuration] = useState(0);
  const [audioSrc, setAudioSrc] = useState<string | undefined>(undefined);
  const [djSpeaking, setDjSpeaking] = useState(false);

  const currentStation = useRadioStore((s) => s.currentStation);

  // Reset on station change
  useEffect(() => {
    resetTrackCount();
    introPlayedRef.current = false;
  }, [currentStation?.id, resetTrackCount]);

  // Play DJ intro when a new station starts, BEFORE first track
  useEffect(() => {
    // Wait until we have a track and station, and intro hasn't played yet
    if (!currentTrack || !currentStation) return;
    if (djIntroPlayed || introPlayedRef.current) return;

    introPlayedRef.current = true;

    if (!commentaryEnabled) {
      // Skip intro, go straight to music
      setDjIntroPlayed(true);
      return;
    }

    let cancelled = false;

    const playIntro = async () => {
      try {
        const audioUrl = await generateIntro(currentTrack);
        if (cancelled) return;

        if (audioUrl && audioUrl !== 'browser-tts') {
          setDjSpeaking(true);
          await playAudioUrl(audioUrl);
          if (!cancelled) setDjSpeaking(false);
        } else if (audioUrl === 'browser-tts') {
          setDjSpeaking(true);
          await waitForBrowserTTS();
          if (!cancelled) setDjSpeaking(false);
        }
      } catch (e) {
        console.error('DJ intro failed:', e);
        setDjSpeaking(false);
      }

      if (cancelled) return;

      // Mark intro as done and start the music
      setDjIntroPlayed(true);
      if (audioRef.current && currentTrack?.previewUrl) {
        setAudioSrc(currentTrack.previewUrl);
        setTimeout(() => {
          audioRef.current?.load();
          audioRef.current?.play().catch(() => {});
        }, 200);
      }
    };

    // Small delay to let React finish rendering before starting async work
    const timer = setTimeout(() => playIntro(), 300);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [currentTrack?.id, currentStation?.id, djIntroPlayed]);

  // Load track audio (only after intro is done)
  useEffect(() => {
    if (!djIntroPlayed) return;
    if (currentTrack?.previewUrl && currentTrack.previewUrl !== audioSrc) {
      setAudioSrc(currentTrack.previewUrl);
      setTimeout(() => {
        if (audioRef.current && isPlaying) {
          audioRef.current.load();
          audioRef.current.play().catch(() => {});
        }
      }, 100);
    } else if (!currentTrack) {
      setAudioSrc(undefined);
    }
  }, [currentTrack, djIntroPlayed]);

  // Helper: play an audio URL and wait for it to finish
  const playAudioUrl = useCallback((url: string): Promise<void> => {
    return new Promise((resolve) => {
      const audio = commentaryAudioRef.current;
      if (!audio) { resolve(); return; }
      audio.src = url;
      audio.volume = isMuted ? 0 : volume;
      const onEnd = () => { audio.removeEventListener('ended', onEnd); resolve(); };
      audio.addEventListener('ended', onEnd);
      audio.play().catch(() => resolve());
    });
  }, [isMuted, volume]);

  // Helper: wait for browser TTS to finish
  const waitForBrowserTTS = useCallback((): Promise<void> => {
    return new Promise((resolve) => {
      const check = () => window.speechSynthesis?.speaking ? setTimeout(check, 200) : resolve();
      setTimeout(check, 500);
    });
  }, []);

  // When a track ends: play transition commentary, then next track
  const handleTrackEnd = useCallback(async () => {
    const prev = previousTrackRef.current;
    const nextInQueue = queue[0] || null;

    if (commentaryEnabled && currentTrack && nextInQueue) {
      const url = await generateTransition(currentTrack, prev, nextInQueue);
      if (url === 'browser-tts') {
        setDjSpeaking(true);
        await waitForBrowserTTS();
        setDjSpeaking(false);
      } else if (url) {
        setDjSpeaking(true);
        await playAudioUrl(url);
        setDjSpeaking(false);
      }
    }

    previousTrackRef.current = currentTrack;
    nextTrack();
  }, [commentaryEnabled, currentTrack, queue, generateTransition, nextTrack, playAudioUrl, waitForBrowserTTS]);

  // Audio element events
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;
    const onEnded = () => handleTrackEnd();
    const onCanPlay = () => { if (isPlaying && !djSpeaking && djIntroPlayed) audio.play().catch(() => {}); };
    const onError = () => {
      console.warn('Audio load failed, skipping to next track');
      previousTrackRef.current = currentTrack;
      nextTrack();
    };
    audio.addEventListener('ended', onEnded);
    audio.addEventListener('canplay', onCanPlay);
    audio.addEventListener('error', onError);
    return () => { audio.removeEventListener('ended', onEnded); audio.removeEventListener('canplay', onCanPlay); audio.removeEventListener('error', onError); };
  }, [handleTrackEnd, isPlaying, djSpeaking, djIntroPlayed, currentTrack, nextTrack]);

  // Volume sync
  useEffect(() => {
    const v = isMuted ? 0 : volume;
    if (audioRef.current) audioRef.current.volume = v;
    if (commentaryAudioRef.current) commentaryAudioRef.current.volume = v;
  }, [volume, isMuted]);

  // Progress tracking
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;
    const update = () => { setProgress(audio.currentTime); setDuration(audio.duration || 0); };
    audio.addEventListener('timeupdate', update);
    audio.addEventListener('loadedmetadata', update);
    return () => { audio.removeEventListener('timeupdate', update); audio.removeEventListener('loadedmetadata', update); };
  }, []);

  const handlePlayPause = async () => {
    if (!audioRef.current) { setIsPlaying(!isPlaying); return; }
    try {
      if (isPlaying) { audioRef.current.pause(); } else { await audioRef.current.play(); }
      setIsPlaying(!isPlaying);
    } catch {
      audioRef.current.load();
      setTimeout(async () => { try { await audioRef.current?.play(); setIsPlaying(true); } catch {} }, 100);
    }
  };

  const handleSeek = (e: React.ChangeEvent<HTMLInputElement>) => {
    const t = parseFloat(e.target.value);
    if (audioRef.current) audioRef.current.currentTime = t;
    setProgress(t);
  };

  const handleSkip = () => {
    if (djSpeaking && commentaryAudioRef.current) {
      commentaryAudioRef.current.pause();
      commentaryAudioRef.current.src = '';
      window.speechSynthesis?.cancel();
      setDjSpeaking(false);
    }
    previousTrackRef.current = currentTrack;
    nextTrack();
  };

  const fmt = (s: number) => `${Math.floor(s / 60)}:${Math.floor(s % 60).toString().padStart(2, '0')}`;
  const track = currentTrack || (queue.length > 0 ? queue[0] : null);

  if (!track) return null;

  return (
    <div className="fixed bottom-0 inset-x-0 z-50">
      <audio ref={audioRef} src={audioSrc} preload="auto" />
      <audio ref={commentaryAudioRef} preload="auto" />

      <div className="bg-zinc-950/95 backdrop-blur-xl border-t border-white/5 px-4 pt-3 pb-4 sm:px-6">
        {djSpeaking && (
          <div className="flex items-center gap-1.5 text-violet-400 text-xs mb-2">
            <Mic size={12} className="animate-pulse" />
            <span>{currentStation?.djName || 'DJ'} is on the mic...</span>
          </div>
        )}

        <div className="flex items-center gap-3">
          {track.artworkUrl && (
            <img src={track.artworkUrl} alt="" className="w-10 h-10 rounded-lg object-cover flex-shrink-0" onError={e => { (e.target as HTMLImageElement).style.display = 'none'; }} />
          )}
          <div className="flex-1 min-w-0">
            <p className="text-white text-sm font-medium truncate">{track.title}</p>
            <p className="text-zinc-500 text-xs truncate">{track.artistName}</p>
          </div>
          <div className="flex items-center gap-1 flex-shrink-0">
            <button onClick={handlePlayPause} className="w-10 h-10 flex items-center justify-center rounded-full bg-white text-black active:scale-90 transition-transform">
              {isPlaying ? <Pause size={18} fill="currentColor" /> : <Play size={18} fill="currentColor" className="ml-0.5" />}
            </button>
            <button onClick={handleSkip} className="p-2 text-zinc-400 active:text-white transition-colors">
              <SkipForward size={18} />
            </button>
          </div>
        </div>

        <div className="mt-2">
          <input type="range" min={0} max={duration || 1} value={progress} onChange={handleSeek} className="w-full h-1" />
          <div className="flex justify-between text-[10px] text-zinc-600 mt-0.5">
            <span>{fmt(progress)}</span>
            <span>{fmt(duration)}</span>
          </div>
        </div>

        <div className="hidden sm:flex items-center gap-2 mt-1">
          <button onClick={() => setIsMuted(!isMuted)} className="p-1 text-zinc-500">
            {isMuted ? <VolumeX size={14} /> : <Volume2 size={14} />}
          </button>
          <input type="range" min={0} max={1} step={0.05} value={isMuted ? 0 : volume} onChange={e => setVolume(parseFloat(e.target.value))} className="w-20 h-1" />
        </div>
      </div>
    </div>
  );
}
