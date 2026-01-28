import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import './globals.css';

const inter = Inter({ subsets: ['latin'] });

export const metadata: Metadata = {
  title: 'RAY.DO - AI Radio DJ',
  description: 'Your personal AI-hosted radio station with Apple Music integration',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <head>
        {/* Apple MusicKit Script - loaded by player.tsx */}
      </head>
      <body className={inter.className}>
        {children}
      </body>
    </html>
  );
}
