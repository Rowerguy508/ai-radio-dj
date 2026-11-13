import type { IncomingMessage, ServerResponse } from 'node:http';
import { defaultDeps, handleTts } from '../src/handler.js';

/** Vercel Node runtime request: IncomingMessage plus the parsed `body` helper. */
type VercelLikeRequest = IncomingMessage & { body?: unknown };

export default async function handler(req: VercelLikeRequest, res: ServerResponse): Promise<void> {
  const authorization = req.headers.authorization;
  // #378: install token and assertion headers, passed through as-is; handleTts decides
  // (exactly one credential per request, else 400 `mixed_auth`). Never logged.
  const installToken = req.headers['x-onairly-install-token'];
  const assertion = req.headers['x-onairly-assertion'];
  const result = await handleTts(
    {
      method: req.method,
      authorization: typeof authorization === 'string' ? authorization : undefined,
      body: req.body,
      ...(installToken !== undefined ? { installToken: Array.isArray(installToken) ? installToken.join(',') : installToken } : {}),
      ...(assertion !== undefined ? { assertion: Array.isArray(assertion) ? assertion.join(',') : assertion } : {}),
    },
    defaultDeps(),
  );
  res.statusCode = result.status;
  for (const [name, value] of Object.entries(result.headers)) res.setHeader(name, value);
  res.end(result.body);
}
