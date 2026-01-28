'use client';

import { useEffect } from 'react';

export default function MusicKitInit() {
  useEffect(() => {
    if ((window as any).MusicKit) {
      (window as any).MusicKit.configure({
        developerToken: process.env.NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN || '',
        app: {
          name: 'RAY.DO',
          build: '1.0.0',
        },
      });
    }
  }, []);

  return null;
}
