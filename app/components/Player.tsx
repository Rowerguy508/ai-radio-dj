'use client';

import { useState, useEffect, useRef, useCallback } from 'react';
import { Play, Pause, SkipForward, Volume2, VolumeX, Mic } from 'lucide-react';
import { useRadioStore } from '@/lib/store/radio';
import { useAppleMusic } from '@/lib/apple-music/player';
import { useCommentary } from '@/lib/hooks/useCommentary';

const SILENT = 'data:audio/wav;base64,UklGRjIAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQ4AAAB/f39/f39/f39/f39/fw==';

export function Player() {
  const {
    isPlaying, currentTrack, queue, volume, commentaryEnabled, djIntroPlayed, usingMusicKit,
    setIsPlaying, setVolume, nextTrack, setDjIntroPlayed,
  } = useRadioStore();

  const appleMusic = useAppleMusic();
  const { generateIntro, generateTransition, resetTrackCount } = useCommentary();
  const commentaryAudioRef = useRef<HTMLAudioElement | null>(null);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const previousTrackRef = useRef(currentTrack);
  const introPlayedRef = useRef(false);
  const [isMuted, setIsMuted] = useState(false);
  const [audioSrc, setAudioSrc] = useState<string>(SILENT);
  const [djSpeaking, setDjSpeaking] = useState(false);

  const currentStation = useRadioStore((s) => s.currentStation);

  // Progress: use MusicKit progress when active, otherwise HTML audio
  const mkProgress = appleMusic.musicKitProgress;
  const [htmlProgress, setHtmlProgress] = useState(0);
  const [htmlDuration, setHtmlDuration] = useState(0);
  const progress = usingMusicKit ? mkProgress.current : htmlProgress;
  const duration = usingMusicKit ? mkProgress.total : htmlDuration;

  // Sync volume to MusicKit
  useEffect(() => {
    if (usingMusicKit && appleMusic.music) {
      appleMusic.music.volume = isMuted ? 0 : volume;
    }
  }, [volume, isMuted, usingMusicKit, appleMusic.music]);

  // Reset on station change
  useEffect(() => {
    resetTrackCount();
    introPlayedRef.current = false;
  }, [currentStation?.id, resetTrackCount]);

  // Play commentary audio through the dedicated element
  const playCommentaryAudio = useCallback((url: string): Promise<void> => {
    return new Promise((resolve) => {
      const audio = commentaryAudioRef.current;
      if (!audio) { resolve(); return; }

      // Pause MusicKit or HTML audio while DJ speaks
      if (usingMusicKit && appleMusic.music) {
        appleMusic.music.volume = (isMuted ? 0 : volume) * 0.15;
      } else if (audioRef.current) {
        audioRef.current.volume = (isMuted ? 0 : volume) * 0.15;
      }

      audio.src = url;
      audio.volume = isMuted ? 0 : volume;

      const cleanup = () => {
        audio.removeEventListener('ended', onEnd);
        audio.removeEventListener('error', onErr);
        // Restore music volume
        if (usingMusicKit && appleMusic.music) {
          appleMusic.music.volume = isMuted ? 0 : volume;
        } else if (audioRef.current) {
          audioRef.current.volume = isMuted ? 0 : volume;
        }
      };
      const onEnd = () => { cleanup(); resolve(); };
      const onErr = () => { cleanup(); resolve(); };
      audio.addEventListener('ended', onEnd);
      audio.addEventListener('error', onErr);

      audio.play().catch(e => {
        console.warn('[DJ] Commentary play blocked:', e.name);
        cleanup();
        resolve();
      });
    });
  }, [isMuted, volume, usingMusicKit, appleMusic.music]);

  const waitForBrowserTTS = useCallback((): Promise<void> => {
    return new Promise((resolve) => {
      const timeout = setTimeout(resolve, 15000);
      const check = () => {
        if (window.speechSynthesis?.speaking) setTimeout(check, 200);
        else { clearTimeout(timeout); resolve(); }
      };
      setTimeout(check, 500);
    });
  }, []);

  // DJ intro — plays before first track, works with both MusicKit and HTML audio
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
          await playCommentaryAudio(audioUrl);
          if (!cancelled) setDjSpeaking(false);
        } else if (audioUrl === 'browser-tts') {
          setDjSpeaking(true);
          await waitForBrowserTTS();
          if (!cancelled) setDjSpeaking(false);
        }
      } catch (e) {
        console.error('[DJ] Intro failed:', e);
        setDjSpeaking(false);
      }

      if (cancelled) return;
      setDjIntroPlayed(true);
    };

    const timer = setTimeout(() => playIntro(), 300);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [currentTrack?.id, currentStation?.id, djIntroPlayed]);

  // HTML audio: load and play track (only when NOT using MusicKit)
  useEffect(() => {
    if (usingMusicKit) return;
    if (!djIntroPlayed || !currentTrack?.previewUrl) return;
    if (currentTrack.previewUrl === audioSrc && audioSrc !== SILENT) return;

    const url = currentTrack.previewUrl;
    setAudioSrc(url);

    const timer = setTimeout(() => {
      const audio = audioRef.current;
      if (!audio || !isPlaying) return;
      audio.load();
      audio.play().catch(e => {
        console.warn('[Audio] Track play blocked:', e.name);
      });
    }, 150);

    return () => clearTimeout(timer);
  }, [currentTrack?.previewUrl, djIntroPlayed, usingMusicKit]);

  // HTML audio: track end handler
  const handleTrackEnd = useCallback(async () => {
    if (usingMusicKit) return; // MusicKit handles its own queue

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
        await playCommentaryAudio(url);
        setDjSpeaking(false);
      }
    }

    previousTrackRef.current = currentTrack;
    nextTrack();
  }, [usingMusicKit, commentaryEnabled, currentTrack, queue, generateTransition, nextTrack, playCommentaryAudio, waitForBrowserTTS]);

  // HTML audio: element events (only active when not using MusicKit)
  useEffect(() => {
    if (usingMusicKit) return;
    const audio = audioRef.current;
    if (!audio) return;

    const onEnded = () => handleTrackEnd();
    const onCanPlay = () => {
      if (isPlaying && !djSpeaking && djIntroPlayed && audioSrc !== SILENT) {
        audio.play().catch(() => {});
      }
    };
    const onError = () => {
      if (audio.src && !audio.src.startsWith('data:')) {
        console.warn('[Audio] Load error, skipping track');
        previousTrackRef.current = currentTrack;
        nextTrack();
      }
    };

    audio.addEventListener('ended', onEnded);
    audio.addEventListener('canplay', onCanPlay);
    audio.addEventListener('error', onError);
    return () => {
      audio.removeEventListener('ended', onEnded);
      audio.removeEventListener('canplay', onCanPlay);
      audio.removeEventListener('error', onError);
    };
  }, [usingMusicKit, handleTrackEnd, isPlaying, djSpeaking, djIntroPlayed, audioSrc, currentTrack, nextTrack]);

  // HTML audio: volume sync
  useEffect(() => {
    if (usingMusicKit) return;
    const v = isMuted ? 0 : volume;
    if (audioRef.current) audioRef.current.volume = v;
  }, [volume, isMuted, usingMusicKit]);

  // HTML audio: progress tracking
  useEffect(() => {
    if (usingMusicKit) return;
    const audio = audioRef.current;
    if (!audio) return;
    const update = () => {
      if (audio.src && !audio.src.startsWith('data:')) {
        setHtmlProgress(audio.currentTime);
        setHtmlDuration(audio.duration || 0);
      }
    };
    audio.addEventListener('timeupdate', update);
    audio.addEventListener('loadedmetadata', update);
    return () => { audio.removeEventListener('timeupdate', update); audio.removeEventListener('loadedmetadata', update); };
  }, [usingMusicKit]);

  // Commentary audio volume sync
  useEffect(() => {
    if (commentaryAudioRef.current) {
      commentaryAudioRef.current.volume = isMuted ? 0 : volume;
    }
  }, [volume, isMuted]);

  const handlePlayPause = async () => {
    if (usingMusicKit) {
      if (isPlaying) {
        appleMusic.musicKitPause();
      } else {
        await appleMusic.musicKitPlay();
      }
      return;
    }

    // HTML audio path
    const audio = audioRef.current;
    if (!audio) { setIsPlaying(!isPlaying); return; }

    if (isPlaying) {
      audio.pause();
      setIsPlaying(false);
      return;
    }

    if (currentTrack?.previewUrl) {
      if (audioSrc === SILENT || audio.src !== currentTrack.previewUrl) {
        audio.src = currentTrack.previewUrl;
        setAudioSrc(currentTrack.previewUrl);
        audio.load();
      }
      try {
        await audio.play();
        setIsPlaying(true);
      } catch (e) {
        console.error('[Audio] Play failed:', (e as Error).name);
      }
    }
  };

  const handleSeek = (e: React.ChangeEvent<HTMLInputElement>) => {
    const t = parseFloat(e.target.value);
    if (usingMusicKit && appleMusic.music) {
      appleMusic.music.seekToTime(t);
    } else if (audioRef.current) {
      audioRef.current.currentTime = t;
    }
  };

  const handleSkip = async () => {
    if (djSpeaking && commentaryAudioRef.current) {
      commentaryAudioRef.current.pause();
      commentaryAudioRef.current.src = SILENT;
      window.speechSynthesis?.cancel();
      setDjSpeaking(false);
    }

    if (usingMusicKit) {
      await appleMusic.musicKitSkip();
    } else {
      previousTrackRef.current = currentTrack;
      nextTrack();
    }
  };

  const fmt = (s: number) => `${Math.floor(s / 60)}:${Math.floor(s % 60).toString().padStart(2, '0')}`;
  const progressPct = duration > 0 ? (progress / duration) * 100 : 0;
  const track = currentTrack || (queue.length > 0 ? queue[0] : null);

  if (!track) return null;

  return (
    <div className="fixed bottom-0 inset-x-0 z-50 animate-slide-up">
      {/* HTML audio elements — only used for non-MusicKit playback + commentary */}
      <audio ref={audioRef} src={usingMusicKit ? SILENT : audioSrc} preload="auto" playsInline />
      <audio ref={commentaryAudioRef} src={SILENT} preload="auto" playsInline />

      <div className="h-px bg-gradient-to-r from-transparent via-violet-500/30 to-transparent" />

      <div className="bg-zinc-950/90 backdrop-blur-2xl border-t border-white/[0.04] px-4 pt-3 pb-4 sm:px-6">
        {djSpeaking && (
          <div className="flex items-center gap-2 mb-2.5 animate-fade-in">
            <div className="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-violet-500/10 border border-violet-500/20">
              <Mic size={11} className="text-violet-400 animate-pulse" />
              <span className="text-violet-300 text-[11px] font-medium">{currentStation?.djName || 'DJ'} is on the mic</span>
            </div>
          </div>
        )}

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

        <div className="flex items-center gap-3">
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

          <div className="flex-1 min-w-0">
            <p className="text-white text-sm font-medium truncate">{track.title}</p>
            <p className="text-zinc-500 text-xs truncate">{track.artistName}</p>
          </div>

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
