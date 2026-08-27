#!/usr/bin/env node
import { writeFileSync, mkdirSync, readFileSync } from 'node:fs';

try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY in .env'); process.exit(1); }

const CASES_IN = process.env.PROBE_CASES;
if (!CASES_IN) {
  console.error('set PROBE_CASES to the LOSSJSON dump from RubyCoverageProbe');
  process.exit(1);
}

const STAMP = process.env.PROBE_STAMP ?? new Date().toISOString().slice(0, 10);
const ROOT = process.env.PROBE_OUT
  ?? new URL(`out/${STAMP}-ruby-loss-demo/`, import.meta.url).pathname;
const AUDIO = `${ROOT}/audio`;
mkdirSync(AUDIO, { recursive: true });

const VOICE = { id: 'WQz3clzUdMqvBf0jswZQ', name: 'Shizuka' };
const MODEL = 'eleven_multilingual_v2';
const MP3_BYTES_PER_SECOND = 16000;
const SETTINGS = {
  stability: 0.65, similarity_boost: 0.75, style: 0.0, use_speaker_boost: true, speed: 1.0,
};

const TOP = Number(process.env.PROBE_TOP ?? 20);
const TAIL = Number(process.env.PROBE_TAIL ?? 16);

const all = JSON.parse(readFileSync(CASES_IN, 'utf8'));
const repeated = all.filter((c) => c.count > 1);
const singles = all.filter((c) => c.count === 1);
const top = repeated.slice(0, TOP);
const step = singles.length > TAIL ? Math.floor(singles.length / TAIL) : 1;
const sampled = singles.filter((_, i) => i % step === 0).slice(0, TAIL);
const chosen = [...top, ...sampled].map((c, i) => ({ ...c, id: `c${String(i).padStart(2, '0')}` }));

const droppedPairs = all.length - chosen.length;
const droppedOccurrences = all.reduce((n, c) => n + c.count, 0)
  - chosen.reduce((n, c) => n + c.count, 0);

const reference = (c) => {
  const at = c.sentence.indexOf(c.surface);
  if (at < 0) return null;
  return c.sentence.slice(0, at) + c.bookReading + c.sentence.slice(at + c.surface.length);
};

const chars = chosen.reduce((n, c) => n + [...c.sentence].length * 2, 0);
console.log(`${chosen.length} cases (${top.length} repeated + ${sampled.length} sampled from the `
  + `${singles.length}-long tail), dropping ${droppedPairs} pairs / ${droppedOccurrences} occurrences`);
console.log(`~${chars} characters over two arms ≈ $${(chars / 1000 * 0.10).toFixed(2)} on ${MODEL}\n`);

async function synth(text) {
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${VOICE.id}/stream/with-timestamps`
      + '?output_format=mp3_44100_128',
    {
      method: 'POST',
      headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text, model_id: MODEL, language_code: 'ja', voice_settings: SETTINGS,
      }),
    });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const lines = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const audio = Buffer.concat(lines.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const cs = [], starts = [], ends = [];
  for (const c of lines) {
    if (!c.alignment) continue;
    cs.push(...c.alignment.characters);
    starts.push(...c.alignment.character_start_times_seconds);
    ends.push(...c.alignment.character_end_times_seconds);
  }
  return {
    audio,
    audioSec: audio.length / MP3_BYTES_PER_SECOND,
    alignSec: ends.at(-1) ?? 0,
    chars: cs,
    starts,
    ends,
    joinOK: cs.join('') === text,
  };
}

const span = (r, text, needle) => {
  const at = [...text].join('').indexOf(needle);
  if (at < 0 || !r.starts.length) return null;
  const to = Math.min(at + [...needle].length - 1, r.ends.length - 1);
  if (at >= r.starts.length) return null;
  return { start: r.starts[at], end: r.ends[to] };
};

const results = [];
for (const c of chosen) {
  const ref = reference(c);
  if (!ref) { console.log(`${c.id} SKIP (surface not in sentence)`); continue; }
  process.stdout.write(`${c.id} ${c.surface}→${c.bookReading}`.padEnd(28));
  const row = { ...c, referenceText: ref, arms: {} };
  for (const [arm, text, needle] of [['raw', c.sentence, c.surface], ['ref', ref, c.bookReading]]) {
    try {
      const r = await synth(text);
      writeFileSync(`${AUDIO}/${c.id}-${arm}.mp3`, r.audio);
      row.arms[arm] = {
        file: `audio/${c.id}-${arm}.mp3`,
        text,
        audioSec: r.audioSec,
        joinOK: r.joinOK,
        target: span(r, text, needle),
      };
      process.stdout.write(` ${arm}:${r.audioSec.toFixed(1)}s`);
    } catch (error) {
      row.arms[arm] = { error: String(error.message ?? error) };
      process.stdout.write(` ${arm}:FAIL`);
    }
  }
  results.push(row);
  process.stdout.write('\n');
}

writeFileSync(`${ROOT}/cases.json`, JSON.stringify({
  generated: new Date().toISOString(),
  voice: VOICE,
  model: MODEL,
  settings: SETTINGS,
  population: {
    distinctPairs: all.length,
    totalOccurrences: all.reduce((n, c) => n + c.count, 0),
    chosenPairs: chosen.length,
    droppedPairs,
    droppedOccurrences,
    tailLength: singles.length,
  },
  results,
}, null, 2));
console.log(`\nwrote ${results.length * 2} mp3s + cases.json to ${ROOT}`);
