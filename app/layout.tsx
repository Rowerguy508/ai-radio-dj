import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import './globals.css';

const inter = Inter({ subsets: ['latin'] });

export const metadata: Metadata = {
  title: 'AI Radio DJ',
  description: 'Your personal AI-hosted radio station with customized commentary and music',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <head>
        {/* Apple Music Kit Script */}
        <script
          src="https://js-cdn.music.apple.com/musickit/v3/musickit.js"
          async
        />
      </head>
      <body className={inter.className}>{children}</body>
    </html>
  );
}
