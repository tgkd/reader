#!/usr/bin/env node
/**
 * Does the Cloudflare AI Gateway's `/elevenlabs/v1` passthrough proxy MANAGEMENT
 * endpoints, or only inference?
 *
 * The Worker holds no ElevenLabs key — only AI_GATEWAY_TOKEN, with the provider key
 * stored BYOK at the gateway (aiwork/src/index.ts:54, :331-348). Narration works in
 * production, which proves the inference path. Creating and listing pronunciation
 * dictionaries is a different class of call, and if the gateway does not forward it the
 * Worker cannot own the dictionary lifecycle at all.
 *
 * Read-only: GET /pronunciation-dictionaries only. Creates nothing.
 */
import { readFileSync } from 'node:fs';

const devVars = readFileSync(process.env.AIWORK_DEV_VARS ?? '', 'utf8');
const get = (k) => devVars.match(new RegExp(`^${k}\\s*=\\s*"?([^"\\n]+)"?`, 'm'))?.[1]?.trim();
const TOKEN = get('AI_GATEWAY_TOKEN');
if (!TOKEN) { console.error('no AI_GATEWAY_TOKEN in .dev.vars'); process.exit(1); }

// Same values wrangler.jsonc ships as vars.
const ACCOUNT = '375e4092bc7903fb8ef13e363a41d370';
const GATEWAY = 'default';
const BASE = `https://gateway.ai.cloudflare.com/v1/${ACCOUNT}/${GATEWAY}/elevenlabs/v1`;

async function probe(label, url, headers) {
  try {
    const res = await fetch(url, { headers });
    const body = await res.text();
    console.log(`${label}\n  -> HTTP ${res.status}  ${body.slice(0, 220).replace(/\n/g, ' ')}\n`);
    return res.status;
  } catch (e) {
    console.log(`${label}\n  -> threw ${e.message}\n`);
    return null;
  }
}

console.log('=== through the AI Gateway, gateway credential only (what the Worker has) ===\n');
await probe('GET /pronunciation-dictionaries  (cf-aig-authorization)',
  `${BASE}/pronunciation-dictionaries?page_size=1`,
  { 'cf-aig-authorization': `Bearer ${TOKEN}` });

await probe('GET /models  (inference-adjacent control, same auth)',
  `${BASE}/models`,
  { 'cf-aig-authorization': `Bearer ${TOKEN}` });

console.log('=== direct to ElevenLabs with the real key (control — known to work) ===\n');
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
await probe('GET /pronunciation-dictionaries  (xi-api-key, direct)',
  'https://api.elevenlabs.io/v1/pronunciation-dictionaries?page_size=1',
  { 'xi-api-key': KEY });
