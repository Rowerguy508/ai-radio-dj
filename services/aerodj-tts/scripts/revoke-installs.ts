/**
 * Owner tooling (#378): put App Attest keys on the revocation list. Never run by CI or by
 * any request path. A revoked key can't mint a token (401 `reattest`) and its live token
 * stops working on its next /api/tts request (the reserve script checks the list).
 *
 *   KV_REST_API_URL=… KV_REST_API_TOKEN=… npx tsx scripts/revoke-installs.ts production < keyids.txt
 *
 * stdin: one keyId per line, standard base64 (as the app sends in X-OnAirly-Key). The store
 * credentials come from the owner's own shell environment. Prints counts only, never a keyId.
 */
import { RedisAttestStore, type Keyspace } from '../src/attest-store.js';
import { parseKeyId } from '../src/challenge.js';
import { redisRestConfig } from '../src/limiter.js';

async function main(): Promise<void> {
  const keyspace = process.argv[2];
  if (keyspace !== 'production' && keyspace !== 'nonprod') throw new Error('usage: revoke-installs.ts production|nonprod < keyids.txt');
  const config = redisRestConfig(process.env);
  if (!config) throw new Error('KV_REST_API_URL / KV_REST_API_TOKEN not set');
  const store = new RedisAttestStore(config);
  let input = '';
  for await (const chunk of process.stdin) input += chunk;
  let revoked = 0;
  let skipped = 0;
  for (const line of input.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)) {
    const keyId = parseKeyId(line);
    if (!keyId) {
      skipped++;
      continue;
    }
    await store.revokeKey(keyspace as Keyspace, keyId);
    revoked++;
  }
  console.log(JSON.stringify({ revoked, skipped }));
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : 'failed');
  process.exitCode = 1;
});
