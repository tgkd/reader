#!/usr/bin/env node
/**
 * ElevenLabs alignment-fidelity test bench.
 *
 * The question this answers: for a given (model, route, params), does the alignment
 * the API returns actually DESCRIBE the audio it returns? That is the property the
 * word-synced highlight depends on, and the one nothing in the docs promises.
 *
 * For each cell it records:
 *   joinOK        alignment.characters.joined() === text
 *   monotonic     start times never decrease
 *   alignSec      alignment extent (last end time)
 *   audioSec      real audio length (bytes / 16000; mp3_44100_128 is CBR)
 *   undescribed   audioSec - alignSec   <-- the defect: audio with no timings
 *   faSec / faLoss  same from /v1/forced-alignment on the generated audio
 *
 * Usage:
 *   node eleven-matrix.mjs <textfile> [--models a,b,c] [--runs N] [--route stream|buffered|both]
 *                          [--voice ID] [--no-lang] [--forced-alignment]
 *   node eleven-matrix.mjs --estimate <textfile>     # cost only, no calls
 */
import { writeFileSync, readFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
try { process.loadEnvFile(join(here, '..', '.env')); } catch { /* ambient env */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY in .env'); process.exit(1); }

const OUT = process.env.OUT_DIR || join(here, '..', '.eleven-matrix');
mkdirSync(OUT, { recursive: true });

const argv = process.argv.slice(2);
// Which flags consume the NEXT argument. Guessing this from "the previous argument
// started with --" mis-reads every boolean flag: `--estimate <textfile>` swallowed the
// file as --estimate's value and left readFileSync('--estimate').
const VALUED = new Set(['models', 'runs', 'route', 'voice']);
const flag = (name, def) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : def;
};
const has = (name) => argv.includes(`--${name}`);

const textFile = argv.find((a, i) => {
  if (a.startsWith('--')) return false;
  const prev = argv[i - 1];
  return !(prev?.startsWith('--') && VALUED.has(prev.slice(2)));
});
if (!textFile) {
  console.error('usage: eleven-matrix.mjs <textfile> [--models a,b] [--runs N] [--route stream|buffered|both]'
    + '\n       eleven-matrix.mjs --estimate <textfile>');
  process.exit(1);
}
const TEXT = readFileSync(textFile, 'utf8').normalize('NFKC');

// 1 credit/char for v3 and multilingual_v2, 0.5 for flash. Creator tier ≈ $0.15/1k credits.
const CREDIT_RATE = { eleven_v3: 1, eleven_multilingual_v2: 1, eleven_flash_v2_5: 0.5, eleven_turbo_v2_5: 0.5 };
const MODELS = flag('models', 'eleven_v3,eleven_multilingual_v2,eleven_flash_v2_5').split(',');
const RUNS = Number(flag('runs', 1));
const ROUTES = flag('route', 'stream') === 'both' ? ['stream', 'buffered'] : [flag('route', 'stream')];
const VOICE = flag('voice', 'WQz3clzUdMqvBf0jswZQ');           // Shizuka
const LANG = has('no-lang') ? null : 'ja';
const DO_FA = has('forced-alignment');

const cells = MODELS.flatMap((m) => ROUTES.flatMap((r) =>
  Array.from({ length: RUNS }, (_, i) => ({ model: m, route: r, run: i + 1 }))));

const credits = cells.reduce((s, c) => s + TEXT.length * (CREDIT_RATE[c.model] ?? 1), 0);
console.log(`text ${TEXT.length} chars · ${cells.length} cells · ~${credits} credits`
  + ` (~$${(credits * 0.00015).toFixed(2)} at $0.15/1k)`
  + (DO_FA ? ` + ${cells.length} forced-alignment calls (STT rate)` : ''));
if (has('estimate')) process.exit(0);

const MP3_BYTES_PER_SECOND = 16000;

async function synth({ model, route }) {
  const path = route === 'stream'
    ? `${VOICE}/stream/with-timestamps`
    : `${VOICE}/with-timestamps`;
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${path}?output_format=mp3_44100_128`, {
      method: 'POST',
      headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text: TEXT,
        model_id: model,
        ...(LANG ? { language_code: LANG } : {}),
        voice_settings: {
          stability: 0.65, similarity_boost: 0.75, style: 0.0,
          use_speaker_boost: true, speed: 1.0,
        },
      }),
    });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);

  // Both routes are folded the same way the app folds them: concatenate audio,
  // concatenate alignment arrays. Buffered returns one JSON object; stream returns
  // NDJSON, one object per chunk with ABSOLUTE timestamps.
  const body = await res.text();
  const chunks = route === 'stream'
    ? body.split('\n').filter(Boolean).map((l) => JSON.parse(l))
    : [JSON.parse(body)];

  const audio = Buffer.concat(chunks.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const characters = [], startTimes = [], endTimes = [];
  for (const c of chunks) {
    const a = c.alignment;
    if (!a) continue;
    characters.push(...a.characters);
    startTimes.push(...a.character_start_times_seconds);
    endTimes.push(...a.character_end_times_seconds);
  }
  return { audio, characters, startTimes, endTimes, chunkCount: chunks.length };
}

async function forcedAlignment(audio) {
  const form = new FormData();
  form.append('file', new Blob([audio], { type: 'audio/mpeg' }), 'chapter.mp3');
  form.append('text', TEXT);
  const res = await fetch('https://api.elevenlabs.io/v1/forced-alignment', {
    method: 'POST', headers: { 'xi-api-key': KEY }, body: form,
  });
  if (!res.ok) return { error: `HTTP ${res.status}: ${(await res.text()).slice(0, 160)}` };
  return res.json();
}

const rows = [];
for (const cell of cells) {
  const tag = `${cell.model}__${cell.route}__${cell.run}`;
  process.stdout.write(`\n${tag} ... `);
  let r;
  try { r = await synth(cell); } catch (e) { console.log(`FAILED ${e.message}`); continue; }

  const audioSec = r.audio.length / MP3_BYTES_PER_SECOND;
  const alignSec = r.endTimes.at(-1) ?? 0;
  const joinOK = r.characters.join('') === TEXT;
  const backwards = r.startTimes.filter((v, i) => i && v < r.startTimes[i - 1] - 1e-9).length;

  writeFileSync(join(OUT, `${tag}.mp3`), r.audio);
  writeFileSync(join(OUT, `${tag}.json`), JSON.stringify({
    text: TEXT,
    alignment: {
      characters: r.characters,
      character_start_times_seconds: r.startTimes,
      character_end_times_seconds: r.endTimes,
    },
  }));

  const row = {
    model: cell.model, route: cell.route, run: cell.run, chunks: r.chunkCount,
    joinOK, backwards, alignSec: +alignSec.toFixed(2), audioSec: +audioSec.toFixed(2),
    undescribed: +(audioSec - alignSec).toFixed(2),
  };

  if (DO_FA) {
    const fa = await forcedAlignment(r.audio);
    if (fa.error) row.fa = fa.error;
    else {
      row.faSec = +(fa.characters?.at(-1)?.end ?? 0).toFixed(2);
      row.faLoss = fa.loss != null ? +fa.loss.toFixed(4) : null;
      writeFileSync(join(OUT, `${tag}.fa.json`), JSON.stringify(fa));
    }
  }
  rows.push(row);
  console.log(`undescribed ${row.undescribed}s  align ${row.alignSec}s  audio ${row.audioSec}s`
    + (row.faSec != null ? `  fa ${row.faSec}s loss ${row.faLoss}` : ''));
}

console.log('\n\n=== summary (undescribed > ~0.05 s means the alignment does not describe the audio) ===');
console.table(rows);
writeFileSync(join(OUT, 'summary.json'), JSON.stringify(rows, null, 2));
console.log(`\nartifacts in ${OUT}`);
