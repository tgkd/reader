#!/usr/bin/env node
import { writeFileSync, mkdirSync, readFileSync } from 'node:fs';

try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const ELEVEN_KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
const devVarsPath = process.env.AIWORK_DEV_VARS
  ?? `${process.env.HOME}/Projects/cloudflare/aiwork/.dev.vars`;
const GATEWAY_TOKEN = readFileSync(devVarsPath, 'utf8')
  .match(/^AI_GATEWAY_TOKEN\s*=\s*"?([^"\n]+)"?/m)?.[1]?.trim();
if (!ELEVEN_KEY) { console.error('no ELEVEN_KEY'); process.exit(1); }
if (!GATEWAY_TOKEN) { console.error('no AI_GATEWAY_TOKEN'); process.exit(1); }

const STAMP = process.env.PROBE_STAMP ?? new Date().toISOString().slice(0, 10);
const ROOT = process.env.PROBE_OUT
  ?? new URL(`out/${STAMP}-provider-demo/`, import.meta.url).pathname;
const AUDIO = `${ROOT}/audio`;
mkdirSync(AUDIO, { recursive: true });

const GATEWAY = 'https://gateway.ai.cloudflare.com/v1/375e4092bc7903fb8ef13e363a41d370/default';
const MP3_BYTES_PER_SECOND = 16000;
const PCM_RATE = 44100;
const PCM_BYTES_PER_SECOND = PCM_RATE * 2;

const ELEVEN_VOICE = 'WQz3clzUdMqvBf0jswZQ';
const CARTESIA_VOICE = '498e7f37-7fa3-4e2c-b8e2-8b6e9276f956';
const CARTESIA_VOICE_NAME = 'Aiko';

const wav = (pcm) => {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.length, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(PCM_RATE, 24); h.writeUInt32LE(PCM_BYTES_PER_SECOND, 28);
  h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
};

async function elevenlabs(text, { model, locators }) {
  const settings = { stability: 0.65, similarity_boost: 0.75, speed: 1.0 };
  if (model === 'eleven_multilingual_v2') Object.assign(settings, { style: 0.0, use_speaker_boost: true });
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${ELEVEN_VOICE}/stream/with-timestamps`
    + '?output_format=mp3_44100_128', {
      method: 'POST',
      headers: { 'xi-api-key': ELEVEN_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text, model_id: model, language_code: 'ja', voice_settings: settings,
        ...(locators ? { pronunciation_dictionary_locators: locators } : {}),
      }),
    });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const lines = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const audio = Buffer.concat(lines.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const units = [], ends = [];
  for (const c of lines) {
    if (!c.alignment) continue;
    units.push(...c.alignment.characters);
    ends.push(...c.alignment.character_end_times_seconds);
  }
  const audioSec = audio.length / MP3_BYTES_PER_SECOND;
  return { audio, ext: 'mp3', audioSec, alignSec: ends.at(-1) ?? 0, units, joined: units.join('') };
}

const CARTESIA_HEADERS = {
  'cf-aig-authorization': `Bearer ${GATEWAY_TOKEN}`,
  'Cartesia-Version': '2026-03-01', 'Content-Type': 'application/json',
};

async function cartesia(text, { model, dictId }) {
  const res = await fetch(`${GATEWAY}/cartesia/tts/sse`, {
    method: 'POST',
    headers: CARTESIA_HEADERS,
    body: JSON.stringify({
      model_id: model, transcript: text,
      voice: { mode: 'id', id: CARTESIA_VOICE },
      output_format: { container: 'raw', encoding: 'pcm_s16le', sample_rate: PCM_RATE },
      language: 'ja', add_timestamps: true,
      ...(dictId ? { pronunciation_dict_id: dictId } : {}),
    }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const events = (await res.text()).split('\n').filter((l) => l.startsWith('data:'))
    .map((l) => { try { return JSON.parse(l.slice(5)); } catch { return null; } }).filter(Boolean);
  const pcm = Buffer.concat(events.filter((e) => e.data).map((e) => Buffer.from(e.data, 'base64')));
  const units = events.flatMap((e) => e.word_timestamps?.words ?? []);
  const ends = events.flatMap((e) => e.word_timestamps?.end ?? []);
  const audioSec = pcm.length / PCM_BYTES_PER_SECOND;
  return { audio: wav(pcm), ext: 'wav', audioSec, alignSec: ends.at(-1) ?? 0, units, joined: units.join('') };
}

const CONFIGS = [
  { id: 'el-ml2', label: 'ElevenLabs multilingual_v2', provider: 'ElevenLabs', tag: 'PRODUCTION',
    run: (t) => elevenlabs(t, { model: 'eleven_multilingual_v2' }),
    note: 'Ровно то, что слышат пользователи сегодня.' },
  { id: 'el-ml2-lex', label: 'ElevenLabs ml2 + лексикон', provider: 'ElevenLabs', tag: 'PRODUCTION + РУБЬ',
    run: (t, loc) => elevenlabs(t, { model: 'eleven_multilingual_v2', locators: loc }),
    note: 'То же плюс alias-словарь из рубя книги — правило на КАЖДЫЙ компонент имени, как его собирает PronunciationLexicon.' },
  { id: 'ct-s3', label: 'Cartesia sonic-3', provider: 'Cartesia', tag: 'НОВЫЙ ПРОВАЙДЕР',
    run: (t) => cartesia(t, { model: 'sonic-3' }),
    note: `Голос ${CARTESIA_VOICE_NAME}. Посимвольные таймстемпы, склейка сходится с текстом.` },
  { id: 'ct-s3-dict', label: 'Cartesia sonic-3 + словарь', provider: 'Cartesia', tag: 'НОВЫЙ ПРОВАЙДЕР + РУБЬ',
    run: (t, loc, dictId) => cartesia(t, { model: 'sonic-3', dictId }),
    note: `Голос ${CARTESIA_VOICE_NAME}. Те же чтения из рубя, что и у ElevenLabs, но через собственные словари Cartesia (кана как «sounds-like»).` },
  { id: 'ct-s35', label: 'Cartesia sonic-3.5', provider: 'Cartesia', tag: 'НОВЫЙ ПРОВАЙДЕР',
    run: (t) => cartesia(t, { model: 'sonic-3.5' }),
    note: `Голос ${CARTESIA_VOICE_NAME}. Заявлен как крупное улучшение многоязычности.` },
  { id: 'ct-s36', label: 'Cartesia sonic-3.6', provider: 'Cartesia', tag: 'ВЫРАВНИВАНИЕ ЛОМАЕТСЯ',
    run: (t) => cartesia(t, { model: 'sonic-3.6' }),
    note: 'Новейшая. Отдаёт меньше меток, чем символов, склейка не сходится — для синхронной подсветки непригодна.' },
];

const CASES = [
  { id: 'kitauji', surface: '黄前', reading: 'おうまえ', kana: 'おうまえくみこ',
    rules: [['黄前', 'おうまえ'], ['久美子', 'くみこ'], ['北宇治', 'きたうじ']],
    text: '吹奏楽部の練習が始まる前、部長が名簿を読み上げていた。黄前久美子は北宇治高校の一年生で、中学からユーフォニアムを続けている。',
    why: 'IPADic читает 黄前 как きぜん. Теперь имя стоит в абзаце, а не в вакууме — модели есть за что зацепиться.' },
  { id: 'sapphire', surface: '緑輝', reading: 'サファイア', kana: 'さふぁいあ',
    rules: [['緑輝', 'サファイア'], ['久美子', 'くみこ'], ['葉月', 'はづき']],
    text: '低音パートの三人は仲が良かった。緑輝はコントラバスを抱えたまま笑い、久美子と葉月がそれを見ていた。',
    why: 'Имя, а не чтение: вывести サファイア из 緑輝 невозможно ни контекстом, ни словарём токенизатора.' },
  { id: 'yoroizuka', surface: '鎧塚', reading: 'よろいづか', kana: 'よろいづかみぞれ',
    rules: [['鎧塚', 'よろいづか'], ['希美', 'のぞみ']],
    text: 'オーボエの音が止まった。鎧塚みぞれは黙って立っていたが、やがて希美のほうを見た。',
    why: 'Рэндаку: токенизатор даёт よろいつか, глухое. Проверяем ещё и 希美 в том же абзаце.' },
  { id: 'umare', surface: '生れ', reading: 'うまれ', kana: 'とうきょうのうまれ',
    rules: [['生れ', 'うまれ']],
    text: '彼は自分のことをあまり話さなかった。私は東京の生れですが、育ちは京都です、とだけ言った。',
    why: 'Довоенная орфография. multilingual_v2 читает なまれ. Ровно из-за этого когда-то пробовали v3.' },
  { id: 'nihonbashi', surface: '日本橋', reading: 'にほんばし', kana: 'にほんばし',
    rules: [],
    text: '日本橋から三百六十五日、十一月三日まで歩いたという話を、七十五歳の主人が聞かせてくれた。',
    why: 'Чтение кандзи через китайский плюс числительные, счётные слова и даты в одном предложении.' },
];

const PROSE_PATH = new URL('out/2026-08-20-model-voice-audit/probe-text-851chars.txt', import.meta.url).pathname;
let prose = 'ある日の暮方の事である。一人の下人が、羅生門の下で雨やみを待っていた。';
try { prose = readFileSync(PROSE_PATH, 'utf8').slice(0, 300); } catch { /* fallback */ }

const RULES = [...new Map(CASES.flatMap((c) => c.rules ?? [])).entries()];

const cartesiaDict = await fetch(`${GATEWAY}/cartesia/pronunciation-dicts/`, {
  method: 'POST', headers: CARTESIA_HEADERS,
  body: JSON.stringify({
    name: `yomi-provider-demo-${STAMP}`,
    items: RULES.map(([text, pronunciation]) => ({ text, pronunciation })),
  }),
}).then(async (r) => {
  if (!r.ok) throw new Error(`cartesia dict: ${r.status} ${await r.text()}`);
  return r.json();
});
console.log(`cartesia dict ${cartesiaDict.id} (${RULES.length} items)`);

const lexicon = await fetch('https://api.elevenlabs.io/v1/pronunciation-dictionaries/add-from-rules', {
  method: 'POST',
  headers: { 'xi-api-key': ELEVEN_KEY, 'Content-Type': 'application/json' },
  body: JSON.stringify({
    name: `yomi-provider-demo-${STAMP}`,
    description: 'Provider comparison, rules derived from publisher ruby',
    rules: RULES
      .map(([surface, alias]) => ({
        string_to_replace: surface, type: 'alias', alias,
        case_sensitive: true, word_boundaries: false,
      })),
  }),
}).then(async (r) => {
  if (!r.ok) throw new Error(`create dict: ${r.status} ${await r.text()}`);
  return r.json();
});
console.log(`lexicon ${lexicon.id} (${lexicon.version_rules_num} rules)\n`);
const LOCATORS = [{ pronunciation_dictionary_id: lexicon.id, version_id: lexicon.version_id }];

const ALL = [...CASES, {
  id: 'prose', surface: '', reading: '', kana: '',
  text: prose,
  why: 'Связная проза (Рассёмон, 300 знаков, с полноширинными пробелами) — ритм, паузы и устойчивость выравнивания на длине.',
}];

const results = [];
for (const c of ALL) {
  process.stdout.write(`${c.id.padEnd(11)}`);
  const row = { ...c, runs: {} };

  if (c.kana) {
    try {
      const ref = await elevenlabs(c.kana, { model: 'eleven_multilingual_v2' });
      writeFileSync(`${AUDIO}/${c.id}-reference.${ref.ext}`, ref.audio);
      row.reference = { file: `audio/${c.id}-reference.${ref.ext}`, text: c.kana };
      process.stdout.write(' ref✓');
    } catch (error) { row.reference = { error: String(error.message ?? error) }; }
  }

  for (const cfg of CONFIGS) {
    try {
      const r = await cfg.run(c.text, LOCATORS, cartesiaDict.id);
      writeFileSync(`${AUDIO}/${c.id}-${cfg.id}.${r.ext}`, r.audio);
      const bare = (s) => [...s].filter((ch) => ch.trim() !== '').join('');
      row.runs[cfg.id] = {
        file: `audio/${c.id}-${cfg.id}.${r.ext}`,
        audioSec: r.audioSec, alignSec: r.alignSec,
        undescribed: r.audioSec - r.alignSec,
        joinOK: r.joined === c.text,
        joinOKIgnoringBlanks: bare(r.joined) === bare(c.text),
        units: r.units.length,
        expectedUnits: [...c.text].length,
        expectedNonBlank: [...bare(c.text)].length,
        charsPerSecond: r.audioSec > 0 ? [...c.text].length / r.audioSec : 0,
      };
      process.stdout.write(` ${cfg.id}:${r.audioSec.toFixed(1)}s`);
    } catch (error) {
      row.runs[cfg.id] = { error: String(error.message ?? error) };
      process.stdout.write(` ${cfg.id}:FAIL`);
    }
  }
  results.push(row);
  process.stdout.write('\n');
}

writeFileSync(`${ROOT}/cases.json`, JSON.stringify({
  generated: new Date().toISOString(),
  voices: { ElevenLabs: 'Shizuka', Cartesia: CARTESIA_VOICE_NAME },
  configs: CONFIGS.map(({ run, ...rest }) => rest),
  lexicon: { id: lexicon.id, version: lexicon.version_id },
  cartesiaDict: { id: cartesiaDict.id, items: RULES.length },
  results,
}, null, 2));
console.log(`\nlexicon to archive afterwards: ${lexicon.id}`);
console.log(`wrote ${ROOT}`);
