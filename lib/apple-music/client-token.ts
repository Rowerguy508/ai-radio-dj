/** Browser helper. Talks only to our token route and never sees the MusicKit private key. */
export async function fetchDeveloperToken(): Promise<string | null> {
  try {
    // POST so the browser attaches Origin. The page cannot set that header itself.
    const response = await fetch('/api/apple-music/token', { method: 'POST' });
    if (!response.ok) return null;
    const data = await response.json();
    if (!data || typeof data.token !== 'string' || data.token.length === 0) return null;
    return data.token;
  } catch {
    return null;
  }
}
