'use client';

import { useRef, useCallback } from 'react';
import { useRadioStore, Track } from '@/lib/store/radio';
import type { CommentaryContext, TrackInfo } from '@/lib/llm/commentary';

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
 * Hook that generates AI DJ commentary and converts it to speech via ElevenLabs.
 * Returns a function that produces an audio URL to play between tracks.
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

    // Don't generate commentary for every single track - do it every 2-3 tracks
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

      // Step 1: Generate commentary text via our API
      const commentaryRes = await fetch('/api/commentary', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ context, style: 'medium' }),
      });

      if (!commentaryRes.ok) return null;
      const { text } = await commentaryRes.json();
      if (!text) return null;

      // Step 2: Convert to speech via ElevenLabs
      const voiceId = store.currentStation.voiceId
        || process.env.NEXT_PUBLIC_ELEVENLABS_DEFAULT_VOICE_ID
        || '21m00Tcm4TlvDq8ikWAM'; // Rachel default

      const voiceRes = await fetch('/api/voice', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text,
          voiceId,
          energy: store.currentStation.energyLevel,
        }),
      });

      if (!voiceRes.ok) return null;
      const { audio } = await voiceRes.json();
      return audio || null; // data:audio/mp3;base64,...
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
