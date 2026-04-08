'use client';

import { useRef, useCallback } from 'react';
import { useRadioStore, Track } from '@/lib/store/radio';
import type { CommentaryContext } from '@/lib/llm/commentary';

interface TrackInfo {
  title: string;
  artist: string;
  album?: string;
}

function trackToInfo(track: Track): TrackInfo {
  return {
    title: track.title,
    artist: track.artistName,
    album: track.albumName,
  };
}

function getTimeOfDay(): string {
  const hour = new Date().getHours();
  if (hour < 6) return 'late night';
  if (hour < 12) return 'morning';
  if (hour < 17) return 'afternoon';
  if (hour < 21) return 'evening';
  return 'night';
}

/**
 * Hook that generates AI DJ commentary and converts it to speech.
 * Uses ElevenLabs if configured, otherwise falls back to browser speech synthesis.
 */
export function useCommentary() {
  const isGenerating = useRef(false);
  const trackCountRef = useRef(0);

  const generateCommentaryAudio = useCallback(async (
    currentTrack: Track,
    previousTrack: Track | null,
    nextTrack: Track | null,
  ): Promise<string | null> => {
    const store = useRadioStore.getState();
    if (!store.commentaryEnabled || !store.currentStation) return null;
    if (isGenerating.current) return null;

    // Commentary on first track and every 3rd track after that
    trackCountRef.current++;
    const isFirst = trackCountRef.current === 1;
    if (!isFirst && trackCountRef.current % 3 !== 0) return null;

    isGenerating.current = true;

    try {
      const context: CommentaryContext = {
        station: {
          name: store.currentStation.name,
          energy: store.currentStation.energyLevel,
          style: store.currentStation.style,
        },
        currentTrack: trackToInfo(currentTrack),
        previousTrack: previousTrack ? trackToInfo(previousTrack) : undefined,
        nextTrack: nextTrack ? trackToInfo(nextTrack) : undefined,
        timeOfDay: getTimeOfDay(),
        isFirstTrack: isFirst,
        isTransition: !!previousTrack,
      };

      // Step 1: Generate commentary text
      const commentaryRes = await fetch('/api/commentary', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ context, style: 'medium' }),
      });

      if (!commentaryRes.ok) return null;
      const { text } = await commentaryRes.json();
      if (!text) return null;

      // Step 2: Try ElevenLabs TTS
      const voiceId = store.currentStation.voiceId || '21m00Tcm4TlvDq8ikWAM';

      const voiceRes = await fetch('/api/voice', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text,
          voiceId,
          energy: store.currentStation.energyLevel,
        }),
      });

      if (voiceRes.ok) {
        const { audio } = await voiceRes.json();
        if (audio) return audio; // data:audio/mp3;base64,...
      }

      // Step 3: Fallback - use browser speech synthesis
      return await speakWithBrowserTTS(text);
    } catch (e) {
      console.error('Commentary generation failed:', e);
      return null;
    } finally {
      isGenerating.current = false;
    }
  }, []);

  const resetTrackCount = useCallback(() => {
    trackCountRef.current = 0;
  }, []);

  return { generateCommentaryAudio, resetTrackCount };
}

/**
 * Use the browser's built-in speech synthesis as a fallback for ElevenLabs.
 * Records the speech to a blob URL so it can be played through the audio element.
 */
function speakWithBrowserTTS(text: string): Promise<string | null> {
  return new Promise((resolve) => {
    if (typeof window === 'undefined' || !window.speechSynthesis) {
      resolve(null);
      return;
    }

    const utterance = new SpeechSynthesisUtterance(text);
    utterance.rate = 0.95;
    utterance.pitch = 1.0;

    // Try to use a natural-sounding voice
    const voices = window.speechSynthesis.getVoices();
    const preferred = voices.find(v =>
      v.name.includes('Samantha') || v.name.includes('Google') ||
      v.name.includes('Daniel') || v.name.includes('Karen')
    ) || voices.find(v => v.lang.startsWith('en')) || voices[0];
    if (preferred) utterance.voice = preferred;

    // We can't record speechSynthesis to a blob easily,
    // so we'll return a special marker that the Player will handle
    utterance.onend = () => resolve(null);
    utterance.onerror = () => resolve(null);

    // Play it directly - the Player will wait for it
    window.speechSynthesis.speak(utterance);
    resolve('browser-tts'); // Special marker
  });
}
