/**
 * Which of the catalog's Japanese voices reads proper nouns best?
 *
 * Voice was never a variable in this investigation — every measurement used Shizuka, the
 * default. But the library labels these voices by role (narrator, educational) and accent
 * (Kanto vs Standard), and a voice built for narration may simply handle names better. If one
 * does, that is a fix with no dictionary, no rules and no collision risk.
 *
 * One sentence carrying three of the eight known failures, each voice in the production
 * configuration and again bare, so voice and settings stay separable.
 */
import { writeFileSync } from 'node:fs';
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch {}
const KEY = process.env.ELEVEN_KEY;
const OUT = process.env.PROBE_OUT ?? new URL('out/', import.meta.url).pathname;
const TEXT = '黄前久美子と鎧塚みぞれは、秀一の話をしていました。';
const SETTINGS = { stability: 0.65, similarity_boost: 0.75, style: 0.0, use_speaker_boost: true, speed: 1.0 };

const VOICES = [
  { id: 'WQz3clzUdMqvBf0jswZQ', name: 'shizuka',  label: 'Shizuka — Natural & Soft (Standard) — our default' },
  { id: 'deKmbWEKZdwxcKxxcfvP', name: 'maiko',    label: 'Maiko Kokusaki — Calm Japanese Narrator (Kanto)' },
  { id: '17ljzcHzSunXNkdixIEa', name: 'hirokoji', label: '広小路学 — ex-TV announcer (Standard)' },
  { id: 'Mv8AjrYZCBkdsmDHNwcB', name: 'ishibashi',label: 'Ishibashi — Strong Japanese (Kanto)' },
  { id: 'ss9cJxDAEMXP4wfQ3GPr', name: 'daisuke',  label: 'Daisuke — Calm, Educational (Kanto)' },
];

for (const v of VOICES) {
  for (const [mode, body] of [['prod', { language_code: 'ja', voice_settings: SETTINGS }], ['bare', {}]]) {
    const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${v.id}/stream/with-timestamps?output_format=mp3_44100_128`, {
      method: 'POST', headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: TEXT, model_id: 'eleven_flash_v2_5', ...body }),
    });
    if (!r.ok) { console.log(`${v.name}/${mode}: HTTP ${r.status}`); continue; }
    const chunks = (await r.text()).split('\n').filter(Boolean).map(l => JSON.parse(l));
    const audio = Buffer.concat(chunks.map(c => Buffer.from(c.audio_base64 ?? '', 'base64')));
    writeFileSync(`${OUT}/audio/voice-${v.name}-${mode}.mp3`, audio);
    console.log(`  ${v.name.padEnd(10)} ${mode.padEnd(5)} ${(audio.length/16000).toFixed(2)}s`);
  }
}
console.log(`\ntext: ${TEXT}`);
