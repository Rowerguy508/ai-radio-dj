'use client';

import { useEffect } from 'react';

export default function MusicKitInit() {
  useEffect(() => {
    const configure = () => {
      try {
        if ((window as any).MusicKit) {
          (window as any).MusicKit.configure({
            developerToken: process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '',
            app: {
              name: 'RAY.DO',
              build: '1.0.0',
            },
          });
        }
      } catch (e) {
        console.warn('MusicKit configure error:', e);
      }
    };

    // If MusicKit already loaded, configure now
    if ((window as any).MusicKit) {
      configure();
    } else {
      // Otherwise wait for the script from layout.tsx to load
      document.addEventListener('musickitloaded', configure);
      return () => document.removeEventListener('musickitloaded', configure);
    }
  }, []);

  return null;
}
