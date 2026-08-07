/**
 * End to end: the 122 rules PronunciationLexicon derived from the real book, uploaded as a
 * real dictionary, against the chapter that is nothing but names.
 *
 * Everything else matches production — eleven_flash_v2_5, Shizuka, language_code ja, the
 * pinned voice_settings, stream/with-timestamps, mp3_44100_128 — so the only difference
 * between the two clips is the lexicon this app built by itself.
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch {}
const KEY = process.env.ELEVEN_KEY;
const OUT = process.env.PROBE_OUT ?? new URL('out/', import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });

const rules = JSON.parse(readFileSync((process.env.PROBE_RULES ?? ''), 'utf8'))
  .map(r => ({ ...r, type: 'alias', case_sensitive: true, word_boundaries: false }));
const TEXT = readFileSync((process.env.PROBE_TEXT ?? ''), 'utf8')
  .normalize('NFKC');
const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const MP3 = 16000;

const api = (p, i) => fetch(`https://api.elevenlabs.io/v1${p}`, {
  ...i, headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(i?.headers ?? {}) },
});

const res = await api('/pronunciation-dictionaries/add-from-rules', {
  method: 'POST',
  body: JSON.stringify({ name: 'yomi-euph-book-lexicon', description: 'built by PronunciationLexicon', rules }),
});
if (!res.ok) { console.error('create:', res.status, (await res.text()).slice(0, 300)); process.exit(1); }
const dict = await res.json();
console.log(`dictionary ${dict.id} v${dict.version_id}, ${dict.version_rules_num} rules accepted`);

async function synth(label, locators) {
  const r = await api(`/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`, {
    method: 'POST',
    body: JSON.stringify({
      text: TEXT, model_id: 'eleven_flash_v2_5', language_code: 'ja',
      voice_settings: { stability: 0.65, similarity_boost: 0.75, style: 0.0,
                        use_speaker_boost: true, speed: 1.0 },
      ...(locators ? { pronunciation_dictionary_locators: locators } : {}),
    }),
  });
  if (!r.ok) throw new Error(`${label}: ${r.status} ${(await r.text()).slice(0, 200)}`);
  const chunks = (await r.text()).split('\n').filter(Boolean).map(l => JSON.parse(l));
  const audio = Buffer.concat(chunks.map(c => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const ch = chunks.flatMap(c => c.alignment?.characters ?? []);
  const et = chunks.flatMap(c => c.alignment?.character_end_times_seconds ?? []);
  const audioSec = audio.length / MP3, alignSec = et.at(-1) ?? 0;
  writeFileSync(`${OUT}/${label}.mp3`, audio);
  console.log(`  ${label.padEnd(8)} audio ${audioSec.toFixed(2)}s  undescribed ${(audioSec - alignSec).toFixed(3)}s`
    + `  joinOK ${ch.join('') === TEXT}  chars ${ch.length}/${[...TEXT].length}`);
  return { audioSec, undescribed: audioSec - alignSec, joinOK: ch.join('') === TEXT };
}

console.log(`text ${[...TEXT].length} chars (the chapter-5 character list)`);
const before = await synth('before', null);
const after = await synth('after', [{ pronunciation_dictionary_id: dict.id, version_id: dict.version_id }]);
console.log(`\nΔ duration ${(after.audioSec - before.audioSec).toFixed(2)}s`);
console.log(`alignment contract held on both: ${before.joinOK && after.joinOK}`);
console.log(`dictionary to archive later: ${dict.id}`);
