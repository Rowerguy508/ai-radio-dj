import type { Metadata } from 'next';
import './globals.css';
import MusicKitInit from './musickit-init';

export const metadata: Metadata = {
  title: 'RAY.DO - AI Radio DJ',
  description: 'Your personal AI-hosted radio station with Apple Music or Spotify integration',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <head>
        {/* Apple MusicKit Script */}
        <script
          src="https://assets.applemusickit.com/apple-musickit.js"
          async
        />
      </head>
      <body className="font-sans">
        <MusicKitInit />
        {children}
      </body>
    </html>
  );
}
