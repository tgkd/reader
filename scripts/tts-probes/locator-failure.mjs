#!/usr/bin/env node
/**
 * §9 blocking question #1: what happens when the pinned locator is bad?
 *
 * Phase 1 would attach the locator to EVERY reader request, so the answer decides whether a
 * stale env var is a silent degradation or a total narration outage. Four ways it can be
 * bad, each tested against the production request shape:
 *
 *   archived   — the dictionary still exists but was archived (the realistic case: cleanup
 *                ran, or someone archived it in the dashboard)
 *   unknown id — a typo in the env var
 *   bad version— right dictionary, stale/mistyped version_id
 *   no version — locator without version_id at all (is it even accepted?)
 *
 * A 2xx with the rule silently not applied is survivable. A 4xx is an outage for every
 * chapter, surfaced to the user as "TTS failed (N)" via WorkerTTSService.swift:67-70.
 */
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY'); process.exit(1); }

const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const TEXT = '黄前久美子です。';
const MP3_BYTES_PER_SECOND = 16000;

// The demo lexicon, created then archived earlier today. Rule: 黄前 -> おうまえ.
const ARCHIVED_ID = 'VRoP5nZal9EX0Th4Tpdm';
const ARCHIVED_VERSION = 'vUyFHFJDK1k4tE2hlWmpE';

async function synth(label, locators) {
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/stream/with-timestamps`
    + `?output_format=mp3_44100_128`, {
      method: 'POST',
      headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text: TEXT,
        model_id: 'eleven_flash_v2_5',
        language_code: 'ja',
        voice_settings: {
          stability: 0.65, similarity_boost: 0.75, style: 0.0,
          use_speaker_boost: true, speed: 1.0,
        },
        ...(locators ? { pronunciation_dictionary_locators: locators } : {}),
      }),
    });

  if (!res.ok) {
    console.log(`  ${label.padEnd(30)} HTTP ${res.status}  <-- OUTAGE`);
    console.log(`      ${(await res.text()).slice(0, 200).replace(/\n/g, ' ')}`);
    return null;
  }
  const chunks = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const bytes = chunks.reduce((n, c) => n + Buffer.from(c.audio_base64 ?? '', 'base64').length, 0);
  const sec = bytes / MP3_BYTES_PER_SECOND;
  console.log(`  ${label.padEnd(30)} HTTP 200  audio ${sec.toFixed(2)}s`);
  return sec;
}

console.log('baseline (no locator at all):');
const base = await synth('no dictionary', null);

console.log('\nbad locators:');
const archived = await synth('archived dictionary',
  [{ pronunciation_dictionary_id: ARCHIVED_ID, version_id: ARCHIVED_VERSION }]);
const unknown = await synth('unknown dictionary id',
  [{ pronunciation_dictionary_id: 'zzzzzzzzzzzzzzzzzzzz', version_id: ARCHIVED_VERSION }]);
const badVersion = await synth('valid id, bad version',
  [{ pronunciation_dictionary_id: ARCHIVED_ID, version_id: 'zzzzzzzzzzzzzzzzzzzz' }]);
const noVersion = await synth('id with no version_id',
  [{ pronunciation_dictionary_id: ARCHIVED_ID }]);

console.log('\n================ VERDICT ================');
const outage = [archived, unknown, badVersion, noVersion].some((v) => v === null);
console.log(outage
  ? 'At least one bad-locator case FAILS the request -> a stale env var is a NARRATION OUTAGE.\n'
    + 'Phase 1 needs a validated/blankable env var and a startup check.'
  : 'Every bad-locator case returned 200 -> failures are silent (rule just does not apply).\n'
    + 'A stale env var degrades pronunciation but never blocks narration.');
if (archived !== null && base !== null) {
  console.log(`\nDid the ARCHIVED dictionary still apply its rule? `
    + `${archived - base > 0.3 ? 'YES — archiving does not stop it firing' : 'no — archived rules are inert'} `
    + `(baseline ${base.toFixed(2)}s vs ${archived.toFixed(2)}s)`);
}
