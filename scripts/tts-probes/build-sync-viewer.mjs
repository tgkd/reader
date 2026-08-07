#!/usr/bin/env node
/**
 * Builds a synced-reading view of the v3 defect: the chapter text with furigana, highlighted
 * character by character from the alignment the API actually returned, against the audio it
 * actually returned.
 *
 * The numbers say "the alignment ends 4-7 s before the audio". This shows what that IS: the
 * highlight reaches the end of the text and stops, while the voice keeps talking. That is
 * precisely the bug the app would ship — except the client's guard rejects it first, so the
 * user gets an error instead.
 *
 * Five v3 runs plus one flash control, same chapter, same settings.
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch {}
const KEY = process.env.ELEVEN_KEY;
const ROOT = process.env.PROBE_OUT ?? new URL('out/', import.meta.url).pathname;
const AUDIO = `${ROOT}/v3-sync`;
mkdirSync(AUDIO, { recursive: true });

const TEXT = readFileSync((process.env.PROBE_TEXT ?? ''), 'utf8').normalize('NFKC');
const VOICE = 'WQz3clzUdMqvBf0jswZQ';
const MP3 = 16000;

/// Longest-match-first. Names first so they win over their components.
const RUBY = [
  ['黄前', 'おうまえ'], ['久美子', 'くみこ'], ['加藤', 'かとう'], ['葉月', 'はづき'],
  ['川島', 'かわしま'], ['緑輝', 'サファイア'], ['後藤', 'ごとう'], ['卓也', 'たくや'],
  ['長瀬', 'ながせ'], ['梨子', 'りこ'], ['中川', 'なかがわ'], ['夏紀', 'なつき'],
  ['田中', 'たなか'], ['高坂', 'こうさか'], ['麗奈', 'れいな'], ['吉川', 'よしかわ'],
  ['優子', 'ゆうこ'], ['中世古', 'なかせこ'], ['香織', 'かおり'], ['塚本', 'つかもと'],
  ['秀一', 'しゅういち'], ['鎧塚', 'よろいづか'], ['傘木', 'かさき'], ['希美', 'のぞみ'],
  ['小笠原', 'おがさわら'], ['晴香', 'はるか'], ['松本', 'まつもと'], ['美知恵', 'みちえ'],
  ['橋本', 'はしもと'], ['真博', 'まさひろ'], ['新山', 'にいやま'], ['聡美', 'さとみ'],
  ['北宇治', 'きたうじ'], ['京都府大会', 'きょうとふたいかい'],
  ['登場人物', 'とうじょうじんぶつ'], ['吹奏楽部', 'すいそうがくぶ'], ['中学時代', 'ちゅうがくじだい'],
  ['超強豪', 'ちょうきょうごう'], ['犬猿', 'けんえん'], ['幼馴染', 'おさななじみ'],
  ['小学生', 'しょうがくせい'], ['一年生', 'いちねんせい'], ['二年生', 'にねんせい'],
  ['三年生', 'さんねんせい'], ['中学校', 'ちゅうがっこう'], ['課題曲', 'かだいきょく'],
  ['指導者', 'しどうしゃ'], ['副顧問', 'ふくこもん'], ['変わり者', 'かわりもの'],
  ['低音', 'ていおん'], ['東京', 'とうきょう'], ['京都', 'きょうと'], ['高校', 'こうこう'],
  ['女子校', 'じょしこう'], ['自分', 'じぶん'], ['名前', 'なまえ'], ['結果', 'けっか'],
  ['編成', 'へんせい'], ['出場', 'しゅつじょう'], ['天才', 'てんさい'], ['大好', 'だいす'],
  ['先輩', 'せんぱい'], ['部活', 'ぶかつ'], ['部長', 'ぶちょう'], ['顧問', 'こもん'],
  ['以前', 'いぜん'], ['軍曹', 'ぐんそう'], ['先生', 'せんせい'], ['外部', 'がいぶ'],
  ['専門', 'せんもん'], ['木管', 'もっかん'], ['指導', 'しどう'], ['担当', 'たんとう'],
  ['憧', 'あこが'], ['争', 'あらそ'], ['辞', 'や'], ['嫌', 'きら'], ['緑', 'みどり'],
  ['呼', 'よ'], ['副', 'ふく'], ['務', 'つと'], ['通', 'かよ'], ['入', 'はい'],
  ['同', 'おな'], ['一度', 'いちど'], ['滝', 'たき'], ['昇', 'のぼる'], ['父', 'ちち'],
  ['吹', 'ふ'], ['部', 'ぶ'],
].sort((a, b) => b[0].length - a[0].length);

/// Every character gets an indexed span; ruby bases wrap their spans in <ruby>.
function renderText(text) {
  const chars = [...text];
  const out = [];
  let i = 0;
  const span = (k) => {
    const c = chars[k];
    if (c === '\n') return '';
    return `<span class="c" data-i="${k}">${c === ' ' ? '&nbsp;' : c}</span>`;
  };
  while (i < chars.length) {
    if (chars[i] === '\n') {
      let n = 0;
      while (chars[i + n] === '\n') n++;
      out.push(n > 1 ? '<div class="br"></div>' : '<br>');
      i += n;
      continue;
    }
    const hit = RUBY.find(([base]) => chars.slice(i, i + [...base].length).join('') === base);
    if (hit) {
      const len = [...hit[0]].length;
      const inner = Array.from({ length: len }, (_, k) => span(i + k)).join('');
      out.push(`<ruby>${inner}<rt>${hit[1]}</rt></ruby>`);
      i += len;
      continue;
    }
    out.push(span(i));
    i++;
  }
  return out.join('');
}

async function generate(model, tag) {
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/stream/with-timestamps?output_format=mp3_44100_128`, {
      method: 'POST', headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text: TEXT, model_id: model, language_code: 'ja',
        voice_settings: { stability: 0.65, similarity_boost: 0.75, style: 0.0,
                          use_speaker_boost: true, speed: 1.0 },
      }),
    });
  if (!res.ok) throw new Error(`${tag}: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
  const chunks = (await res.text()).split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const audio = Buffer.concat(chunks.map((c) => Buffer.from(c.audio_base64 ?? '', 'base64')));
  const ch = [], st = [], et = [];
  for (const c of chunks) {
    if (!c.alignment) continue;
    ch.push(...c.alignment.characters);
    st.push(...c.alignment.character_start_times_seconds);
    et.push(...c.alignment.character_end_times_seconds);
  }
  writeFileSync(`${AUDIO}/${tag}.mp3`, audio);
  const audioSec = audio.length / MP3, alignSec = et.at(-1) ?? 0;
  console.log(`  ${tag.padEnd(12)} audio ${audioSec.toFixed(2)}s  align ${alignSec.toFixed(2)}s`
    + `  undescribed ${(audioSec - alignSec).toFixed(2)}s`
    + `  ${audioSec - alignSec > 1.0 ? 'REJECTED' : 'passes'}`);
  return { tag, model, audioSec, alignSec, undescribed: audioSec - alignSec,
           joinOK: ch.join('') === TEXT, start: st.map(n => +n.toFixed(3)), end: et.map(n => +n.toFixed(3)) };
}

console.log(`text ${[...TEXT].length} chars\ngenerating 5x eleven_v3 + 1x flash control...\n`);
const runs = [];
for (let i = 1; i <= 5; i++) runs.push(await generate('eleven_v3', `v3-run${i}`));
runs.push(await generate('eleven_flash_v2_5', 'flash-control'));

const rejected = runs.filter((r) => r.model === 'eleven_v3' && r.undescribed > 1.0).length;
console.log(`\n${rejected}/5 v3 runs would be rejected by the 1.0 s guard`);

const DATA = runs.map(({ tag, model, audioSec, alignSec, undescribed, joinOK, start, end }) =>
  ({ tag, model, audioSec: +audioSec.toFixed(2), alignSec: +alignSec.toFixed(2),
     undescribed: +undescribed.toFixed(2), joinOK, start, end }));

const html = `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>v3 alignment — synced reading</title>
<style>
  :root { --bg:#fbfaf8; --panel:#fff; --ink:#1c1a17; --muted:#6b655d; --line:#e2ddd5;
          --accent:#7a5c3e; --hit:#f2e2c8; --bad:#c0392b; --ok:#3f6b46;
          --mono: ui-monospace, SFMono-Regular, Menlo, monospace; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#171614; --panel:#211f1c; --ink:#ece7df; --muted:#9a938a; --line:#35322d;
            --accent:#c9a37a; --hit:#4a3a22; --bad:#e07a6a; --ok:#8fc09a; }
  }
  * { box-sizing:border-box; }
  body { margin:0; padding:2rem 1.25rem 4rem; background:var(--bg); color:var(--ink);
         font:16px/1.6 -apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif; }
  main { max-width:52rem; margin:0 auto; }
  h1 { font-size:1.4rem; margin:0 0 .3rem; }
  p.sub { color:var(--muted); margin:0 0 1.5rem; }
  code { font-family:var(--mono); font-size:.875em; }
  .runs { display:flex; flex-wrap:wrap; gap:.4rem; margin-bottom:1rem; }
  .runs button { font:inherit; font-size:.85rem; padding:.45rem .8rem; border-radius:7px;
                 border:1px solid var(--line); background:var(--panel); color:var(--ink); cursor:pointer; }
  .runs button.sel { border-color:var(--accent); color:var(--accent); font-weight:600; }
  .runs button .u { font-family:var(--mono); font-size:.8em; color:var(--muted); }
  .runs button.sel .u { color:var(--accent); }
  .player { background:var(--panel); border:1px solid var(--line); border-radius:10px;
            padding:.9rem 1rem; margin-bottom:1rem; position:sticky; top:.5rem; z-index:5; }
  audio { width:100%; height:36px; }
  .clocks { display:flex; gap:1.25rem; flex-wrap:wrap; font-family:var(--mono); font-size:.8rem;
            color:var(--muted); margin-top:.5rem; }
  .clocks b { color:var(--ink); font-weight:600; }
  .warn { color:var(--bad); font-weight:600; }
  .good { color:var(--ok); font-weight:600; }
  .text { background:var(--panel); border:1px solid var(--line); border-radius:10px;
          padding:1.5rem 1.25rem; font-size:1.15rem; line-height:2.4; }
  .c { transition:background-color .08s linear; border-radius:2px; }
  .c.done { color:var(--muted); }
  .c.now  { background:var(--hit); color:var(--ink); font-weight:600; }
  rt { font-size:.5em; color:var(--muted); font-weight:400; }
  .br { height:1.1rem; }
  .note { color:var(--muted); font-size:.9rem; }
  .exhausted { display:none; margin-top:1rem; padding:.7rem .9rem; border-radius:8px;
               border:1px solid var(--bad); color:var(--bad); font-size:.9rem; }
  .exhausted.on { display:block; }
</style>
</head>
<body>
<main>
<h1>The alignment, played against its own audio</h1>
<p class="sub">
  Chapter 5 character list, 851 characters, voice Shizuka, production settings. The highlight is
  driven by the character timings the API returned, over the audio the same request returned.
  Watch what happens at the end of a rejected run: the text finishes and the voice keeps going.
</p>

<div class="runs" id="runs"></div>

<div class="player">
  <audio id="a" controls preload="none"></audio>
  <div class="clocks">
    <span>audio <b id="t">0.00</b>s / <b id="dur">–</b>s</span>
    <span>alignment ends <b id="ae">–</b>s</span>
    <span>undescribed <b id="un">–</b>s</span>
    <span id="state"></span>
  </div>
  <div class="exhausted" id="ex">
    Alignment exhausted — the voice is still speaking, but no character has a timing for this
    audio. In the app the highlight would sit frozen on the last word for the rest of the chapter.
  </div>
</div>

<div class="text" id="text">${renderText(TEXT)}</div>

<p class="note" style="margin-top:1.5rem">
  Furigana is the correct reading, so it doubles as a pronunciation check — the names are the ones
  no model gets right unaided: <ruby>黄前<rt>おうまえ</rt></ruby>, <ruby>鎧塚<rt>よろいづか</rt></ruby>,
  <ruby>秀一<rt>しゅういち</rt></ruby>, <ruby>緑輝<rt>サファイア</rt></ruby>,
  <ruby>希美<rt>のぞみ</rt></ruby>.
</p>
</main>

<script>
const RUNS = ${JSON.stringify(DATA)};
const spans = [...document.querySelectorAll('.c')];
const byIndex = new Map(spans.map(s => [+s.dataset.i, s]));
const a = document.getElementById('a');
const runsEl = document.getElementById('runs');
let cur = RUNS[0], last = -1;

RUNS.forEach((r, i) => {
  const b = document.createElement('button');
  const bad = r.undescribed > 1.0;
  b.innerHTML = r.tag.replace('v3-run', 'v3 · run ').replace('flash-control', 'flash · control')
    + ' <span class="u">' + (bad ? '✕ ' : '✓ ') + r.undescribed.toFixed(2) + 's</span>';
  b.onclick = () => select(i);
  runsEl.appendChild(b);
});

function select(i) {
  cur = RUNS[i];
  [...runsEl.children].forEach((b, k) => b.classList.toggle('sel', k === i));
  a.src = 'v3-sync/' + cur.tag + '.mp3';
  document.getElementById('ae').textContent = cur.alignSec.toFixed(2);
  document.getElementById('un').textContent = cur.undescribed.toFixed(2);
  document.getElementById('dur').textContent = cur.audioSec.toFixed(2);
  const st = document.getElementById('state');
  st.className = cur.undescribed > 1.0 ? 'warn' : 'good';
  st.textContent = cur.undescribed > 1.0 ? 'rejected by the 1.0s guard' : 'passes the guard';
  reset();
}
function reset() {
  spans.forEach(s => s.classList.remove('done', 'now'));
  last = -1;
  document.getElementById('ex').classList.remove('on');
}
/// Rightmost start <= t, clamped to the last timed character — the same rule SpanTimeline uses.
function indexAt(t) {
  const s = cur.start;
  let lo = 0, hi = s.length - 1, ans = -1;
  while (lo <= hi) { const m = (lo + hi) >> 1; if (s[m] <= t) { ans = m; lo = m + 1; } else hi = m - 1; }
  return ans;
}
a.addEventListener('timeupdate', () => {
  const t = a.currentTime;
  document.getElementById('t').textContent = t.toFixed(2);
  const i = indexAt(t);
  if (i !== last) {
    if (last >= 0) byIndex.get(last)?.classList.remove('now');
    for (let k = Math.max(0, last); k <= i; k++) byIndex.get(k)?.classList.add('done');
    byIndex.get(i)?.classList.add('now');
    byIndex.get(i)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    last = i;
  }
  document.getElementById('ex').classList.toggle('on', t > cur.alignSec + 0.15);
});
a.addEventListener('seeked', reset);
select(0);
</script>
</body>
</html>`;

writeFileSync(`${ROOT}/v3-sync.html`, html);
console.log(`\nwrote ${ROOT}/v3-sync.html`);
