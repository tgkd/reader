#!/usr/bin/env node
/**
 * Probe 5 — the go/no-go for the "one dictionary object, many pinned versions" lifecycle.
 *
 * Probe 4 proved dictionary objects cannot be DELETED. It did not prove that an OLD
 * version stays callable once the dictionary has been updated. The whole per-book design
 * rests on that: each book pins its own {dictionary_id, version_id}, and books imported
 * later must not change how a book imported earlier is narrated.
 *
 * Test: build version A with a long absurd alias (audible as a big duration jump), then
 * mutate the dictionary to version B, then synthesize AGAIN pinned to A.
 *
 *   A still long  -> versions are immutable and callable; the lifecycle works.
 *   A now short   -> pinning is cosmetic and the design collapses.
 */
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY'); process.exit(1); }

const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const MODEL = 'eleven_flash_v2_5';
const TEXT = '黄前久美子です。';
const MP3_BYTES_PER_SECOND = 16000;
const ALIAS_A = 'ぬるぽぬるぽぬるぽぬるぽぬるぽぬるぽ';     // long -> big jump
const ALIAS_B = 'おうまえ';                                  // short -> near baseline

const api = (path, init) => fetch(`https://api.elevenlabs.io/v1${path}`, {
  ...init,
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
});

const rule = (alias) => ({
  string_to_replace: '黄前', type: 'alias', alias,
  case_sensitive: true, word_boundaries: false,
});

async function post(path, body, label) {
  const res = await api(path, { method: 'POST', body: JSON.stringify(body) });
  const text = await res.text();
  if (!res.ok) throw new Error(`${label} HTTP ${res.status}: ${text.slice(0, 300)}`);
  return JSON.parse(text);
}

async function synth(label, locators) {
  const res = await api(
    `/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`, {
      method: 'POST',
      body: JSON.stringify({
        text: TEXT, model_id: MODEL, language_code: 'ja',
        voice_settings: {
          stability: 0.65, similarity_boost: 0.75, style: 0.0,
          use_speaker_boost: true, speed: 1.0,
        },
        ...(locators ? { pronunciation_dictionary_locators: locators } : {}),
      }),
    });
  if (!res.ok) { console.log(`  ${label.padEnd(38)} HTTP ${res.status} ${(await res.text()).slice(0, 200)}`); return null; }
  const chunks = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const bytes = chunks.reduce((n, c) => n + Buffer.from(c.audio_base64 ?? '', 'base64').length, 0);
  const chars = chunks.flatMap((c) => c.alignment?.characters ?? []);
  const sec = bytes / MP3_BYTES_PER_SECOND;
  console.log(`  ${label.padEnd(38)} audio ${sec.toFixed(2)}s  joinOK ${chars.join('') === TEXT}`);
  return sec;
}

const dict = await post('/pronunciation-dictionaries/add-from-rules',
  { name: 'yomi-probe5-versioning', description: 'version immutability probe', rules: [rule(ALIAS_A)] },
  'create');
const vA = dict.version_id;
console.log(`dictionary ${dict.id}\n  version A = ${vA} (alias -> long)`);

const loc = (v) => [{ pronunciation_dictionary_id: dict.id, version_id: v }];

const baseline = await synth('no dictionary (baseline)', null);
const aBefore = await synth('pinned A, before any update', loc(vA));

// Mutate: drop the long rule, add the short one. Each call returns a new version.
const removed = await post(`/pronunciation-dictionaries/${dict.id}/remove-rules`,
  { rule_strings: ['黄前'] }, 'remove-rules');
console.log(`  after remove -> version ${removed.version_id}`);
const added = await post(`/pronunciation-dictionaries/${dict.id}/add-rules`,
  { rules: [rule(ALIAS_B)] }, 'add-rules');
const vB = added.version_id;
console.log(`  version B = ${vB} (alias -> おうまえ)`);

const aAfter = await synth('pinned A, AFTER update to B', loc(vA));
const bAfter = await synth('pinned B', loc(vB));

console.log('\n================ VERDICT ================');
console.log(`baseline (no dict)            ${baseline?.toFixed(2)}s`);
console.log(`pinned A before update        ${aBefore?.toFixed(2)}s`);
console.log(`pinned A after update to B    ${aAfter?.toFixed(2)}s`);
console.log(`pinned B                      ${bAfter?.toFixed(2)}s`);
const immutable = aAfter != null && aBefore != null && Math.abs(aAfter - aBefore) < 1.0;
console.log(`\nOld pinned version still callable and unchanged? ${immutable ? 'YES — lifecycle is safe' : 'NO — pinning does not preserve behaviour'}`);
console.log(`dictionary created: ${dict.id}`);
