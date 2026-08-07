#!/usr/bin/env node
/**
 * Probe 3. Probe 2 established that an alias with word_boundaries:false DOES fire inside
 * CJK, and that `alignment.characters` still joins back to the ORIGINAL submitted text.
 *
 * That leaves the question those two facts create together: the audio got longer, the
 * character list did not. So which characters absorb the alias, and is the total still
 * described?
 *
 * Three ways this can go, and only the first is shippable:
 *   1. the aliased characters' own span stretches to cover the spoken alias, everything
 *      after it shifts later — highlight stays correct;
 *   2. the alias audio is left UNDESCRIBED (alignment ends early) — the same defect that
 *      disqualified eleven_v3, and WorkerTTSService's 1.0 s guard rejects it;
 *   3. the timings smear, so following characters are systematically early — the
 *      "highlight leads the voice" bug.
 *
 * Printing per-character timings around the aliased span distinguishes all three.
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY'); process.exit(1); }

const OUT = join(here, 'dict-probe-out');
mkdirSync(OUT, { recursive: true });

const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const MODEL = 'eleven_flash_v2_5';
const MP3_BYTES_PER_SECOND = 16000;
const TEXT = '黄前久美子です。今日はいい天気ですね。'.normalize('NFKC');

const api = (path, init) => fetch(`https://api.elevenlabs.io/v1${path}`, {
  ...init,
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
});

async function makeDict(name, alias) {
  const res = await api('/pronunciation-dictionaries/add-from-rules', {
    method: 'POST',
    body: JSON.stringify({
      name,
      description: 'Yomi alias probe — safe to delete',
      rules: [{
        string_to_replace: '黄前', type: 'alias', alias,
        case_sensitive: true, word_boundaries: false,
      }],
    }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`create dict HTTP ${res.status}: ${body.slice(0, 300)}`);
  return JSON.parse(body);
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
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);

  const chunks = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const audio = Buffer.concat(chunks.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const chars = [], st = [], et = [];
  for (const c of chunks) {
    if (!c.alignment) continue;
    chars.push(...c.alignment.characters);
    st.push(...c.alignment.character_start_times_seconds);
    et.push(...c.alignment.character_end_times_seconds);
  }
  const audioSec = audio.length / MP3_BYTES_PER_SECOND;
  const alignSec = et.at(-1) ?? 0;
  writeFileSync(join(OUT, `p3-${label}.mp3`), audio);

  console.log(`\n### ${label}`);
  console.log(`  joinOK ${chars.join('') === TEXT}   audio ${audioSec.toFixed(3)}s`
    + `   alignEnd ${alignSec.toFixed(3)}s   UNDESCRIBED ${(audioSec - alignSec).toFixed(3)}s`
    + `   ${audioSec - alignSec > 1.0 ? '<-- WOULD BE REJECTED by the 1.0s guard' : '(within guard)'}`);
  console.log('  per-character timings:');
  for (let i = 0; i < chars.length; i++) {
    const dur = et[i] - st[i];
    console.log(`    ${String(i).padStart(2)} ${JSON.stringify(chars[i])}`
      + `  ${st[i].toFixed(3)} → ${et[i].toFixed(3)}  (${dur.toFixed(3)}s)`
      + (dur > 0.45 ? '   <-- long' : ''));
  }
  const backwards = st.filter((v, i) => i && v < st[i - 1] - 1e-9).length;
  console.log(`  backwards starts: ${backwards}`);
  return { audioSec, alignSec, undescribed: audioSec - alignSec, st, et };
}

const dReal = await makeDict('yomi-probe3-realistic', 'おうまえ');
const dLong = await makeDict('yomi-probe3-long', 'ぬるぽぬるぽぬるぽぬるぽぬるぽぬるぽ');
const loc = (d) => [{ pronunciation_dictionary_id: d.id, version_id: d.version_id }];

const base = await synth('no-dict-control', null);
const real = await synth('alias-realistic-おうまえ', loc(dReal));
const long = await synth('alias-long-diagnostic', loc(dLong));

console.log('\n================ VERDICT ================');
console.log(`control      audio ${base.audioSec.toFixed(2)}s  undescribed ${base.undescribed.toFixed(3)}s`);
console.log(`realistic    audio ${real.audioSec.toFixed(2)}s  undescribed ${real.undescribed.toFixed(3)}s`);
console.log(`long (diag)  audio ${long.audioSec.toFixed(2)}s  undescribed ${long.undescribed.toFixed(3)}s`);
console.log(`\nIf undescribed stays ~0.05s while audio grows, the aliased characters absorb`);
console.log(`the alias and the alignment stays honest — the dictionary path is shippable.`);
console.log(`dictionaries created: ${dReal.id}, ${dLong.id}`);
