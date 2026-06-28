#!/usr/bin/env node
/**
 * Capture a real ElevenLabs `with-timestamps` alignment for the sync spike.
 *
 * Your key is read from the environment and never written to disk. Run it
 * yourself so the key never passes through the agent:
 *
 *   ELEVENLABS_KEY=sk_... node scripts/capture-alignment.mjs "日本語の文章" soseki
 *
 * Optional env: VOICE_ID, MODEL_ID (default eleven_multilingual_v2),
 * OUTPUT_FORMAT (default mp3_44100_128).
 *
 * Writes ReaderCore/Tests/ReaderCoreTests/fixtures/<name>.json (+ .mp3).
 * The golden test (AlignmentFixtureTests) auto-activates once a .json exists.
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

// Auto-load the repo-root .env if present (Node 20.6+). Vars set directly win.
try {
  process.loadEnvFile(join(here, '..', '.env'));
} catch {
  /* no .env — rely on the ambient environment */
}

const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) {
  console.error('Set ELEVEN_KEY (or ELEVENLABS_KEY) in .env or the environment.');
  process.exit(1);
}

const VOICE_ID = process.env.VOICE_ID || 'JBFqnCBsd6RMkjVDRZzb'; // George — premade (free-tier API-usable); multilingual_v2 speaks JP
const MODEL_ID = process.env.MODEL_ID || 'eleven_multilingual_v2';
const OUTPUT_FORMAT = process.env.OUTPUT_FORMAT || 'mp3_44100_128';

const rawText =
  process.argv[2] || '吾輩は猫である。名前はまだ無い。どこで生まれたか頓と見当がつかぬ。';
const name = process.argv[3] || 'sample';

// NFKC-normalize so the sent text matches what MeCab tokenizes on the Swift side
// (the single-normalization rule the architecture depends on).
const text = rawText.normalize('NFKC');

const url = `https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}/with-timestamps?output_format=${OUTPUT_FORMAT}`;
const res = await fetch(url, {
  method: 'POST',
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
  body: JSON.stringify({ text, model_id: MODEL_ID }),
});

if (!res.ok) {
  console.error(`ElevenLabs HTTP ${res.status}: ${await res.text()}`);
  process.exit(1);
}

const data = await res.json();
if (!data.alignment) {
  console.error('Response had no `alignment` block.');
  process.exit(1);
}

const fixturesDir = join(here, '..', 'ReaderCore', 'Tests', 'ReaderCoreTests', 'fixtures');
mkdirSync(fixturesDir, { recursive: true });

// Prefer `alignment` (original input) over `normalized_alignment` so indices
// line up with the text we tokenize and display.
const fixture = { text, voiceId: VOICE_ID, modelId: MODEL_ID, alignment: data.alignment };
writeFileSync(join(fixturesDir, `${name}.json`), JSON.stringify(fixture, null, 2));
if (data.audio_base64) {
  writeFileSync(join(fixturesDir, `${name}.mp3`), Buffer.from(data.audio_base64, 'base64'));
}

const n = data.alignment.characters.length;
const dur = data.alignment.character_end_times_seconds[n - 1];
console.log(`Saved fixtures/${name}.json (${n} chars, ${dur.toFixed(2)}s) + ${name}.mp3`);
console.log(`Now run:  cd ReaderCore && swift test`);
