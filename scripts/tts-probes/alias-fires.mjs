#!/usr/bin/env node
/**
 * Probe 2. Probe 1 showed alignment always returns the ORIGINAL text, but its duration
 * deltas were inside generation noise, so it could not distinguish "the alias fired and
 * the alignment is honest" from "the alias never fired at all".
 *
 * Fix both ambiguities without needing ears:
 *   - the alias is now RIDICULOUSLY long, so firing moves duration by seconds, not by
 *     the ~0.1 s that two takes of the same sentence differ by anyway;
 *   - a LATIN positive control runs the same rule shape on text the matcher certainly
 *     understands. Latin firing + CJK not firing = a CJK matching limit. Neither firing
 *     = alias dictionaries are simply not applied on this model, and the CJK question is
 *     moot.
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

const VOICE = 'WQz3clzUdMqvBf0jswZQ';           // Shizuka
const MP3_BYTES_PER_SECOND = 16000;
const LONG_KANA = 'ぬるぽぬるぽぬるぽぬるぽぬるぽぬるぽぬるぽぬるぽ';
const LONG_LATIN = 'alpha bravo charlie delta echo foxtrot golf hotel india juliet';

const api = (path, init) => fetch(`https://api.elevenlabs.io/v1${path}`, {
  ...init,
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
});

async function makeDict(name, rules) {
  const res = await api('/pronunciation-dictionaries/add-from-rules', {
    method: 'POST',
    body: JSON.stringify({ name, description: 'Yomi alias probe — safe to delete', rules }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`create dict HTTP ${res.status}: ${body.slice(0, 400)}`);
  const j = JSON.parse(body);
  console.log(`  created ${name}: id=${j.id} rules=${j.version_rules_num}`);
  return j;
}

async function synth(label, { text, model, locators, lang }) {
  const res = await api(
    `/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`, {
      method: 'POST',
      body: JSON.stringify({
        text,
        model_id: model,
        ...(lang ? { language_code: lang } : {}),
        voice_settings: {
          stability: 0.65, similarity_boost: 0.75, style: 0.0,
          use_speaker_boost: true, speed: 1.0,
        },
        ...(locators ? { pronunciation_dictionary_locators: locators } : {}),
      }),
    });
  if (!res.ok) { console.log(`  ${label}: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`); return null; }

  const chunks = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const audio = Buffer.concat(chunks.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const characters = [], endTimes = [];
  for (const c of chunks) {
    if (!c.alignment) continue;
    characters.push(...c.alignment.characters);
    endTimes.push(...c.alignment.character_end_times_seconds);
  }
  const joined = characters.join('');
  const audioSec = audio.length / MP3_BYTES_PER_SECOND;
  writeFileSync(join(OUT, `${label}.mp3`), audio);
  console.log(`  ${label.padEnd(34)} audio ${audioSec.toFixed(2)}s  joinOK ${joined === text}`
    + `  alignedChars ${characters.length}/${[...text].length}`);
  return { joined, joinOK: joined === text, audioSec };
}

const dictKanaFalse = await makeDict('yomi-probe2-cjk-long-wbfalse', [{
  string_to_replace: '黄前', type: 'alias', alias: LONG_KANA,
  case_sensitive: true, word_boundaries: false,
}]);
const dictKanaTrue = await makeDict('yomi-probe2-cjk-long-wbtrue', [{
  string_to_replace: '黄前', type: 'alias', alias: LONG_KANA,
  case_sensitive: true, word_boundaries: true,
}]);
const dictLatin = await makeDict('yomi-probe2-latin-control', [{
  string_to_replace: 'ABC', type: 'alias', alias: LONG_LATIN,
  case_sensitive: true, word_boundaries: true,
}]);

const loc = (d) => [{ pronunciation_dictionary_id: d.id, version_id: d.version_id }];
const JA = '黄前久美子です。';
const EN = 'The ABC report is ready.';

console.log('\n--- LATIN POSITIVE CONTROL (eleven_flash_v2_5) ---');
const enBase = await synth('latin-control-nodict', { text: EN, model: 'eleven_flash_v2_5' });
const enDict = await synth('latin-control-dict', { text: EN, model: 'eleven_flash_v2_5', locators: loc(dictLatin) });

console.log('\n--- CJK, eleven_flash_v2_5 ---');
const jaBase = await synth('ja-flash-nodict', { text: JA, model: 'eleven_flash_v2_5', lang: 'ja' });
const jaF = await synth('ja-flash-wbfalse', { text: JA, model: 'eleven_flash_v2_5', lang: 'ja', locators: loc(dictKanaFalse) });
const jaT = await synth('ja-flash-wbtrue', { text: JA, model: 'eleven_flash_v2_5', lang: 'ja', locators: loc(dictKanaTrue) });

console.log('\n--- CJK, eleven_multilingual_v2 (does the model matter?) ---');
const mlBase = await synth('ja-ml2-nodict', { text: JA, model: 'eleven_multilingual_v2' });
const mlF = await synth('ja-ml2-wbfalse', { text: JA, model: 'eleven_multilingual_v2', locators: loc(dictKanaFalse) });

const fired = (base, test) => base && test
  ? (test.audioSec - base.audioSec > 1.0 ? `FIRED (+${(test.audioSec - base.audioSec).toFixed(2)}s)` : 'did NOT fire')
  : 'n/a';

console.log('\n================ VERDICT ================');
console.log(`Latin control, word_boundaries:true   ${fired(enBase, enDict)}`);
console.log(`CJK flash_v2_5, word_boundaries:false ${fired(jaBase, jaF)}`);
console.log(`CJK flash_v2_5, word_boundaries:true  ${fired(jaBase, jaT)}`);
console.log(`CJK multilingual_v2, wb:false         ${fired(mlBase, mlF)}`);
console.log(`\nalignment joined back to submitted text in every cell? `
  + `${[enBase, enDict, jaBase, jaF, jaT, mlBase, mlF].filter(Boolean).every((r) => r.joinOK)}`);
console.log(`dictionaries created: ${dictKanaFalse.id}, ${dictKanaTrue.id}, ${dictLatin.id}`);
