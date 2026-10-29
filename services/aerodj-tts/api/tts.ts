import type { IncomingMessage, ServerResponse } from 'node:http';
import { defaultDeps, handleTts } from '../src/handler.js';

/** Vercel Node runtime request: IncomingMessage plus the parsed `body` helper. */
type VercelLikeRequest = IncomingMessage & { body?: unknown };

export default async function handler(req: VercelLikeRequest, res: ServerResponse): Promise<void> {
  const authorization = req.headers.authorization;
  const result = await handleTts(
    { method: req.method, authorization: typeof authorization === 'string' ? authorization : undefined, body: req.body },
    defaultDeps(),
  );
  res.statusCode = result.status;
  for (const [name, value] of Object.entries(result.headers)) res.setHeader(name, value);
  res.end(result.body);
}
