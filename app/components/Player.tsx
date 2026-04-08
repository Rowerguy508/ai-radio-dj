'use client';

import { useState, useEffect, useRef, useCallback } from 'react';
import { Play, Pause, SkipForward, Volume2, VolumeX, Mic } from 'lucide-react';
import { useRadioStore } from '@/lib/store/radio';
import { useCommentary } from '@/lib/hooks/useCommentary';

export function Player() {
  const {
    isPlaying, currentTrack, queue, volume, commentaryEnabled,
    setIsPlaying, setVolume, nextTrack,
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

  const currentStation = useRadioStore((s) => s.currentStation);
  useEffect(() => { resetTrackCount(); }, [currentStation?.id, resetTrackCount]);

  // Load new track
  useEffect(() => {
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
  }, [currentTrack]);

  // Commentary between tracks
  const handleTrackEnd = useCallback(async () => {
    const prev = previousTrackRef.current;
    const nextInQueue = queue[0] || null;

    if (commentaryEnabled && currentTrack) {
      const url = await generateCommentaryAudio(currentTrack, prev, nextInQueue);

      if (url === 'browser-tts') {
        setIsPlayingCommentary(true);
        await new Promise<void>(r => {
          const check = () => window.speechSynthesis.speaking ? setTimeout(check, 200) : r();
          setTimeout(check, 500);
        });
        setIsPlayingCommentary(false);
      } else if (url && commentaryAudioRef.current) {
        setIsPlayingCommentary(true);
        commentaryAudioRef.current.src = url;
        commentaryAudioRef.current.volume = isMuted ? 0 : volume;
        try {
          await commentaryAudioRef.current.play();
          await new Promise<void>(r => {
            const onEnd = () => { commentaryAudioRef.current?.removeEventListener('ended', onEnd); r(); };
            commentaryAudioRef.current?.addEventListener('ended', onEnd);
          });
        } catch {}
        setIsPlayingCommentary(false);
      }
    }

    previousTrackRef.current = currentTrack;
    nextTrack();
  }, [commentaryEnabled, currentTrack, queue, generateCommentaryAudio, nextTrack, isMuted, volume]);

  // Audio events
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;
    const onEnded = () => handleTrackEnd();
    const onCanPlay = () => { if (isPlaying && !isPlayingCommentary) audio.play().catch(() => {}); };
    audio.addEventListener('ended', onEnded);
    audio.addEventListener('canplay', onCanPlay);
    return () => { audio.removeEventListener('ended', onEnded); audio.removeEventListener('canplay', onCanPlay); };
  }, [handleTrackEnd, isPlaying, isPlayingCommentary]);

  // Volume
  useEffect(() => {
    const v = isMuted ? 0 : volume;
    if (audioRef.current) audioRef.current.volume = v;
    if (commentaryAudioRef.current) commentaryAudioRef.current.volume = v;
  }, [volume, isMuted]);

  // Progress
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

  const fmt = (s: number) => `${Math.floor(s / 60)}:${Math.floor(s % 60).toString().padStart(2, '0')}`;
  const track = currentTrack || (queue.length > 0 ? queue[0] : null);

  if (!track) return null;

  return (
    <div className="fixed bottom-0 inset-x-0 z-50 safe-bottom">
      <audio ref={audioRef} src={audioSrc} preload="auto" />
      <audio ref={commentaryAudioRef} preload="auto" />

      <div className="bg-zinc-950/95 backdrop-blur-xl border-t border-white/5 px-4 pt-3 pb-4 sm:px-6">
        {/* Commentary indicator */}
        {isPlayingCommentary && (
          <div className="flex items-center gap-1.5 text-violet-400 text-xs mb-2">
            <Mic size={12} className="animate-pulse" />
            <span>DJ is speaking...</span>
          </div>
        )}

        {/* Track + controls row */}
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
            <button onClick={() => { previousTrackRef.current = currentTrack; nextTrack(); }} className="p-2 text-zinc-400 active:text-white transition-colors">
              <SkipForward size={18} />
            </button>
          </div>
        </div>

        {/* Progress */}
        <div className="mt-2">
          <input type="range" min={0} max={duration || 1} value={progress} onChange={handleSeek} className="w-full h-1" />
          <div className="flex justify-between text-[10px] text-zinc-600 mt-0.5">
            <span>{fmt(progress)}</span>
            <span>{fmt(duration)}</span>
          </div>
        </div>

        {/* Volume - desktop only */}
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
