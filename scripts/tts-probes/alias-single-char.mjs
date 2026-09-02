import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch {}
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY'); process.exit(1); }

const OUT = join(here, 'out', '2026-09-02-alias-single-char');
mkdirSync(OUT, { recursive: true });
const VOICE = 'deKmbWEKZdwxcKxxcfvP';
const MODEL = 'eleven_v3';
const LONG_KANA = 'ぬるぽぬるぽぬるぽぬるぽぬるぽぬるぽぬるぽぬるぽ';
const TEXT = '滝 昇は北宇治高校の顧問だ。父も以前、北宇治高校の顧問をしていた。';
const TEXT_LATIN = 'Mr X is the advisor. His father was the advisor too.';

const api = (path, init) => fetch(`https://api.elevenlabs.io/v1${path}`, {
  ...init,
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
});

async function makeDict(name, rules) {
  const res = await api('/pronunciation-dictionaries/add-from-rules', {
    method: 'POST',
    body: JSON.stringify({ name, description: 'Yomi single-char alias probe', rules: rules.map((r) => ({
      ...r, type: 'alias', case_sensitive: true, word_boundaries: false })) }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`create dict HTTP ${res.status}: ${body.slice(0, 400)}`);
  const j = JSON.parse(body);
  console.log(`created ${name}: id=${j.id} version=${j.version_id} rules=${j.version_rules_num}`);
  return { pronunciation_dictionary_id: j.id, version_id: j.version_id };
}

async function archive(locator) {
  const res = await api(`/pronunciation-dictionaries/${locator.pronunciation_dictionary_id}`, {
    method: 'PATCH', body: JSON.stringify({ archived: true }),
  });
  console.log(`archive ${locator.pronunciation_dictionary_id}: HTTP ${res.status}`);
}

async function synth(label, text, locators) {
  const res = await api(`/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`, {
    method: 'POST',
    body: JSON.stringify({
      text, model_id: MODEL, language_code: 'ja',
      voice_settings: { stability: 0.65, similarity_boost: 0.75, speed: 1.0 },
      ...(locators ? { pronunciation_dictionary_locators: locators } : {}),
    }),
  });
  if (!res.ok) { console.log(`${label}: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`); return; }
  const chunks = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const audio = Buffer.concat(chunks.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  writeFileSync(join(OUT, `${label}.mp3`), audio);
  console.log(`${label.padEnd(28)} audio ${(audio.length / 16000).toFixed(2)}s`);
}

const control = await makeDict('yomi-probe-two-char-control', [
  { string_to_replace: '顧問', alias: LONG_KANA },
]);
const single = await makeDict('yomi-probe-single-char', [
  { string_to_replace: '昇', alias: LONG_KANA, type: 'alias' },
]);
const spaced = await makeDict('yomi-probe-spaced-base', [
  { string_to_replace: '滝 昇', alias: LONG_KANA, type: 'alias' },
]);
const latin = await makeDict('yomi-probe-latin-single', [
  { string_to_replace: 'X', alias: 'alpha bravo charlie delta echo foxtrot golf hotel', type: 'alias' },
]);

await synth('ja-baseline', TEXT);
await synth('ja-two-char-顧問', TEXT, [control]);
await synth('ja-single-char-昇', TEXT, [single]);
await synth('ja-spaced-滝␣昇', TEXT, [spaced]);
await synth('latin-baseline', TEXT_LATIN);
await synth('latin-single-X', TEXT_LATIN, [latin]);

for (const l of [control, single, spaced, latin]) await archive(l);
