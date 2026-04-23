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
    if (!currentTrack || !currentStation) return;
    if (djIntroPlayed || introPlayedRef.current) return;

    introPlayedRef.current = true;

    if (!commentaryEnabled) {
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

      setDjIntroPlayed(true);
      if (audioRef.current && currentTrack?.previewUrl) {
        setAudioSrc(currentTrack.previewUrl);
        setTimeout(() => {
          if (!audioRef.current) return;
          audioRef.current.load();
          audioRef.current.play().catch(e => {
            console.warn('Auto-play blocked after intro, waiting for user click:', e.name);
          });
        }, 200);
      }
    };

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
          audioRef.current.play().catch(e => {
            console.warn('Track auto-play blocked:', e.name);
          });
        }
      }, 100);
    } else if (!currentTrack) {
      setAudioSrc(undefined);
    }
  }, [currentTrack, djIntroPlayed]);

  const playAudioUrl = useCallback((url: string): Promise<void> => {
    return new Promise((resolve) => {
      const audio = commentaryAudioRef.current;
      if (!audio) { resolve(); return; }
      audio.src = url;
      audio.volume = isMuted ? 0 : volume;
      const onEnd = () => { audio.removeEventListener('ended', onEnd); resolve(); };
      audio.addEventListener('ended', onEnd);
      audio.play().catch(e => { console.warn('Commentary play blocked:', e.name); resolve(); });
    });
  }, [isMuted, volume]);

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
    const onCanPlay = () => {
      if (isPlaying && !djSpeaking && djIntroPlayed) {
        audio.play().catch(e => console.warn('canplay auto-play blocked:', e.name));
      }
    };
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
    const audio = audioRef.current;
    if (!audio) { setIsPlaying(!isPlaying); return; }

    if (isPlaying) {
      audio.pause();
      setIsPlaying(false);
      return;
    }

    // Ensure src is loaded
    if (currentTrack?.previewUrl && audio.src !== currentTrack.previewUrl) {
      audio.src = currentTrack.previewUrl;
      setAudioSrc(currentTrack.previewUrl);
      audio.load();
    }

    try {
      await audio.play();
      setIsPlaying(true);
    } catch (e) {
      console.warn('Play failed, retrying:', (e as Error).name);
      audio.load();
      try {
        await new Promise(r => setTimeout(r, 150));
        await audio.play();
        setIsPlaying(true);
      } catch {
        console.error('Play failed after retry');
      }
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
  const progressPct = duration > 0 ? (progress / duration) * 100 : 0;
  const track = currentTrack || (queue.length > 0 ? queue[0] : null);

  if (!track) return null;

  return (
    <div className="fixed bottom-0 inset-x-0 z-50 animate-slide-up">
      <audio ref={audioRef} src={audioSrc} preload="auto" />
      <audio ref={commentaryAudioRef} preload="auto" />

      {/* Gradient edge */}
      <div className="h-px bg-gradient-to-r from-transparent via-violet-500/30 to-transparent" />

      <div className="bg-zinc-950/90 backdrop-blur-2xl border-t border-white/[0.04] px-4 pt-3 pb-4 sm:px-6">
        {/* DJ speaking indicator */}
        {djSpeaking && (
          <div className="flex items-center gap-2 mb-2.5 animate-fade-in">
            <div className="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-violet-500/10 border border-violet-500/20">
              <Mic size={11} className="text-violet-400 animate-pulse" />
              <span className="text-violet-300 text-[11px] font-medium">{currentStation?.djName || 'DJ'} is on the mic</span>
            </div>
          </div>
        )}

        {/* Progress bar - full width, above controls */}
        <div className="mb-3">
          <div className="relative w-full h-1 bg-zinc-800/60 rounded-full overflow-hidden group cursor-pointer">
            <div
              className="absolute inset-y-0 left-0 bg-gradient-to-r from-violet-500 to-fuchsia-500 rounded-full transition-all duration-150"
              style={{ width: `${progressPct}%` }}
            />
            <input
              type="range"
              min={0}
              max={duration || 1}
              value={progress}
              onChange={handleSeek}
              className="absolute inset-0 w-full opacity-0 cursor-pointer"
            />
          </div>
          <div className="flex justify-between text-[10px] text-zinc-600 mt-1 px-0.5">
            <span>{fmt(progress)}</span>
            <span>{fmt(duration)}</span>
          </div>
        </div>

        {/* Main controls */}
        <div className="flex items-center gap-3">
          {/* Track artwork */}
          {track.artworkUrl ? (
            <img
              src={track.artworkUrl}
              alt=""
              className={`w-11 h-11 rounded-lg object-cover flex-shrink-0 shadow-lg transition-all duration-300 ${isPlaying ? 'shadow-violet-500/10' : 'opacity-70'}`}
              onError={e => { (e.target as HTMLImageElement).style.display = 'none'; }}
            />
          ) : (
            <div className="w-11 h-11 rounded-lg bg-zinc-800 flex items-center justify-center flex-shrink-0">
              <span className="text-zinc-600 text-lg">{'\u{266B}'}</span>
            </div>
          )}

          {/* Track info */}
          <div className="flex-1 min-w-0">
            <p className="text-white text-sm font-medium truncate">{track.title}</p>
            <p className="text-zinc-500 text-xs truncate">{track.artistName}</p>
          </div>

          {/* Playback buttons */}
          <div className="flex items-center gap-1.5 flex-shrink-0">
            <button
              onClick={handlePlayPause}
              className="w-10 h-10 flex items-center justify-center rounded-full bg-white text-black active:scale-90 transition-all duration-150 hover:shadow-lg hover:shadow-white/10"
            >
              {isPlaying ? <Pause size={17} fill="currentColor" /> : <Play size={17} fill="currentColor" className="ml-0.5" />}
            </button>
            <button onClick={handleSkip} className="p-2.5 text-zinc-500 hover:text-white active:scale-90 transition-all">
              <SkipForward size={18} />
            </button>
          </div>

          {/* Volume control - desktop only */}
          <div className="hidden sm:flex items-center gap-2 pl-2 border-l border-white/5">
            <button onClick={() => setIsMuted(!isMuted)} className="p-1 text-zinc-500 hover:text-zinc-300 transition-colors">
              {isMuted ? <VolumeX size={15} /> : <Volume2 size={15} />}
            </button>
            <input
              type="range"
              min={0}
              max={1}
              step={0.05}
              value={isMuted ? 0 : volume}
              onChange={e => setVolume(parseFloat(e.target.value))}
              className="w-20 h-1"
            />
          </div>
        </div>
      </div>
    </div>
  );
}
