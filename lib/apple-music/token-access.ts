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
//
// Within one instance the limiter is hardened as follows (#78):
//  - Atomic: permitTokenRequest reads, checks and increments in one synchronous
//    call with no await in between. Node runs it to completion, so concurrent
//    requests on an instance can never both take the last slot.
//  - Keyed per client by the platform-verified `x-real-ip` only, validated as an
//    address-shaped string of bounded length. Anything else shares UNKNOWN_CLIENT.
//  - Bounded memory: expired buckets are evicted, and no more than
//    MAX_TRACKED_CLIENTS distinct clients are tracked at once. Past that cap new
//    clients share one OVERFLOW_CLIENT bucket (still rate limited), so a flood of
//    distinct addresses cannot grow the Map or mint unlimited fresh budgets.
//  - Fail closed: the key is only ever an address, never a token or a header
//    value, and nothing here logs. If the limiter itself throws, the route
//    refuses the request (503) and mints nothing; see the route.

export const TOKEN_REQUESTS_PER_WINDOW = 10;
export const TOKEN_WINDOW_MS = 60_000;
export const UNKNOWN_CLIENT = 'unknown';
export const OVERFLOW_CLIENT = 'overflow';
/** Hard cap on live buckets. Ten thousand small entries is well under a megabyte. */
export const MAX_TRACKED_CLIENTS = 10_000;
/** While at the cap, an eviction sweep may run this often instead of once per window. */
export const EVICTION_MIN_GAP_AT_CAPACITY_MS = 1_000;
/** Longest textual IPv6 address, with an IPv4 tail, is 45 characters. */
export const MAX_CLIENT_KEY_LENGTH = 45;
const ADDRESS_SHAPED = /^[0-9a-fA-F:.]+$/;

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
// distinct address until a cold start. Runs on write, at most once per `minGap`
// (a window normally, a second when the Map is full), so the cost stays
// O(live buckets) per sweep.
function evictExpired(now: number, minGap: number = TOKEN_WINDOW_MS): void {
  if (now - lastEviction < minGap) return;
  lastEviction = now;
  buckets.forEach((bucket, address) => {
    if (now - bucket.start >= TOKEN_WINDOW_MS) buckets.delete(address);
  });
}

/**
 * The limiter key. Vercel sets `x-real-ip` to the connecting address and overwrites
 * any value the client sent. `x-forwarded-for` is never read: its first entry is
 * whatever the client put there, so keying on it lets a caller pick a fresh bucket
 * per request. A missing, oversized or non-address value (so never free text, and
 * never a token) falls back to UNKNOWN_CLIENT: every such request shares one bucket.
 */
export function clientAddress(headers: Headers): string {
  const real = headers.get('x-real-ip')?.trim();
  if (!real || real.length > MAX_CLIENT_KEY_LENGTH || !ADDRESS_SHAPED.test(real)) return UNKNOWN_CLIENT;
  return real.toLowerCase();
}

/** Spend one request from the caller's bucket. Call only after the origin check passes. */
export function permitTokenRequest(address: string, now = Date.now()): boolean {
  let key = address.length > MAX_CLIENT_KEY_LENGTH ? UNKNOWN_CLIENT : address;
  let current = buckets.get(key);
  if (!current && buckets.size >= MAX_TRACKED_CLIENTS) {
    evictExpired(now, EVICTION_MIN_GAP_AT_CAPACITY_MS);
    if (buckets.size >= MAX_TRACKED_CLIENTS) key = OVERFLOW_CLIENT;
    current = buckets.get(key);
  }
  if (!current || now - current.start >= TOKEN_WINDOW_MS) {
    evictExpired(now);
    buckets.set(key, { start: now, count: 1 });
    return true;
  }
  if (current.count >= TOKEN_REQUESTS_PER_WINDOW) return false;
  current.count += 1;
  return true;
}
