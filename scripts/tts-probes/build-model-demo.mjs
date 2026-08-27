#!/usr/bin/env node
import { writeFileSync, mkdirSync, readFileSync } from 'node:fs';

try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY in .env'); process.exit(1); }

const STAMP = process.env.PROBE_STAMP ?? new Date().toISOString().slice(0, 10);
const ROOT = process.env.PROBE_OUT ?? new URL(`out/${STAMP}-model-demo/`, import.meta.url).pathname;
const AUDIO = `${ROOT}/audio`;
mkdirSync(AUDIO, { recursive: true });

const VOICE = { id: 'WQz3clzUdMqvBf0jswZQ', name: 'Shizuka' };
const MP3_BYTES_PER_SECOND = 16000;

const BASE_SETTINGS = {
  stability: 0.65, similarity_boost: 0.75, style: 0.0, use_speaker_boost: true, speed: 1.0,
};
const SETTING_SUPPORT = {
  eleven_multilingual_v2: { style: true, speakerBoost: true },
  eleven_v3_conversational: { style: false, speakerBoost: true },
  eleven_flash_v2_5: { style: false, speakerBoost: false },
  eleven_v3: { style: false, speakerBoost: false },
};
const settingsFor = (model) => {
  const caps = SETTING_SUPPORT[model] ?? { style: true, speakerBoost: true };
  const { style, use_speaker_boost, ...rest } = BASE_SETTINGS;
  return { ...rest, ...(caps.style ? { style } : {}), ...(caps.speakerBoost ? { use_speaker_boost } : {}) };
};

const CONFIGS = [
  { id: 'ml2', label: 'multilingual_v2', model: 'eleven_multilingual_v2', dict: false,
    tag: 'PRODUCTION', cost: '1.0x', note: 'Что слышат пользователи сегодня. Все пять voice_settings принимаются.' },
  { id: 'ml2-lex', label: 'multilingual_v2 + лексикон', model: 'eleven_multilingual_v2', dict: true,
    tag: 'PRODUCTION + рубь', cost: '1.0x', note: 'То же плюс alias-словарь из рубя книги (word_boundaries: false).' },
  { id: 'v3c', label: 'v3_conversational', model: 'eleven_v3_conversational', dict: false,
    tag: 'НЕ ПРОСЛУШАН', cost: '0.5x', note: 'Вдвое дешевле production, японский поддерживает, диалоговая настройка. Ни разу не аудировался.' },
  { id: 'v3', label: 'eleven_v3', model: 'eleven_v3', dict: false,
    tag: 'РИСК ВЫРАВНИВАНИЯ', cost: '1.0x', note: 'Лучшее контекстное чтение, но остаточный дефект таймингов ниже порога гарда — и он кэшируется навсегда.' },
  { id: 'flash', label: 'flash_v2_5', model: 'eleven_flash_v2_5', dict: false,
    tag: 'СТАРЫЙ ДЕФОЛТ', cost: '0.5x', note: 'Так звучит уже закэшированное аудио у части пользователей. Молча отбрасывает style и speaker_boost.' },
];

const CASES = [
  { id: 'kitauji', surface: '黄前', reading: 'おうまえ', text: '黄前久美子は北宇治高校の一年生です。',
    why: 'IPADic читает 黄前 как きぜん. Рубь издателя говорит おうまえ.',
    listen: 'В начале: «о-у-ма-э» или ошибочное «ки-дзэн».' },
  { id: 'nozomi', surface: '希美', reading: 'のぞみ', text: '希美は去年のことを話しませんでした。',
    why: 'IPADic читает 希美 как きみ.', listen: 'Первое слово: «но-дзо-ми» или «ки-ми».' },
  { id: 'sapphire', surface: '緑輝', reading: 'サファイア', text: '緑輝はコントラバスを弾いています。',
    why: 'Это имя, а не чтение — ни один токенизатор не выведет サファイア из 緑輝.',
    listen: 'Ожидается «са-фа-и-а». Любая модель без словаря почти наверняка скажет «рёкки».' },
  { id: 'yoroizuka', surface: '鎧塚', reading: 'よろいづか', text: '鎧塚みぞれは黙って立っていました。',
    why: 'Токенизатор теряет рэндаку (よろいつか).', listen: 'Звонкое «дзу» против глухого «цу» в конце фамилии.' },
  { id: 'umare', surface: '生れ', reading: 'うまれ', text: '私は東京の生れです。',
    why: 'Довоенная орфография. multilingual_v2 говорит なまれ. Ровно из-за этого когда-то пробовали v3.',
    listen: 'Конец фразы: «у-ма-рэ» или «на-ма-рэ».' },
  { id: 'shuichi', surface: '秀一', reading: 'しゅういち', text: '秀一は幼なじみでした。',
    why: 'MeCab оставляет 秀一 целым и читает ひでかず.', listen: '«сю-и-чи» против «хи-дэ-кадзу».' },
  { id: 'myojo', surface: '明静工科', reading: 'みょうじょうこうか', text: '明静工科高校が全国大会に出ます。',
    why: 'Название школы, восстановленное из уплощённого рубя.', listen: 'Четыре кандзи подряд — типичное место развала.' },
  { id: 'nihonbashi', surface: '日本橋', reading: 'にほんばし', text: '日本橋から三百六十五日、十一月三日まで歩いた。',
    why: 'Тест на прочтение кандзи через китайский плюс числительные, счётные слова и дата.',
    listen: '«ни-хон-ба-си», а не «ри-бэн-цяо»; и как читаются 三百六十五 и 十一月三日.' },
];

const PROSE_SOURCE = new URL('out/2026-08-20-model-voice-audit/probe-text-851chars.txt', import.meta.url).pathname;
let prose = '';
try {
  prose = readFileSync(PROSE_SOURCE, 'utf8').slice(0, 200);
} catch {
  prose = 'ある日の暮方の事である。一人の下人が、羅生門の下で雨やみを待っていた。';
}

const api = (path, init) => fetch(`https://api.elevenlabs.io/v1${path}`, {
  ...init,
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
});

async function synth(text, model, locators) {
  const res = await api(
    `/text-to-speech/${VOICE.id}/stream/with-timestamps?output_format=mp3_44100_128`, {
      method: 'POST',
      body: JSON.stringify({
        text,
        model_id: model,
        language_code: 'ja',
        voice_settings: settingsFor(model),
        ...(locators ? { pronunciation_dictionary_locators: locators } : {}),
      }),
    });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const lines = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const audio = Buffer.concat(lines.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const chars = [], starts = [], ends = [];
  for (const c of lines) {
    if (!c.alignment) continue;
    chars.push(...c.alignment.characters);
    starts.push(...c.alignment.character_start_times_seconds);
    ends.push(...c.alignment.character_end_times_seconds);
  }
  let longestBlank = 0, blankAt = 0;
  for (let i = 0; i < chars.length; i += 1) {
    const held = ends[i] - starts[i];
    if (chars[i].trim() === '' && held > longestBlank) { longestBlank = held; blankAt = starts[i]; }
  }
  const audioSec = audio.length / MP3_BYTES_PER_SECOND;
  const alignSec = ends.at(-1) ?? 0;
  return {
    audio,
    audioSec,
    alignSec,
    undescribed: audioSec - alignSec,
    joinOK: chars.join('') === text,
    longestBlank,
    blankAt,
    charsPerSecond: audioSec > 0 ? [...text].length / audioSec : 0,
  };
}

const lexicon = await api('/pronunciation-dictionaries/add-from-rules', {
  method: 'POST',
  body: JSON.stringify({
    name: `yomi-model-demo-${STAMP}`,
    description: 'Model comparison demo, derived from publisher ruby',
    rules: CASES.filter((c) => c.reading !== 'にほんばし').map((c) => ({
      string_to_replace: c.surface, type: 'alias', alias: c.reading,
      case_sensitive: true, word_boundaries: false,
    })),
  }),
}).then(async (r) => {
  if (!r.ok) throw new Error(`create dict: ${r.status} ${await r.text()}`);
  return r.json();
});
console.log(`lexicon ${lexicon.id} v${lexicon.version_id} (${lexicon.version_rules_num} rules)\n`);
const LOCATORS = [{ pronunciation_dictionary_id: lexicon.id, version_id: lexicon.version_id }];

const ALL = [...CASES, {
  id: 'prose', surface: '', reading: '', text: prose,
  why: 'Связная проза (Рассёмон, 200 знаков) — на коротких фразах не слышно ни ритма, ни пауз.',
  listen: 'Естественность каденции, паузы на 、и 。, ровность на длинной дистанции.',
}];

const results = [];
for (const c of ALL) {
  process.stdout.write(`${c.id.padEnd(12)}`);
  const row = { ...c, runs: {} };
  for (const cfg of CONFIGS) {
    try {
      const r = await synth(c.text, cfg.model, cfg.dict ? LOCATORS : null);
      writeFileSync(`${AUDIO}/${c.id}-${cfg.id}.mp3`, r.audio);
      row.runs[cfg.id] = {
        audioSec: r.audioSec, alignSec: r.alignSec, undescribed: r.undescribed,
        joinOK: r.joinOK, longestBlank: r.longestBlank, blankAt: r.blankAt,
        charsPerSecond: r.charsPerSecond, file: `audio/${c.id}-${cfg.id}.mp3`,
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
  generated: new Date().toISOString(), voice: VOICE, configs: CONFIGS,
  lexicon: { id: lexicon.id, version: lexicon.version_id }, results,
}, null, 2));
console.log(`\nlexicon to archive afterwards: ${lexicon.id}`);
console.log(`wrote ${results.length * CONFIGS.length} mp3s + cases.json to ${ROOT}`);
