import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';

try { process.loadEnvFile('/Users/paveltrofimov/Projects/j/reader/.env'); } catch {}
const KEY = process.env.ELEVEN_KEY;
const OUT = process.env.PROBE_OUT ?? '/Users/paveltrofimov/Projects/j/reader/scripts/tts-probes/out/2026-09-02-relabel';
const VOICE = process.env.PROBE_VOICE ?? 'deKmbWEKZdwxcKxxcfvP';
const MODEL = 'eleven_v3';
const DRY = process.argv.includes('--dry-run');
const SETTINGS = { stability: 0.65, similarity_boost: 0.75, speed: 1.0 };

const texts = readdirSync(`${OUT}/texts`).filter(f => f.endsWith('.txt')).sort()
  .map(f => ({ name: f.replace(/\.txt$/, ''), text: readFileSync(`${OUT}/texts/${f}`, 'utf8') }));
let total = 0;
for (const t of texts) { total += [...t.text].length; console.log(`${t.name.padEnd(14)} ${[...t.text].length} chars`); }
console.log(`total ${total} chars, voice ${VOICE}, model ${MODEL}`);
if (DRY) process.exit(0);
if (!KEY) { console.error('ELEVEN_KEY missing'); process.exit(1); }

async function synth(text, path) {
  const body = { text, model_id: MODEL, language_code: 'ja', voice_settings: SETTINGS };
  const r = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`,
    { method: 'POST', headers: { 'xi-api-key': KEY, 'content-type': 'application/json' },
      body: JSON.stringify(body) });
  if (!r.ok) return { ok: false, status: r.status, error: (await r.text()).slice(0, 400) };
  const raw = await r.text();
  writeFileSync(`${path}.ndjson`, raw);
  const lines = raw.split('\n').filter(Boolean).map(l => JSON.parse(l));
  const audio = Buffer.concat(lines.map(c => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const characters = [], starts = [], ends = [];
  for (const c of lines) {
    if (!c.alignment) continue;
    characters.push(...c.alignment.characters);
    starts.push(...c.alignment.character_start_times_seconds);
    ends.push(...c.alignment.character_end_times_seconds);
  }
  writeFileSync(`${path}.mp3`, audio);
  writeFileSync(`${path}.alignment.json`, JSON.stringify({ characters, starts, ends }));
  writeFileSync(`${path}.request.json`, JSON.stringify({
    model: MODEL, voice: VOICE, voice_settings: SETTINGS, language_code: 'ja',
    chars: [...text].length, sha256: createHash('sha256').update(text).digest('hex'), chunks: lines.length,
  }, null, 1));
  writeFileSync(`${path}.txt`, text);
  return { ok: true, bytes: audio.length, chars: [...text].length, alignChars: characters.length, alignEnd: ends.at(-1) ?? 0 };
}

for (const t of texts) {
  const path = `${OUT}/${t.name}`;
  if (existsSync(`${path}.mp3`)) { console.log(`${t.name.padEnd(14)} SKIP (exists)`); continue; }
  try {
    const r = await synth(t.text, path);
    if (!r.ok) { console.log(`${t.name.padEnd(14)} HTTP ${r.status} ${r.error}`); continue; }
    const sec = r.bytes / 16000;
    console.log(`${t.name.padEnd(14)} chars=${r.chars} audio=${sec.toFixed(1)}s align=${r.alignEnd.toFixed(1)}s residual=${(sec - r.alignEnd).toFixed(3)}s labels=${r.alignChars}`);
  } catch (e) { console.log(`${t.name.padEnd(14)} ERROR ${e.message}`); }
}
