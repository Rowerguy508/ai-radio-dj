import type { NextRequest } from 'next/server';

export const TOKEN_REQUESTS_PER_WINDOW = 10;
const WINDOW_MS = 60_000;

type Bucket = { start: number; count: number };
const buckets = new Map<string, Bucket>();

export function resetTokenRateLimitForTests(): void {
  buckets.clear();
}

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

export function clientAddress(request: NextRequest): string {
  const forwarded = request.headers.get('x-forwarded-for');
  const first = forwarded?.split(',')[0]?.trim();
  if (first) return first;
  const real = request.headers.get('x-real-ip')?.trim();
  return real || 'unknown';
}

/** Best-effort per-address limit. A caller who can choose this address can pick a new bucket. */
export function permitTokenRequest(address: string, now = Date.now()): boolean {
  const current = buckets.get(address);
  if (!current || now - current.start >= WINDOW_MS) {
    buckets.set(address, { start: now, count: 1 });
    return true;
  }
  if (current.count >= TOKEN_REQUESTS_PER_WINDOW) return false;
  current.count += 1;
  return true;
}
