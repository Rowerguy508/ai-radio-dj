'use client';

import { useRef, useCallback } from 'react';
import { useRadioStore, Track } from '@/lib/store/radio';
import type { CommentaryContext } from '@/lib/llm/commentary';

function getTimeOfDay(): string {
  const h = new Date().getHours();
  if (h < 6) return 'late night';
  if (h < 12) return 'morning';
  if (h < 17) return 'afternoon';
  if (h < 21) return 'evening';
  return 'night';
}

/**
 * Generates AI DJ audio. Supports:
 * - DJ intro (before any music plays)
 * - Track transitions (between songs, every 2-3 tracks)
 */
export function useCommentary() {
  const isGenerating = useRef(false);
  const trackCountRef = useRef(0);

  // Generate and return audio URL for the DJ to speak
  const generateDJAudio = useCallback(async (
    type: 'intro' | 'transition',
    currentTrack?: Track | null,
    previousTrack?: Track | null,
    nextTrack?: Track | null,
  ): Promise<string | null> => {
    const store = useRadioStore.getState();
    if (!store.commentaryEnabled || !store.currentStation) return null;
    if (isGenerating.current) return null;

    isGenerating.current = true;

    try {
      const context: CommentaryContext = {
        station: store.currentStation,
        currentTrack: currentTrack || undefined,
        previousTrack: previousTrack || undefined,
        nextTrack: nextTrack || undefined,
        timeOfDay: getTimeOfDay(),
        type,
      };

      // Step 1: Generate script via MiniMax text
      const commentaryRes = await fetch('/api/commentary', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ context }),
      });

      if (!commentaryRes.ok) return null;
      const { ssml, text } = await commentaryRes.json();
      const spokenText = ssml || text;
      if (!spokenText) return null;

      // Step 2: Generate audio via MiniMax TTS
      const voiceRes = await fetch('/api/voice', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text: spokenText,
          speed: store.currentStation.energyLevel < 0.3 ? 0.9 : store.currentStation.energyLevel > 0.7 ? 1.1 : 1.0,
          style: store.currentStation.style,
        }),
      });

      if (voiceRes.ok) {
        const { audio } = await voiceRes.json();
        if (audio) return audio;
      }

      // Fallback: browser TTS
      if (typeof window !== 'undefined' && window.speechSynthesis) {
        const utterance = new SpeechSynthesisUtterance(text || spokenText);
        utterance.rate = 0.95;
        const voices = window.speechSynthesis.getVoices();
        const preferred = voices.find(v => v.lang.startsWith('en')) || voices[0];
        if (preferred) utterance.voice = preferred;
        window.speechSynthesis.speak(utterance);
        return 'browser-tts';
      }

      return null;
    } catch (e) {
      console.error('DJ audio generation failed:', e);
      return null;
    } finally {
      isGenerating.current = false;
    }
  }, []);

  // Generate DJ intro (plays before first track)
  const generateIntro = useCallback(async (firstTrack: Track | null): Promise<string | null> => {
    return generateDJAudio('intro', null, null, firstTrack);
  }, [generateDJAudio]);

  // Generate transition (plays between tracks, every ~3 tracks)
  const generateTransition = useCallback(async (
    currentTrack: Track,
    previousTrack: Track | null,
    nextTrack: Track | null,
  ): Promise<string | null> => {
    const store = useRadioStore.getState();
    if (!store.commentaryEnabled) return null;

    trackCountRef.current++;
    // Play transition every 2-3 tracks (randomized for natural feel)
    const interval = 2 + Math.floor(Math.random() * 2); // 2 or 3
    if (trackCountRef.current % interval !== 0) return null;

    return generateDJAudio('transition', currentTrack, previousTrack, nextTrack);
  }, [generateDJAudio]);

  const resetTrackCount = useCallback(() => {
    trackCountRef.current = 0;
  }, []);

  return { generateIntro, generateTransition, resetTrackCount };
}
