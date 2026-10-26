import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const sql = readFileSync(new URL('../supabase-migration.sql', import.meta.url), 'utf8');

function stationsTable(): string {
  const match = sql.match(/CREATE TABLE IF NOT EXISTS public\.stations \([\s\S]*?\);/);
  if (!match) throw new Error('stations table missing');
  return match[0];
}

describe('supabase migration', () => {
  it('declares stations.voice_id once and stores the ElevenLabs id separately', () => {
    const table = stationsTable();
    expect(table.match(/\bvoice_id\b/g)).toHaveLength(1);
    expect(table).toMatch(/voice_id UUID REFERENCES public\.voices\(id\) ON DELETE SET NULL/);
    expect(table).toContain('elevenlabs_voice_id TEXT');
  });

  it('sets a fixed search_path on handle_new_user', () => {
    expect(sql).toMatch(
      /FUNCTION public\.handle_new_user\(\)[\s\S]*?LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;/,
    );
  });
});
