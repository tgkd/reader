// Does an alias fire against text that another alias produced?
//
// This is the one hole in the safety argument for the full-set identity fix (§12). That argument
// says a rule whose surface is absent from the submitted text is inert, because an alias can only
// match where its surface occurs. True of the SUBMITTED text — but it says nothing about whether
// ElevenLabs applies rules to text it has already rewritten. If replacement is iterative rather
// than single pass, a rule absent from the chapter could match another rule's OUTPUT, and the
// full-set fix would then change pronunciation in a way the subset never could.
//
// The Worker constrains only the READING to kana; `surface` has no character-class restriction
// (aiwork/src/tts.ts), so a kana surface is admissible and this is reachable, not theoretical.
//
// The test: 黄前 → おうまえ, plus a second rule おうまえ → まったくちがう whose surface appears
// NOWHERE in the submitted text. Single-pass matching leaves the second rule inert and both arms
// sound identical. Iterative matching lets it fire on the first rule's output, and the audio says
// something conspicuously different and longer.
//
// The decoy is deliberately long: a firing rule has to be unmistakable in the duration alone, not
// a judgement call on listening.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const KEY = (readFileSync(new URL('../../.env', import.meta.url), 'utf8')
  .match(/ELEVEN_KEY=(.*)/) || [])[1]?.trim();
if (!KEY) throw new Error('ELEVEN_KEY missing from .env');

const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const MODEL = 'eleven_flash_v2_5';
const OUT = process.env.PROBE_OUT || new URL('./out/alias-chaining', import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });

const TEXT = '黄前久美子は今日も部活に行きました。'.normalize('NFKC');

const BASE = { string_to_replace: '黄前', alias: 'おうまえ' };
// Surface = the alias the first rule emits. Absent from TEXT, which spells the name in kanji.
const CHAIN = { string_to_replace: 'おうまえ', alias: 'まったくちがうことばです' };

const arms = [
  { name: 'base', rules: [BASE] },
  { name: 'base+chain', rules: [BASE, CHAIN] },
  // Proves the decoy is audible at all: here its surface IS in the text, so it must fire.
  { name: 'control-direct', rules: [CHAIN], text: 'おうまえ久美子は今日も部活に行きました。'.normalize('NFKC') },
];

const api = (path, init = {}) => fetch(`https://api.elevenlabs.io/v1/${path}`, {
  ...init,
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(init.headers || {}) },
});

async function makeDictionary(name, rules) {
  const r = await api('pronunciation-dictionaries/add-from-rules', {
    method: 'POST',
    body: JSON.stringify({
      name,
      description: 'Yomi probe — alias chaining',
      rules: rules.map((x) => ({
        string_to_replace: x.string_to_replace,
        type: 'alias',
        alias: x.alias,
        case_sensitive: true,
        word_boundaries: false,
      })),
    }),
  });
  if (!r.ok) throw new Error(`create ${name}: ${r.status} ${(await r.text()).slice(0, 300)}`);
  const d = await r.json();
  return { pronunciation_dictionary_id: d.id, version_id: d.version_id };
}

async function synthesize(text, locator) {
  const r = await api(`text-to-speech/${VOICE}?output_format=mp3_44100_128`, {
    method: 'POST',
    body: JSON.stringify({
      text,
      model_id: MODEL,
      language_code: 'ja',
      voice_settings: { stability: 0.5, similarity_boost: 0.75, style: 0, use_speaker_boost: true, speed: 1 },
      ...(locator ? { pronunciation_dictionary_locators: [locator] } : {}),
    }),
  });
  if (!r.ok) throw new Error(`tts: ${r.status} ${(await r.text()).slice(0, 300)}`);
  return Buffer.from(await r.arrayBuffer());
}

const seconds = (buf) => +(buf.length / 16000).toFixed(3);

console.log(`text: ${TEXT}`);
console.log(`base rule : ${BASE.string_to_replace} -> ${BASE.alias}`);
console.log(`chain rule: ${CHAIN.string_to_replace} -> ${CHAIN.alias}  (surface absent from text)\n`);

const out = {};
for (const arm of arms) {
  const locator = await makeDictionary(`probe-chain-${arm.name}`, arm.rules);
  const audio = await synthesize(arm.text || TEXT, locator);
  writeFileSync(join(OUT, `${arm.name}.mp3`), audio);
  out[arm.name] = seconds(audio);
  console.log(`${arm.name.padEnd(15)} ${out[arm.name]}s`);
}

const delta = Math.abs(out['base+chain'] - out.base);
const decoyCost = out['control-direct'] - out.base;
console.log(`\nbase+chain vs base : ${delta.toFixed(3)}s`);
console.log(`decoy when it DOES fire (control-direct vs base): ${decoyCost.toFixed(3)}s`);
console.log(delta < Math.abs(decoyCost) / 2
  ? 'VERDICT: no chaining — the absent-surface rule stayed inert. The §12 safety argument holds.'
  : 'VERDICT: possible CHAINING. Listen to base+chain.mp3. If it fired, the full-set fix needs a '
    + 'surface character-class constraint before it ships.');
console.log(`\naudio in ${OUT}`);
