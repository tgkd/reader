import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';

try { process.loadEnvFile('/Users/paveltrofimov/Projects/j/reader/.env'); } catch {}
const KEY = process.env.ELEVEN_KEY;
const ROOT = '/Users/paveltrofimov/Projects/j/reader/scripts/tts-probes';
const SRC = `${ROOT}/out/2026-09-01-chapter-v3`;
const OUT = `${ROOT}/out/2026-09-01-truncation`;
const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const MODEL = 'eleven_v3';
const RATE = 3.9;
const DRY = process.argv.includes('--dry-run');

const BASE = { stability: 0.65, similarity_boost: 0.75, speed: 1.0 };

function sentences(text) {
  const out = [];
  let cur = '';
  for (const ch of text) {
    cur += ch;
    if ('。！？!?\n'.includes(ch)) { out.push(cur); cur = ''; }
  }
  if (cur) out.push(cur);
  return out;
}

function splitAtMost(text, cap) {
  const segs = [];
  let cur = '';
  for (const s of sentences(text)) {
    if (cur && [...cur].length + [...s].length > cap) { segs.push(cur); cur = ''; }
    cur += s;
  }
  if (cur) segs.push(cur);
  return segs;
}

function prefixAtMost(text, cap) {
  let cur = '';
  for (const s of sentences(text)) {
    if ([...cur].length + [...s].length > cap) break;
    cur += s;
  }
  return cur;
}

const prose = readFileSync(`${SRC}/chap-prose.txt`, 'utf8');
const names = readFileSync(`${SRC}/chap-names.txt`, 'utf8');

const arms = [];
const whole = (tag, text, run) =>
  arms.push({ arm: `${tag}-whole${run ? `-${run}` : ''}`, segments: [text] });
whole('names', names, 1);
whole('names', names, 2);
whole('prose', prose, 1);
arms.push({ arm: 'names-cap1500', segments: splitAtMost(names, 1500) });
arms.push({ arm: 'prose-cap1500', segments: splitAtMost(prose, 1500) });
arms.push({ arm: 'names-pfx2000', segments: [prefixAtMost(names, 2000)] });
arms.push({ arm: 'names-pfx2400', segments: [prefixAtMost(names, 2400)] });

let total = 0;
console.log(`${'arm'.padEnd(18)}${'segs'.padStart(5)}${'chars'.padStart(8)}${'pred s'.padStart(9)}  per-segment`);
for (const a of arms) {
  const lens = a.segments.map(s => [...s].length);
  const sum = lens.reduce((x, y) => x + y, 0);
  total += sum;
  const worst = Math.max(...lens) / RATE;
  console.log(`${a.arm.padEnd(18)}${String(a.segments.length).padStart(5)}${String(sum).padStart(8)}` +
              `${worst.toFixed(0).padStart(9)}  [${lens.join(', ')}]`);
}
console.log(`\ntotal submitted characters: ${total}`);
console.log(`lossless check: ${arms.filter(a => a.arm.includes('cap'))
  .every(a => a.segments.join('') === (a.arm.startsWith('names') ? names : prose)) ? 'OK' : 'FAIL'}`);
console.log(`prefix 2000/2400 are prefixes: ${
  names.startsWith(arms.find(a => a.arm === 'names-pfx2000').segments[0]) &&
  names.startsWith(arms.find(a => a.arm === 'names-pfx2400').segments[0]) ? 'OK' : 'FAIL'}`);
if (DRY) { console.log('\ndry run — nothing sent, nothing written'); process.exit(0); }

if (!KEY) { console.error('ELEVEN_KEY missing'); process.exit(1); }
mkdirSync(OUT, { recursive: true });

async function synth(text, path) {
  const body = {
    text, model_id: MODEL, language_code: 'ja',
    voice_settings: { stability: BASE.stability, similarity_boost: BASE.similarity_boost, speed: BASE.speed },
  };
  const r = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`,
    { method: 'POST', headers: { 'xi-api-key': KEY, 'content-type': 'application/json' },
      body: JSON.stringify(body) });
  const headers = Object.fromEntries(r.headers.entries());
  if (!r.ok) return { ok: false, status: r.status, headers, error: (await r.text()).slice(0, 400) };
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
    model: MODEL, voice: VOICE, voice_settings: body.voice_settings, language_code: 'ja',
    chars: [...text].length, sha256: createHash('sha256').update(text).digest('hex'),
    chunks: lines.length, headers, submitted_path: `${path}.txt`,
  }, null, 1));
  writeFileSync(`${path}.txt`, text);
  return { ok: true, bytes: audio.length, chars: [...text].length,
           alignChars: characters.length, alignEnd: ends.at(-1) ?? 0 };
}

for (const a of arms) {
  for (let i = 0; i < a.segments.length; i++) {
    const name = a.segments.length > 1 ? `${a.arm}-s${String(i + 1).padStart(2, '0')}` : a.arm;
    const path = `${OUT}/${name}`;
    if (existsSync(`${path}.mp3`)) { console.log(`${name.padEnd(24)} SKIP (exists)`); continue; }
    try {
      const r = await synth(a.segments[i], path);
      if (!r.ok) { console.log(`${name.padEnd(24)} HTTP ${r.status} ${r.error}`); continue; }
      const sec = r.bytes / 16000;
      console.log(`${name.padEnd(24)} chars=${String(r.chars).padStart(4)} audio=${sec.toFixed(1)}s ` +
                  `align=${r.alignEnd.toFixed(1)}s residual=${(sec - r.alignEnd).toFixed(3)}s ` +
                  `rate=${(r.chars / sec).toFixed(2)}c/s labels=${r.alignChars}`);
    } catch (e) { console.log(`${name.padEnd(24)} ERROR ${e.message}`); }
  }
}
console.log(`\nartifacts in ${OUT}`);
