/**
 * Usage limiter seam.
 *
 * IMPORTANT: the default implementation is in-memory and therefore
 * BEST-EFFORT PER SERVERLESS INSTANCE. Vercel may run several instances and
 * recycles them at any time, which resets the counters. The hard spend
 * backstop is the ElevenLabs plan itself (Free plan: 10k credits, no overage,
 * so $0) plus the restricted key's own credit limit. A shared store such as
 * Upstash Redis / Vercel KV can implement this interface later without
 * changing the handler.
 */
export interface UsageLimiter {
  /** Records one request for `key`; returns false if over the per-minute rate. */
  allowRequest(key: string, now: number): Promise<boolean>;
  /** True if `chars` more characters still fit in today's (UTC) cap for `key`. */
  canSpend(key: string, chars: number, now: number): Promise<boolean>;
  /** Records characters spent after a successful upstream render. */
  recordSpend(key: string, chars: number, now: number): Promise<void>;
}

export interface LimiterOptions {
  dailyCharCap: number;
  requestsPerMinute: number;
}

function utcDay(now: number): string {
  return new Date(now).toISOString().slice(0, 10);
}

export class InMemoryUsageLimiter implements UsageLimiter {
  private readonly windows = new Map<string, number[]>();
  private readonly spend = new Map<string, { day: string; chars: number }>();

  constructor(private readonly options: LimiterOptions) {}

  async allowRequest(key: string, now: number): Promise<boolean> {
    const recent = (this.windows.get(key) ?? []).filter((t) => now - t < 60_000);
    if (recent.length >= this.options.requestsPerMinute) {
      this.windows.set(key, recent);
      return false;
    }
    recent.push(now);
    this.windows.set(key, recent);
    return true;
  }

  async canSpend(key: string, chars: number, now: number): Promise<boolean> {
    const entry = this.spend.get(key);
    const used = entry && entry.day === utcDay(now) ? entry.chars : 0;
    return used + chars <= this.options.dailyCharCap;
  }

  async recordSpend(key: string, chars: number, now: number): Promise<void> {
    const day = utcDay(now);
    const entry = this.spend.get(key);
    const used = entry && entry.day === day ? entry.chars : 0;
    this.spend.set(key, { day, chars: used + chars });
  }
}
