'use client';

import { useEffect, useRef } from 'react';

export function Visualizer({ isPlaying }: { isPlaying: boolean }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const animationRef = useRef<number>();

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const bars = 64;
    const barWidth = canvas.width / bars - 2;

    const animate = () => {
      if (!isPlaying) {
        ctx.fillStyle = '#18181b';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        animationRef.current = requestAnimationFrame(animate);
        return;
      }

      // Clear with fade effect
      ctx.fillStyle = 'rgba(24, 24, 27, 0.2)';
      ctx.fillRect(0, 0, canvas.width, canvas.height);

      for (let i = 0; i < bars; i++) {
        // Simulated frequency data based on time
        const time = Date.now() / 1000;
        const height = Math.sin(time * 2 + i * 0.3) * 30 + 
                      Math.sin(time * 3 + i * 0.5) * 20 +
                      Math.random() * 30 + 20;

        const hue = (i * 5 + time * 20) % 360;
        const x = i * (barWidth + 2);
        const y = canvas.height - height;

        ctx.fillStyle = `hsla(${hue}, 70%, 60%, 0.8)`;
        ctx.fillRect(x, y, barWidth, height);

        // Glow effect
        ctx.shadowBlur = 10;
        ctx.shadowColor = `hsla(${hue}, 70%, 60%, 0.5)`;
      }

      animationRef.current = requestAnimationFrame(animate);
    };

    animate();

    return () => {
      if (animationRef.current) {
        cancelAnimationFrame(animationRef.current);
      }
    };
  }, [isPlaying]);

  return (
    <canvas
      ref={canvasRef}
      width={800}
      height={200}
      className="w-full h-48 rounded-xl"
      style={{ background: '#18181b' }}
    />
  );
}
