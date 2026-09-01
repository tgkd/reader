import { readFileSync, writeFileSync } from 'node:fs';

try { process.loadEnvFile('/Users/paveltrofimov/Projects/j/reader/.env'); } catch {}
const KEY = process.env.ELEVEN_KEY;
const OUT = '/Users/paveltrofimov/Projects/j/reader/scripts/tts-probes/out/2026-09-01-join-context';
const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const MODEL = 'eleven_v3';
const SETTINGS = { stability: 0.65, similarity_boost: 0.75, speed: 1.0 };

const segments = JSON.parse(readFileSync(`${OUT}/segments.json`, 'utf8'));

async function synth(text, context, tag) {
  const body = { text, model_id: MODEL, language_code: 'ja', voice_settings: SETTINGS, ...context };
  const r = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`,
    { method: 'POST', headers: { 'xi-api-key': KEY, 'content-type': 'application/json' },
      body: JSON.stringify(body) });
  const headers = Object.fromEntries(r.headers.entries());
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`);
  const raw = await r.text();
  const lines = raw.split('\n').filter(Boolean).map(l => JSON.parse(l));
  const audio = Buffer.concat(lines.map(c => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const characters = [], ends = [];
  for (const c of lines) {
    if (!c.alignment) continue;
    characters.push(...c.alignment.characters);
    ends.push(...c.alignment.character_end_times_seconds);
  }
  writeFileSync(`${OUT}/${tag}.mp3`, audio);
  writeFileSync(`${OUT}/${tag}.alignment.json`, JSON.stringify({ characters, ends }));
  writeFileSync(`${OUT}/${tag}.headers.json`, JSON.stringify(headers, null, 1));
  const joined = characters.join('');
  return { audio, seconds: audio.length / 16000, labels: characters.length,
           submitted: [...text].length, joinOK: joined === text, alignEnd: ends.at(-1) ?? 0,
           leaked: joined.length - text.length };
}

for (const [arm, withContext] of [['ctx', true], ['plain', false]]) {
  const parts = [];
  for (let i = 0; i < segments.length; i++) {
    const context = withContext
      ? { ...(i > 0 ? { previous_text: segments[i - 1] } : {}),
          ...(i < segments.length - 1 ? { next_text: segments[i + 1] } : {}) }
      : {};
    const tag = `${arm}-s${i + 1}`;
    try {
      const r = await synth(segments[i], context, tag);
      parts.push(r.audio);
      console.log(`${tag.padEnd(10)} submitted=${String(r.submitted).padStart(4)} labels=${String(r.labels).padStart(4)}` +
                  ` join=${r.joinOK ? 'OK' : `LEAK ${r.leaked}`} audio=${r.seconds.toFixed(1)}s` +
                  ` residual=${(r.seconds - r.alignEnd).toFixed(3)}s ctx=${Object.keys(context).join('+') || 'none'}`);
    } catch (e) { console.log(`${tag.padEnd(10)} ERROR ${e.message}`); }
  }
  if (parts.length === segments.length) {
    writeFileSync(`${OUT}/${arm}-stitched.mp3`, Buffer.concat(parts));
    const secs = parts.slice(0, -1).reduce((a, p) => a + p.length / 16000, 0);
    console.log(`${arm}-stitched.mp3 written — join at ${Math.floor(secs / 60)}:${String(Math.round(secs % 60)).padStart(2, '0')}\n`);
  }
}
