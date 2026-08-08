// Does attaching a book's WHOLE lexicon change the narration of a chapter, compared with
// attaching only the rules that occur in it?
//
// This is the release gate for the identity fix in docs/2026-08-07-pronunciation-dictionaries.md
// §12. The fix makes the Worker upload the full rule set instead of the chapter-filtered subset,
// so that one book resolves to one dictionary. The whole design rests on absent rules being
// INERT: an alias can only fire where its surface occurs, so rules for names this chapter never
// mentions should change nothing. That is an inference about ElevenLabs' matching, not a
// documented contract, and §7 already measured that redundant aliases cost small pauses — so it
// has to be measured before it is trusted.
//
// Three arms on the same text, N runs each because generation is stochastic and a single sample
// cannot separate a real effect from variance:
//
//   none    no dictionary at all — the floor
//   subset  only the rules that occur in this chapter — what ships today
//   full    the entire book lexicon — what the fix would send
//
// EXIT CONDITION: if `full` differs from `subset` beyond the spread of `subset` against itself,
// the full-set design is dead and the answer is not a bigger cap — see §12.
//
// PROBE_TEXT   chapter to narrate (a file)
// PROBE_RULES  the full book lexicon, [{string_to_replace, alias}]
// PROBE_RUNS   runs per arm (default 3)
// PROBE_OUT    where audio lands

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const KEY = (readFileSync(new URL('../../.env', import.meta.url), 'utf8')
  .match(/ELEVEN_KEY=(.*)/) || [])[1]?.trim();
if (!KEY) throw new Error('ELEVEN_KEY missing from .env');

const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const MODEL = 'eleven_flash_v2_5';
const OUT = process.env.PROBE_OUT
  || new URL('./out/full-set-equivalence', import.meta.url).pathname;
const RUNS = Number(process.env.PROBE_RUNS || 3);

const text = readFileSync(process.env.PROBE_TEXT, 'utf8').normalize('NFKC');
const all = JSON.parse(readFileSync(process.env.PROBE_RULES, 'utf8'));
const subset = all.filter((r) => text.includes(r.string_to_replace));

mkdirSync(OUT, { recursive: true });

const api = (path, init = {}) => fetch(`https://api.elevenlabs.io/v1/${path}`, {
  ...init,
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(init.headers || {}) },
});

async function makeDictionary(name, rules) {
  const r = await api('pronunciation-dictionaries/add-from-rules', {
    method: 'POST',
    body: JSON.stringify({
      name,
      description: 'Yomi probe — full-set equivalence',
      // word_boundaries:false is the whole reason any rule fires inside continuous Japanese.
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
  console.log(`  dictionary ${name}: ${d.id}@${d.version_id} (${d.version_rules_num} rules)`);
  return { pronunciation_dictionary_id: d.id, version_id: d.version_id };
}

// The client sends stream:true and reads NDJSON; each line carries base64 audio plus a slice of
// the character alignment. Absolute timings, so chunks concatenate rather than stitch.
async function synthesize(locator) {
  const body = {
    text,
    model_id: MODEL,
    language_code: 'ja',
    voice_settings: { stability: 0.5, similarity_boost: 0.75, style: 0, use_speaker_boost: true, speed: 1 },
  };
  if (locator) body.pronunciation_dictionary_locators = [locator];

  const r = await api(
    `text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`,
    { method: 'POST', body: JSON.stringify(body) },
  );
  if (!r.ok) throw new Error(`tts: ${r.status} ${(await r.text()).slice(0, 300)}`);

  const audio = [];
  const chars = [];
  const starts = [];
  const ends = [];
  let buf = '';
  for await (const chunk of r.body) {
    buf += Buffer.from(chunk).toString('utf8');
    const lines = buf.split('\n');
    buf = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      const j = JSON.parse(line);
      if (j.audio_base64) audio.push(Buffer.from(j.audio_base64, 'base64'));
      // `alignment`, never `normalized_alignment` — only the former tracks the submitted text.
      const a = j.alignment;
      if (a) {
        chars.push(...a.characters);
        starts.push(...a.character_start_times_seconds);
        ends.push(...a.character_end_times_seconds);
      }
    }
  }
  return { audio: Buffer.concat(audio), chars, starts, ends };
}

// mp3 CBR at 128 kbit/s: bytes/16000 is seconds. Same arithmetic the client uses to know how much
// narration exists (ChapterAudioSource), so a mismatch here is a mismatch there.
const audioSeconds = (buf) => buf.length / 16000;

function measure(res) {
  const joined = res.chars.join('');
  const alignEnd = res.ends.length ? res.ends[res.ends.length - 1] : 0;
  const audioSec = audioSeconds(res.audio);
  let backwards = 0;
  for (let i = 1; i < res.starts.length; i++) if (res.starts[i] < res.starts[i - 1]) backwards++;
  return {
    audioSec: +audioSec.toFixed(3),
    alignSec: +alignEnd.toFixed(3),
    // The client rejects a chapter whose alignment misses its audio by more than 1 s.
    undescribed: +(audioSec - alignEnd).toFixed(3),
    joinOK: joined === text,
    chars: `${res.chars.length}/${[...text].length}`,
    backwards,
  };
}

const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
const spread = (xs) => +(Math.max(...xs) - Math.min(...xs)).toFixed(3);

const arms = [
  { name: 'none', rules: null },
  { name: 'subset', rules: subset },
  { name: 'full', rules: all },
];

console.log(`text ${[...text].length} chars`);
console.log(`rules: full ${all.length}, applicable to this chapter ${subset.length}, `
  + `absent ${all.length - subset.length}`);
if (subset.length === all.length) {
  console.log('WARNING: every rule occurs in this chapter — the arms are identical, '
    + 'this text cannot test the question. Pick a chapter that uses part of the book.');
}

const results = {};
for (const arm of arms) {
  const locator = arm.rules ? await makeDictionary(`probe-fse-${arm.name}-${all.length}`, arm.rules) : null;
  results[arm.name] = [];
  for (let i = 0; i < RUNS; i++) {
    const res = await synthesize(locator);
    const m = measure(res);
    writeFileSync(join(OUT, `${arm.name}-${i + 1}.mp3`), res.audio);
    results[arm.name].push(m);
    console.log(`${arm.name} run ${i + 1}: ${JSON.stringify(m)}`);
  }
}

console.log('\n--- summary ---');
console.log('arm     | mean audio | spread | mean undescribed | joinOK | backwards');
for (const arm of arms) {
  const rs = results[arm.name];
  const secs = rs.map((r) => r.audioSec);
  console.log(
    `${arm.name.padEnd(7)} | ${mean(secs).toFixed(3).padStart(10)} `
    + `| ${String(spread(secs)).padStart(6)} `
    + `| ${mean(rs.map((r) => r.undescribed)).toFixed(3).padStart(16)} `
    + `| ${String(rs.every((r) => r.joinOK)).padStart(6)} `
    + `| ${rs.reduce((a, r) => a + r.backwards, 0)}`,
  );
}

// The decision. `subset` against itself is the noise floor; `full` has to sit inside it.
const sub = results.subset.map((r) => r.audioSec);
const ful = results.full.map((r) => r.audioSec);
const delta = Math.abs(mean(ful) - mean(sub));
const noise = Math.max(spread(sub), spread(ful));
console.log(`\nfull vs subset: mean delta ${delta.toFixed(3)}s, within-arm spread ${noise.toFixed(3)}s`);
console.log(delta <= noise
  ? 'VERDICT: indistinguishable from variance — absent rules look inert.'
  : 'VERDICT: full-set arm moved BEYOND within-arm variance. Listen before trusting the fix.');
console.log(`\naudio in ${OUT} — listening still decides; these numbers only say where to listen.`);
writeFileSync(join(OUT, 'results.json'), JSON.stringify({ text: text.slice(0, 200), results }, null, 2));
