/** Browser helper. Talks only to our token route and never sees the MusicKit private key. */
export async function fetchDeveloperToken(): Promise<string | null> {
  try {
    const response = await fetch('/api/apple-music/token');
    if (!response.ok) return null;
    const data = await response.json();
    if (!data || typeof data.token !== 'string' || data.token.length === 0) return null;
    return data.token;
  } catch {
    return null;
  }
}
