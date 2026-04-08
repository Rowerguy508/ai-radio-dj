'use client';

import { useEffect } from 'react';

// This component just ensures MusicKit is configured once on app load.
// The AppleMusicProvider will wait for it and get the instance.
export default function MusicKitInit() {
  useEffect(() => {
    const configure = async () => {
      try {
        const MK = (window as any).MusicKit;
        if (!MK) return;

        // MusicKit.configure() returns the instance in v1/v3
        const instance = await MK.configure({
          developerToken: process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '',
          app: {
            name: 'RAY.DO',
            build: '1.0.0',
          },
        });

        // Store on window so provider can access it
        (window as any).__musicKitInstance = instance;
        // Dispatch event so provider knows it's ready
        window.dispatchEvent(new Event('musickitconfigured'));
      } catch (e) {
        console.warn('MusicKit configuration failed:', e);
      }
    };

    if ((window as any).MusicKit) {
      configure();
    } else {
      document.addEventListener('musickitloaded', () => configure());
    }
  }, []);

  return null;
}
