/**
 * Bounds on one Upstash REST call (Sentinel's N2 on #256). A stalled fetch or a
 * response body that never finishes must end as a store error (503 `store`),
 * never hold the function open until the platform kills it.
 */

/** Upper bound (ms) on one Upstash REST call, from request to parsed body. */
export const UPSTASH_FETCH_TIMEOUT_MS = 2_000;

/**
 * Settles with `work`, or rejects with the signal's reason as soon as `signal`
 * aborts. The signal is also passed to `fetch`, which aborts the request; this
 * race additionally bounds a fetch implementation (or body read) that ignores it.
 */
export function untilAborted<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) {
    work.catch(() => {});
    return Promise.reject(signal.reason);
  }
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(signal.reason);
    signal.addEventListener('abort', onAbort, { once: true });
    work.then(
      (value) => {
        signal.removeEventListener('abort', onAbort);
        resolve(value);
      },
      (error: unknown) => {
        signal.removeEventListener('abort', onAbort);
        reject(error);
      },
    );
  });
}
