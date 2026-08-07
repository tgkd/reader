#!/usr/bin/env node
/**
 * Builds the A/B demo: every hard case synthesized twice on the production model and
 * voice — once exactly as production sends it today, once with a single alias rule added.
 *
 * This is the one question the measurements could not answer. Experiments A–E proved an
 * alias fires, that the alignment still describes the audio, and that the lifecycle is
 * workable. None of them prove the narration got BETTER — only ears can settle that, and
 * only against the names the reader actually gets wrong.
 *
 * Everything but the dictionary matches production: eleven_flash_v2_5, Shizuka,
 * language_code ja, the pinned voice_settings, stream/with-timestamps, mp3_44100_128.
 */
import { writeFileSync } from 'node:fs';

try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY'); process.exit(1); }

const OUT = process.env.PROBE_OUT ?? new URL('out/', import.meta.url).pathname;
const VOICE = 'WQz3clzUdMqvBf0jswZQ';           // Shizuka
const MODEL = 'eleven_flash_v2_5';
const MP3_BYTES_PER_SECOND = 16000;

/// Every case is a real failure recorded in docs/2026-08-03-findings.md §4, plus the old
/// orthography that drove the original move to v3.
const CASES = [
  { id: 'kitauji', surface: '黄前', alias: 'おうまえ',
    text: '黄前久美子は北宇治高校の一年生です。',
    why: 'IPADic reads 黄前 as きぜん. Publisher ruby says おうまえ.' },
  { id: 'nozomi', surface: '希美', alias: 'のぞみ',
    text: '希美は去年のことを話しませんでした。',
    why: 'IPADic reads 希美 as きみ. Publisher ruby says のぞみ.' },
  { id: 'sapphire', surface: '緑輝', alias: 'サファイア',
    text: '緑輝はコントラバスを弾いています。',
    why: 'A name, not a reading — no tokenizer can derive サファイア from 緑輝.' },
  { id: 'yoroizuka', surface: '鎧塚', alias: 'よろいづか',
    text: '鎧塚みぞれは黙って立っていました。',
    why: 'Rendaku dropped by the tokenizer (よろいつか).' },
  { id: 'umare', surface: '生れ', alias: 'うまれ',
    text: '私は東京の生れです。',
    why: 'Pre-war orthography. multilingual_v2 says なまれ. This is why v3 was tried.' },
  { id: 'shuichi', surface: '秀一', alias: 'しゅういち',
    text: '秀一は幼なじみでした。',
    why: 'MeCab keeps 秀一 whole and reads ひでかず.' },
  { id: 'myojo', surface: '明静工科', alias: 'みょうじょうこうか',
    text: '明静工科高校が全国大会に出ます。',
    why: 'School name; restored from flattened ruby, MeCab cannot confirm it.' },
  { id: 'rakushu', surface: '洛秋', alias: 'らくしゅう',
    text: '洛秋高校との合同練習がありました。',
    why: 'Another proper noun that only the book knows.' },
];

const api = (path, init) => fetch(`https://api.elevenlabs.io/v1${path}`, {
  ...init,
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
});

async function synth(text, locators) {
  const res = await api(
    `/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`, {
      method: 'POST',
      body: JSON.stringify({
        text, model_id: MODEL, language_code: 'ja',
        voice_settings: {
          stability: 0.65, similarity_boost: 0.75, style: 0.0,
          use_speaker_boost: true, speed: 1.0,
        },
        ...(locators ? { pronunciation_dictionary_locators: locators } : {}),
      }),
    });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const chunks = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const audio = Buffer.concat(chunks.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const chars = [], et = [];
  for (const c of chunks) {
    if (!c.alignment) continue;
    chars.push(...c.alignment.characters);
    et.push(...c.alignment.character_end_times_seconds);
  }
  return {
    audio,
    joinOK: chars.join('') === text,
    audioSec: audio.length / MP3_BYTES_PER_SECOND,
    alignSec: et.at(-1) ?? 0,
    chars: chars.length,
  };
}

// One dictionary holding every rule, exactly as a shipped global lexicon would look.
const dict = await api('/pronunciation-dictionaries/add-from-rules', {
  method: 'POST',
  body: JSON.stringify({
    name: 'yomi-demo-lexicon',
    description: 'A/B demo for the reader pronunciation investigation',
    rules: CASES.map((c) => ({
      string_to_replace: c.surface, type: 'alias', alias: c.alias,
      case_sensitive: true, word_boundaries: false,
    })),
  }),
}).then(async (r) => {
  if (!r.ok) throw new Error(`create dict: ${r.status} ${await r.text()}`);
  return r.json();
});
console.log(`dictionary ${dict.id} v${dict.version_id} (${dict.version_rules_num} rules)\n`);
const loc = [{ pronunciation_dictionary_id: dict.id, version_id: dict.version_id }];

const rows = [];
for (const c of CASES) {
  process.stdout.write(`${c.id.padEnd(11)} `);
  const before = await synth(c.text, null);
  const after = await synth(c.text, loc);
  writeFileSync(`${OUT}/audio/${c.id}-before.mp3`, before.audio);
  writeFileSync(`${OUT}/audio/${c.id}-after.mp3`, after.audio);
  rows.push({ ...c, before, after });
  console.log(`before ${before.audioSec.toFixed(2)}s (undesc ${(before.audioSec - before.alignSec).toFixed(3)}s)`
    + `  after ${after.audioSec.toFixed(2)}s (undesc ${(after.audioSec - after.alignSec).toFixed(3)}s)`
    + `  joinOK ${before.joinOK && after.joinOK}`);
}

writeFileSync(`${OUT}/cases.json`, JSON.stringify(
  rows.map((r) => ({
    id: r.id, surface: r.surface, alias: r.alias, text: r.text, why: r.why,
    before: { audioSec: r.before.audioSec, alignSec: r.before.alignSec, joinOK: r.before.joinOK, chars: r.before.chars },
    after: { audioSec: r.after.audioSec, alignSec: r.after.alignSec, joinOK: r.after.joinOK, chars: r.after.chars },
  })), null, 2));

console.log(`\ndictionary to archive afterwards: ${dict.id}`);
console.log(`wrote ${rows.length * 2} mp3s + cases.json to ${OUT}`);
