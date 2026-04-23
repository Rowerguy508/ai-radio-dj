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

function log(...args: any[]) {
  console.log('[DJ]', ...args);
}

export function useCommentary() {
  const isGenerating = useRef(false);
  const trackCountRef = useRef(0);

  const generateDJAudio = useCallback(async (
    type: 'intro' | 'transition',
    currentTrack?: Track | null,
    previousTrack?: Track | null,
    nextTrack?: Track | null,
  ): Promise<string | null> => {
    const store = useRadioStore.getState();
    if (!store.commentaryEnabled || !store.currentStation) {
      log('Skipping:', !store.commentaryEnabled ? 'commentary disabled' : 'no station');
      return null;
    }
    if (isGenerating.current) {
      log('Skipping: already generating');
      return null;
    }

    isGenerating.current = true;
    log('Generating', type, 'commentary...');

    try {
      const context: CommentaryContext = {
        station: store.currentStation,
        currentTrack: currentTrack || undefined,
        previousTrack: previousTrack || undefined,
        nextTrack: nextTrack || undefined,
        timeOfDay: getTimeOfDay(),
        type,
      };

      // Step 1: Generate script
      log('Step 1: Fetching commentary text...');
      const commentaryRes = await fetch('/api/commentary', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ context }),
      });

      if (!commentaryRes.ok) {
        log('Commentary API failed:', commentaryRes.status);
        return null;
      }
      const { ssml, text } = await commentaryRes.json();
      const spokenText = ssml || text;
      if (!spokenText) {
        log('No text returned from commentary API');
        return null;
      }
      log('Got commentary text:', spokenText.slice(0, 80) + '...');

      // Step 2: Generate audio
      log('Step 2: Fetching TTS audio...');
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
        if (audio) {
          log('Got TTS audio, length:', audio.length);
          return audio;
        }
      }
      log('TTS failed (status:', voiceRes.status, '), trying browser speech...');

      // Fallback: browser TTS
      if (typeof window !== 'undefined' && window.speechSynthesis) {
        const plainText = text || spokenText.replace(/<[^>]+>/g, '');
        log('Using browser speechSynthesis, text:', plainText.slice(0, 60));
        const utterance = new SpeechSynthesisUtterance(plainText);
        utterance.rate = 0.95;
        const voices = window.speechSynthesis.getVoices();
        const preferred = voices.find(v => v.lang.startsWith('en')) || voices[0];
        if (preferred) utterance.voice = preferred;
        window.speechSynthesis.speak(utterance);
        return 'browser-tts';
      }

      log('No TTS available');
      return null;
    } catch (e) {
      log('Generation failed:', e);
      return null;
    } finally {
      isGenerating.current = false;
    }
  }, []);

  const generateIntro = useCallback(async (firstTrack: Track | null): Promise<string | null> => {
    return generateDJAudio('intro', null, null, firstTrack);
  }, [generateDJAudio]);

  const generateTransition = useCallback(async (
    currentTrack: Track,
    previousTrack: Track | null,
    nextTrack: Track | null,
  ): Promise<string | null> => {
    const store = useRadioStore.getState();
    if (!store.commentaryEnabled) return null;

    trackCountRef.current++;
    const interval = 2 + Math.floor(Math.random() * 2);
    if (trackCountRef.current % interval !== 0) {
      log('Skipping transition (track', trackCountRef.current, ', interval', interval, ')');
      return null;
    }

    return generateDJAudio('transition', currentTrack, previousTrack, nextTrack);
  }, [generateDJAudio]);

  const resetTrackCount = useCallback(() => {
    trackCountRef.current = 0;
  }, []);

  return { generateIntro, generateTransition, resetTrackCount };
}
