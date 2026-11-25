export const PAID_TEXT_MAX_CHARS = 600;
export const COMMENTARY_FIELD_MAX_CHARS = 600;
export const COMMENTARY_PROMPT_MAX_CHARS = 4000;
export const SPEED_MIN = 0.5;
export const SPEED_MAX = 2;
const DEFAULT_DAILY_CHAR_BUDGET = 6000;

export class PaidInferenceRefusal extends Error {
  readonly status: number;
  readonly code: 'invalid_input' | 'budget_exceeded';

  constructor(status: number, code: 'invalid_input' | 'budget_exceeded') {
    super(code);
    this.name = 'PaidInferenceRefusal';
    this.status = status;
    this.code = code;
  }
}

/** Production stays off unless ENABLE_PAID_INFERENCE is exactly "true". */
export function paidRoutesEnabled(): boolean {
  if (process.env.NODE_ENV === 'production') {
    return process.env.ENABLE_PAID_INFERENCE === 'true';
  }
  return true;
}

let usedDay = '';
let usedChars = 0;

export function resetPaidInferenceBudgetForTests(): void {
  usedDay = '';
  usedChars = 0;
}

function dailyCap(): number {
  const raw = process.env.PAID_INFERENCE_DAILY_CHAR_BUDGET;
  if (raw === undefined || raw === '') return DEFAULT_DAILY_CHAR_BUDGET;
  const cap = Number(raw);
  if (!Number.isFinite(cap) || cap < 0) return 0;
  return cap;
}

/** Returns false when this request would exceed the daily character budget. */
export function reservePaidCharacters(chars: number): boolean {
  if (!Number.isFinite(chars) || chars < 0) return false;
  const day = new Date().toISOString().slice(0, 10);
  if (usedDay !== day) {
    usedDay = day;
    usedChars = 0;
  }
  if (usedChars + chars > dailyCap()) return false;
  usedChars += chars;
  return true;
}

/** Missing speed defaults to 1. Out-of-range or non-finite values are rejected. */
export function resolveSpeed(speed: unknown): number | null {
  if (speed === undefined || speed === null) return 1;
  if (typeof speed !== 'number' || !Number.isFinite(speed)) return null;
  if (speed < SPEED_MIN || speed > SPEED_MAX) return null;
  return speed;
}

type TrackLike = { title?: unknown; artistName?: unknown } | null | undefined;

/** Sums caller-supplied commentary strings and rejects oversized input. */
export function measureCommentaryInput(context: {
  station?: {
    name?: unknown;
    description?: unknown;
    searchQuery?: unknown;
    djName?: unknown;
    djPersonality?: unknown;
    style?: unknown;
  } | null;
  previousTrack?: TrackLike;
  currentTrack?: TrackLike;
  nextTrack?: TrackLike;
  timeOfDay?: unknown;
  type?: unknown;
}): number {
  const station = context?.station;
  if (!station || typeof station !== 'object') {
    throw new PaidInferenceRefusal(400, 'invalid_input');
  }
  const values: unknown[] = [
    station.name,
    station.description,
    station.searchQuery,
    station.djName,
    station.djPersonality,
    station.style,
    context.previousTrack?.title,
    context.previousTrack?.artistName,
    context.currentTrack?.title,
    context.currentTrack?.artistName,
    context.nextTrack?.title,
    context.nextTrack?.artistName,
    context.timeOfDay,
    context.type,
  ];
  let total = 0;
  for (const value of values) {
    if (typeof value !== 'string') continue;
    if (value.length > COMMENTARY_FIELD_MAX_CHARS) {
      throw new PaidInferenceRefusal(400, 'invalid_input');
    }
    total += value.length;
  }
  if (total > COMMENTARY_PROMPT_MAX_CHARS) {
    throw new PaidInferenceRefusal(400, 'invalid_input');
  }
  return total;
}
