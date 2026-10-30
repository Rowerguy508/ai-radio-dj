import crypto from 'node:crypto';
import { isIP } from 'node:net';

/**
 * Per-device enrollment sub-cap key (owner decision on #256, 2026-10-29: "Keep 20 a
 * day overall and 3 per device for now").
 *
 * What the server can actually observe. Nothing in the register request or the
 * attestation identifies a device across enrollments:
 * - the App Attest keyId is new on every `generateKey()` (every reinstall or
 *   re-enroll), so a keyId cap is no cap at all;
 * - the attestation carries the app's rpIdHash, a constant aaguid, counter 0 and an
 *   Apple receipt with no device identifier (Apple's per-device "risk metric" needs
 *   a server-to-Apple receipt refresh with a .p8, which is out of scope);
 * - the app sends no install or vendor identifier, and adding one would be a client
 *   contract change (an open question for iOS, not made here).
 *
 * So the sub-cap keys on the **client network** as Vercel's edge reports it, read
 * from `x-vercel-forwarded-for` only (Vercel docs, "Request headers": identical to
 * `x-forwarded-for`, which Vercel overwrites to prevent spoofing, and unlike it not
 * rewritten by a proxy in front of Vercel). `x-real-ip` and `x-forwarded-for` are
 * never read (Sentinel's condition on #256: the edge header only). The value is the
 * IPv4 address, or the IPv6 /64 (one device's usual allocation, so rotating privacy
 * addresses inside it does not escape the cap). A missing or unparseable header is
 * `null`, and register refuses it (400 `network`) before the challenge is consumed
 * or any counter is read or written: it fails closed, with no shared bucket.
 *
 * Limits, stated plainly: this is a per-network cap, not a true per-device cap.
 * Devices behind one NAT, CGNAT or office Wi-Fi share 3 a day; one device that
 * changes networks (Wi-Fi to cellular, a VPN) gets 3 more on each.
 *
 * Privacy: the address is never stored, logged or returned. The counter key holds
 * only HMAC-SHA256(K, domain ‖ day ‖ network), K being the server's challenge HMAC
 * key; a keyed hash because the IPv4 space is small enough to brute-force a plain
 * one. The day is inside the MAC, so the same network maps to unrelated keys on
 * different days, and each counter expires with the enroll counter (2 days).
 */

export const DEFAULT_ENROLL_DEVICE_DAILY_CAP = 3;
export const MAX_ENROLL_DEVICE_DAILY_CAP = 1_000;

const DOMAIN = Buffer.from('onairly-enroll-device-v1\0', 'utf8');

function ipv4Octets(ip: string): number[] | null {
  if (isIP(ip) !== 4) return null;
  return ip.split('.').map(Number);
}

/** The eight 16-bit groups of a valid IPv6 address (no zone id), else null. */
function ipv6Groups(ip: string): number[] | null {
  if (isIP(ip) !== 6 || ip.includes('%')) return null;
  let s = ip;
  const last = s.lastIndexOf(':');
  if (s.slice(last + 1).includes('.')) {
    // Embedded IPv4 tail (e.g. ::ffff:192.0.2.1): rewrite it as two hex groups.
    const v4 = ipv4Octets(s.slice(last + 1));
    if (!v4) return null;
    s = `${s.slice(0, last + 1)}${((v4[0] << 8) | v4[1]).toString(16)}:${((v4[2] << 8) | v4[3]).toString(16)}`;
  }
  const parse = (part: string): number[] => (part === '' ? [] : part.split(':').map((g) => parseInt(g, 16)));
  const halves = s.split('::');
  if (halves.length > 2) return null;
  const head = parse(halves[0]);
  const rest = halves.length === 2 ? parse(halves[1]) : [];
  const missing = 8 - head.length - rest.length;
  if (missing < 0 || (halves.length === 1 && missing !== 0)) return null;
  const groups = [...head, ...new Array<number>(missing).fill(0), ...rest];
  return groups.length === 8 && groups.every((g) => Number.isInteger(g) && g >= 0 && g <= 0xffff) ? groups : null;
}

/**
 * Canonical network string for the sub-cap: `v4:a.b.c.d` or `v6:<first 4 groups>`
 * (the /64); `null` when `x-vercel-forwarded-for` is missing or its first entry is
 * not an IP address (the caller fails closed). IPv4-mapped IPv6 (`::ffff:a.b.c.d`)
 * counts as the IPv4. Only the first entry of a comma-separated header is used.
 */
export function clientNetwork(headers: Headers): string | null {
  const raw = headers.get('x-vercel-forwarded-for');
  const first = raw?.split(',')[0]?.trim() ?? '';
  const v4 = ipv4Octets(first);
  if (v4) return `v4:${v4.join('.')}`;
  const g = ipv6Groups(first);
  if (!g) return null;
  if (g.slice(0, 5).every((x) => x === 0) && g[5] === 0xffff) {
    return `v4:${g[6] >> 8}.${g[6] & 0xff}.${g[7] >> 8}.${g[7] & 0xff}`;
  }
  return `v6:${g.slice(0, 4).map((x) => x.toString(16)).join(':')}`;
}

/** Hex HMAC-SHA256(key, DOMAIN ‖ day ‖ 0x00 ‖ network). Never the network itself. */
export function deviceBucket(key: Buffer, day: string, network: string): string {
  return crypto.createHmac('sha256', key).update(DOMAIN).update(day, 'utf8').update('\0').update(network, 'utf8').digest('hex');
}
