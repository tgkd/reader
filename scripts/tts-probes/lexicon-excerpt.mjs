import { readFileSync, writeFileSync } from 'node:fs';
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch {}
const KEY = process.env.ELEVEN_KEY;
const OUT = process.env.PROBE_OUT ?? new URL('out/', import.meta.url).pathname;
const DICT = { pronunciation_dictionary_id: '4JcmGXCmcS7nLzi19k5f', version_id: 'v6fPn2BCA2kRQ8DY1HAh' };
const MP3 = 16000;
const VOICE = 'WQz3clzUdMqvBf0jswZQ';

const full = readFileSync((process.env.PROBE_TEXT ?? ''), 'utf8').normalize('NFKC');
// The first three entries: 黄前久美子, 加藤葉月, 川島緑輝 — one name per gate outcome.
const TEXT = [...full].slice(0, 168).join('').trimEnd();
console.log(`excerpt ${[...TEXT].length} chars:\n${TEXT}\n`);

for (const [label, loc] of [['short-before', null], ['short-after', [DICT]]]) {
  const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`, {
    method: 'POST', headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      text: TEXT, model_id: 'eleven_flash_v2_5', language_code: 'ja',
      voice_settings: { stability: 0.65, similarity_boost: 0.75, style: 0.0, use_speaker_boost: true, speed: 1.0 },
      ...(loc ? { pronunciation_dictionary_locators: loc } : {}),
    }),
  });
  if (!r.ok) { console.error(label, r.status, (await r.text()).slice(0,200)); continue; }
  const chunks = (await r.text()).split('\n').filter(Boolean).map(l => JSON.parse(l));
  const audio = Buffer.concat(chunks.map(c => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const ch = chunks.flatMap(c => c.alignment?.characters ?? []);
  const et = chunks.flatMap(c => c.alignment?.character_end_times_seconds ?? []);
  writeFileSync(`${OUT}/${label}.mp3`, audio);
  console.log(`  ${label.padEnd(13)} ${(audio.length/MP3).toFixed(2)}s  undescribed ${((audio.length/MP3)-(et.at(-1)??0)).toFixed(3)}s  joinOK ${ch.join('')===TEXT}`);
}
