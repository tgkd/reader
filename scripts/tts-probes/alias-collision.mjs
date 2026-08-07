#!/usr/bin/env node
/**
 * Did the collision rules in experiment B fire at all?
 *
 * They sounded unchanged, but 紙→かみ inside 手紙 is a subtle difference (てがみ vs てかみ) and
 * subtlety is exactly what ears are bad at. Re-run the same surfaces in the same sentences with
 * a RIDICULOUS alias, so firing is a duration jump instead of a judgement call.
 *
 * There is a second reason to doubt: every case where firing was previously confirmed had the
 * surface at index 0 of the submitted text (黄前久美子です。). Mid-string matching was never
 * actually isolated. This tests both positions deliberately:
 *
 *   紙 in 手紙  -> index 1, genuinely mid-word
 *   時 in 時計  -> index 0, but inside a compound
 *   花 in 花火  -> index 0, but inside a compound
 *   紙 alone    -> index 0, standalone: the control that must fire if anything does
 */
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY'); process.exit(1); }

const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const LONG = 'ぬるぽぬるぽぬるぽぬるぽぬるぽぬるぽ';   // ~6x, unmissable
const MP3 = 16000;

const api = (p, i) => fetch(`https://api.elevenlabs.io/v1${p}`, {
  ...i, headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(i?.headers ?? {}) },
});

async function makeDict(surface) {
  const r = await api('/pronunciation-dictionaries/add-from-rules', {
    method: 'POST',
    body: JSON.stringify({
      name: `yomi-collision-decisive-${surface}`,
      description: 'decisive collision probe — safe to archive',
      rules: [{ string_to_replace: surface, type: 'alias', alias: LONG,
                case_sensitive: true, word_boundaries: false }],
    }),
  });
  if (!r.ok) throw new Error(`create: ${r.status} ${(await r.text()).slice(0, 200)}`);
  return r.json();
}

async function sec(text, locators) {
  const r = await api(`/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`, {
    method: 'POST',
    body: JSON.stringify({
      text, model_id: 'eleven_flash_v2_5', language_code: 'ja',
      voice_settings: { stability: 0.65, similarity_boost: 0.75, style: 0.0,
                        use_speaker_boost: true, speed: 1.0 },
      ...(locators ? { pronunciation_dictionary_locators: locators } : {}),
    }),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status} ${(await r.text()).slice(0, 200)}`);
  const chunks = (await r.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const bytes = chunks.reduce((n, c) => n + Buffer.from(c.audio_base64 ?? '', 'base64').length, 0);
  return bytes / MP3;
}

const CASES = [
  { surface: '紙', text: '紙を買いました。',       pos: 'index 0, standalone (CONTROL)' },
  { surface: '紙', text: '手紙を書きました。',     pos: 'index 1, inside 手紙' },
  { surface: '時', text: '時計を見てください。',   pos: 'index 0, inside 時計' },
  { surface: '花', text: '花火大会に行きます。',   pos: 'index 0, inside 花火' },
  { surface: '気', text: '天気が良いですね。',     pos: 'index 1, inside 天気' },
];

const dicts = new Map();
const created = [];
for (const c of CASES) {
  if (!dicts.has(c.surface)) {
    const d = await makeDict(c.surface);
    dicts.set(c.surface, [{ pronunciation_dictionary_id: d.id, version_id: d.version_id }]);
    created.push(d.id);
  }
}

console.log('rule alias is ~18 kana, so firing adds seconds — not a judgement call\n');
for (const c of CASES) {
  const before = await sec(c.text, null);
  const after = await sec(c.text, dicts.get(c.surface));
  const d = after - before;
  console.log(`${c.surface} in ${c.text.padEnd(12)} ${c.pos.padEnd(34)}`
    + ` ${before.toFixed(2)}s -> ${after.toFixed(2)}s  Δ${d >= 0 ? '+' : ''}${d.toFixed(2)}s`
    + `  ${d > 1.5 ? 'FIRED' : 'did NOT fire'}`);
}
console.log(`\ndictionaries to archive: ${created.join(' ')}`);
