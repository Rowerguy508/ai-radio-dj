/** Server allowlist for the MusicKit developer token route. */
export function parseOriginAllowlist(raw: string | undefined): string[] {
  if (!raw) return [];
  return raw.split(',').map((entry) => entry.trim()).filter(Boolean);
}

/** Exact match against the server allowlist. The string "null" is never allowed. */
export function originAllowed(origin: string | null, allowlist: readonly string[]): boolean {
  if (!origin) return false;
  const value = origin.trim();
  if (!value || value.toLowerCase() === 'null') return false;
  return allowlist.includes(value);
}
