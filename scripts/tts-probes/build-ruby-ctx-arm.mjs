#!/usr/bin/env node
import { writeFileSync, readFileSync } from 'node:fs';

try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY in .env'); process.exit(1); }

const BASES_IN = process.env.PROBE_BASES;
if (!BASES_IN) { console.error('set PROBE_BASES to the CTXJSON dump'); process.exit(1); }

const STAMP = process.env.PROBE_STAMP ?? new Date().toISOString().slice(0, 10);
const ROOT = process.env.PROBE_OUT
  ?? new URL(`out/${STAMP}-ruby-loss-demo/`, import.meta.url).pathname;
const AUDIO = `${ROOT}/audio`;

const data = JSON.parse(readFileSync(`${ROOT}/cases.json`, 'utf8'));
const bases = JSON.parse(readFileSync(BASES_IN, 'utf8'));
const byKey = new Map(bases.map((b) => [`${b.surface}→${b.bookReading}`, b]));

const VOICE = data.voice;
const MODEL = data.model;
const SETTINGS = data.settings;
const MP3_BYTES_PER_SECOND = 16000;

const api = (path, init) => fetch(`https://api.elevenlabs.io/v1${path}`, {
  ...init,
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
});

const matched = data.results
  .map((c) => ({ c, base: byKey.get(`${c.surface}→${c.bookReading}`) }))
  .filter((x) => x.base && x.c.sentence.includes(x.base.base));

const rules = [...new Map(matched.map(({ base }) => [base.base, {
  string_to_replace: base.base, type: 'alias', alias: base.baseReading,
  case_sensitive: true, word_boundaries: false,
}])).values()];

console.log(`${matched.length} of ${data.results.length} cases have a contextual base in scope`);
console.log(`${rules.length} distinct rules to upload`);
const chars = matched.reduce((n, { c }) => n + [...c.sentence].length * 2, 0);
console.log(`~${chars} characters over two new arms ≈ $${(chars / 1000 * 0.10).toFixed(2)}\n`);

const dict = await api('/pronunciation-dictionaries/add-from-rules', {
  method: 'POST',
  body: JSON.stringify({
    name: `yomi-ruby-ctx-${STAMP}`,
    description: 'Contextual bases derived from publisher ruby, fully vouched in-book',
    rules,
  }),
}).then(async (r) => {
  if (!r.ok) throw new Error(`create dict: ${r.status} ${await r.text()}`);
  return r.json();
});
console.log(`dictionary ${dict.id} v${dict.version_id} (${dict.version_rules_num} rules)\n`);
const LOCATORS = [{ pronunciation_dictionary_id: dict.id, version_id: dict.version_id }];

async function synth(text, locators) {
  const res = await api(
    `/text-to-speech/${VOICE.id}/stream/with-timestamps?output_format=mp3_44100_128`, {
      method: 'POST',
      body: JSON.stringify({
        text, model_id: MODEL, language_code: 'ja', voice_settings: SETTINGS,
        ...(locators ? { pronunciation_dictionary_locators: locators } : {}),
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
    chars: cs, starts, ends,
    joinOK: cs.join('') === text,
  };
}

const span = (r, text, needle) => {
  const at = text.indexOf(needle);
  if (at < 0 || !r.starts.length || at >= r.starts.length) return null;
  const to = Math.min(at + [...needle].length - 1, r.ends.length - 1);
  return { start: r.starts[at], end: r.ends[to] };
};

for (const { c, base } of matched) {
  process.stdout.write(`${c.id} ${base.base}→${base.baseReading}`.padEnd(32));
  const phraseRef = c.sentence.replace(base.base, base.baseReading);
  for (const [arm, text, needle, locators] of [
    ['ctx', c.sentence, base.base, LOCATORS],
    ['ref2', phraseRef, base.baseReading, null],
  ]) {
    try {
      const r = await synth(text, locators);
      writeFileSync(`${AUDIO}/${c.id}-${arm}.mp3`, r.audio);
      c.arms[arm] = {
        file: `audio/${c.id}-${arm}.mp3`,
        text,
        audioSec: r.audioSec,
        joinOK: r.joinOK,
        target: span(r, text, needle),
      };
      process.stdout.write(` ${arm}:${r.audioSec.toFixed(1)}s`);
    } catch (error) {
      c.arms[arm] = { error: String(error.message ?? error) };
      process.stdout.write(` ${arm}:FAIL`);
    }
  }
  c.contextual = base;
  process.stdout.write('\n');
}

data.dictionary = { id: dict.id, version: dict.version_id, rules: rules.length };
data.contextualCases = matched.length;
writeFileSync(`${ROOT}/cases.json`, JSON.stringify(data, null, 2));
console.log(`\nupdated cases.json — ${matched.length} cases now carry ctx + ref2`);
console.log(`archive afterwards: ${dict.id}`);
