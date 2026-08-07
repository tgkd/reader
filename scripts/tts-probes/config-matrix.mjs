#!/usr/bin/env node
/**
 * Is the 学校 mispronunciation the MODEL's, or OUR CONFIGURATION's?
 *
 * The playground run that read it correctly differed from our failing run in three ways at
 * once: a different voice (Daisuke, not Shizuka), no `voice_settings` (the voice's own stored
 * settings apply), and no `language_code`. Our production request pins all three.
 *
 * If pronunciation depends on any of them, then some share of what this investigation has
 * been attributing to the model — and proposing to fix with a dictionary — is self-inflicted,
 * and the dictionary is the wrong remedy for that share.
 *
 * Same text, same model, one variable at a time. Also runs a name case, because if config
 * matters for a common word it may matter for the eight failures too.
 */
import { writeFileSync } from 'node:fs';

try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY'); process.exit(1); }

const OUT = process.env.PROBE_OUT ?? new URL('out/', import.meta.url).pathname;
const MODEL = 'eleven_flash_v2_5';
const MP3 = 16000;

const SHIZUKA = 'WQz3clzUdMqvBf0jswZQ';   // our default
const DAISUKE = 'ss9cJxDAEMXP4wfQ3GPr';   // the playground voice that read it correctly

const OUR_SETTINGS = {
  stability: 0.65, similarity_boost: 0.75, style: 0.0,
  use_speaker_boost: true, speed: 1.0,
};

const TEXTS = [
  { id: 'gakko', text: '学校まで歩いて行きました。', note: 'the common word that failed for us' },
  { id: 'kitauji', text: '黄前久美子は北宇治高校の一年生です。', note: 'a name from the original eight' },
];

/// One variable at a time off the production baseline.
const CELLS = [
  { id: 'prod',            voice: SHIZUKA, settings: OUR_SETTINGS, lang: 'ja',  note: 'exactly production' },
  { id: 'no-lang',         voice: SHIZUKA, settings: OUR_SETTINGS, lang: null,  note: 'drop language_code' },
  { id: 'no-settings',     voice: SHIZUKA, settings: null,         lang: 'ja',  note: 'drop voice_settings' },
  { id: 'bare-shizuka',    voice: SHIZUKA, settings: null,         lang: null,  note: 'playground-like, our voice' },
  { id: 'daisuke-prod',    voice: DAISUKE, settings: OUR_SETTINGS, lang: 'ja',  note: 'our config, their voice' },
  { id: 'bare-daisuke',    voice: DAISUKE, settings: null,         lang: null,  note: 'exactly what you tested' },
  { id: 'stability-05',    voice: SHIZUKA, settings: { ...OUR_SETTINGS, stability: 0.5 }, lang: 'ja', note: 'API default stability' },
];

async function synth(label, text, cell) {
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${cell.voice}/stream/with-timestamps`
    + `?output_format=mp3_44100_128`, {
      method: 'POST',
      headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text, model_id: MODEL,
        ...(cell.lang ? { language_code: cell.lang } : {}),
        ...(cell.settings ? { voice_settings: cell.settings } : {}),
      }),
    });
  if (!res.ok) throw new Error(`${label}: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
  const chunks = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const audio = Buffer.concat(chunks.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  writeFileSync(`${OUT}/audio/${label}.mp3`, audio);
  return audio.length / MP3;
}

const rows = [];
for (const t of TEXTS) {
  console.log(`\n--- ${t.id}: ${t.text}  (${t.note}) ---`);
  for (const c of CELLS) {
    const label = `cfg-${t.id}-${c.id}`;
    const sec = await synth(label, t.text, c);
    rows.push({ text: t.id, cell: c.id, note: c.note, sec, label });
    console.log(`  ${c.id.padEnd(16)} ${c.note.padEnd(26)} ${sec.toFixed(2)}s`);
  }
}
writeFileSync(`${OUT}/cases3.json`, JSON.stringify(rows, null, 2));
console.log('\nno dictionaries created — this is a pure configuration matrix');
