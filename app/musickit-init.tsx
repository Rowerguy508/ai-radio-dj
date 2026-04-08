'use client';

import { useEffect } from 'react';

export default function MusicKitInit() {
  useEffect(() => {
    const init = () => {
      try {
        const MK = (window as any).MusicKit;
        if (MK && !MK._configured) {
          MK.configure({
            developerToken: process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '',
            app: {
              name: 'RAY.DO',
              build: '1.0.0',
            },
          });
          MK._configured = true;
        }
      } catch (e) {
        console.warn('MusicKit configuration skipped:', e);
      }
    };

    if ((window as any).MusicKit) {
      init();
    } else {
      // MusicKit script loads async - listen for its ready event
      document.addEventListener('musickitloaded', init);
      return () => document.removeEventListener('musickitloaded', init);
    }
  }, []);

  return null;
}
