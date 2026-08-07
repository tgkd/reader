/**
 * Five consecutive eleven_v3 generations of the same chapter-5 character list.
 *
 * Two questions at once:
 *   1. How often does the alignment defect actually fire? Two runs earlier today gave 8.29 s
 *      and 0.77 s, so it is stochastic; five runs give a rough rate rather than an anecdote.
 *   2. Does the unbudgeted speech land on the BLANK positions? This page is full of
 *      full-width spaces (黄前　久美子, plus indentation) which NFKC folds to ordinary spaces —
 *      exactly the positions where a model might vocalise something that is not in the text.
 *      That is checkable without ears: look at the duration the alignment assigns to each
 *      space character and find the abnormally long ones.
 *
 * Nothing is cached: ElevenLabs generates afresh per request, which is why the two earlier
 * runs disagreed at all.
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch {}
const KEY = process.env.ELEVEN_KEY;
const OUT = process.env.PROBE_OUT ?? new URL('out/', import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });

const TEXT = readFileSync((process.env.PROBE_TEXT ?? ''), 'utf8')
  .normalize('NFKC');                       // exactly what the app sends
const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const MP3 = 16000;
const RUNS = 5;

console.log(`text ${[...TEXT].length} chars, ${(TEXT.match(/ /g) ?? []).length} spaces after NFKC`);
console.log(`${RUNS} runs x ~851 credits = ~${RUNS * 851} credits (~$${(RUNS * 851 * 0.00015).toFixed(2)})\n`);

const summary = [];
for (let run = 1; run <= RUNS; run++) {
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`, {
      method: 'POST', headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text: TEXT, model_id: 'eleven_v3', language_code: 'ja',
        voice_settings: { stability: 0.65, similarity_boost: 0.75, style: 0.0,
                          use_speaker_boost: true, speed: 1.0 },
      }),
    });
  if (!res.ok) { console.log(`run ${run}: HTTP ${res.status} ${(await res.text()).slice(0,160)}`); continue; }

  const chunks = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const audio = Buffer.concat(chunks.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const ch = [], st = [], et = [];
  for (const c of chunks) {
    if (!c.alignment) continue;
    ch.push(...c.alignment.characters);
    st.push(...c.alignment.character_start_times_seconds);
    et.push(...c.alignment.character_end_times_seconds);
  }
  const audioSec = audio.length / MP3;
  const alignSec = et.at(-1) ?? 0;
  const undescribed = audioSec - alignSec;
  writeFileSync(`${OUT}/run${run}.mp3`, audio);

  // What did the blank positions get?
  const blanks = [];
  for (let i = 0; i < ch.length; i++) {
    if (!/^[\s　]$/.test(ch[i])) continue;
    blanks.push({ i, dur: et[i] - st[i], at: st[i], ctx: ch.slice(Math.max(0, i - 6), i + 6).join('') });
  }
  blanks.sort((a, b) => b.dur - a.dur);
  const blankTotal = blanks.reduce((s, b) => s + b.dur, 0);

  summary.push({ run, audioSec, alignSec, undescribed, joinOK: ch.join('') === TEXT,
                 backwards: st.filter((v, i) => i && v < st[i-1] - 1e-9).length,
                 blanks: blanks.length, blankTotal, worst: blanks[0] });

  console.log(`run ${run}: audio ${audioSec.toFixed(2)}s  align ${alignSec.toFixed(2)}s`
    + `  undescribed ${undescribed.toFixed(2)}s ${undescribed > 1.0 ? '<-- REJECTED by guard' : ''}`
    + `  joinOK ${ch.join('') === TEXT}`);
  console.log(`        blanks: ${blanks.length}, total ${blankTotal.toFixed(2)}s`
    + `, longest ${blanks[0]?.dur.toFixed(2)}s at ${blanks[0]?.at.toFixed(1)}s  «${blanks[0]?.ctx.replace(/\n/g,'⏎')}»`);
  console.log(`        top blanks: ${blanks.slice(0,5).map(b => b.dur.toFixed(2)).join(', ')}s`);
}

const rejected = summary.filter((s) => s.undescribed > 1.0).length;
console.log(`\n=== ${rejected}/${summary.length} runs would be REJECTED by the 1.0 s guard ===`);
console.log(`undescribed per run: ${summary.map(s => s.undescribed.toFixed(2)).join('s, ')}s`);
console.log(`audio length per run: ${summary.map(s => s.audioSec.toFixed(1)).join('s, ')}s`);
console.log(`\nmp3s in ${OUT}`);
