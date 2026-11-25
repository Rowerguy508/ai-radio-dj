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

// ── Token request limiter (#78) ──
//
// BEST-EFFORT ONLY. The buckets live in this module's memory, so each serverless
// instance keeps its own count, a cold start resets it, and parallel instances do
// not share it. A determined caller can exceed the nominal limit. That is accepted
// on purpose: there is no shared store (no KV, Redis or database) and no added
// hosting cost. The real limits on a leaked token are its `origin` claim and its
// one-hour lifetime, plus the admin gate in front of /api.

export const TOKEN_REQUESTS_PER_WINDOW = 10;
export const TOKEN_WINDOW_MS = 60_000;
export const UNKNOWN_CLIENT = 'unknown';

type Bucket = { start: number; count: number };
const buckets = new Map<string, Bucket>();
let lastEviction = 0;

export function resetTokenRateLimitForTests(): void {
  buckets.clear();
  lastEviction = 0;
}

export function tokenBucketCountForTests(): number {
  return buckets.size;
}

// Drops buckets whose window has ended, so the Map does not grow by one entry per
// distinct address until a cold start. Runs on write, at most once per window, so
// the cost stays O(live buckets) per minute.
function evictExpired(now: number): void {
  if (now - lastEviction < TOKEN_WINDOW_MS) return;
  lastEviction = now;
  buckets.forEach((bucket, address) => {
    if (now - bucket.start >= TOKEN_WINDOW_MS) buckets.delete(address);
  });
}

/**
 * The limiter key. Vercel sets `x-real-ip` to the connecting address and overwrites
 * any value the client sent. `x-forwarded-for` is never read: its first entry is
 * whatever the client put there, so keying on it lets a caller pick a fresh bucket
 * per request. With no `x-real-ip`, every request shares one 'unknown' bucket.
 */
export function clientAddress(headers: Headers): string {
  const real = headers.get('x-real-ip')?.trim();
  return real || UNKNOWN_CLIENT;
}

/** Spend one request from the caller's bucket. Call only after the origin check passes. */
export function permitTokenRequest(address: string, now = Date.now()): boolean {
  const current = buckets.get(address);
  if (!current || now - current.start >= TOKEN_WINDOW_MS) {
    evictExpired(now);
    buckets.set(address, { start: now, count: 1 });
    return true;
  }
  if (current.count >= TOKEN_REQUESTS_PER_WINDOW) return false;
  current.count += 1;
  return true;
}
