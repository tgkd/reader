#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';

const RENDER_ONLY = !!process.env.PROBE_RENDER_ONLY;

try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY && !RENDER_ONLY) { console.error('no ELEVEN_KEY in .env'); process.exit(1); }

const STAMP = process.env.PROBE_STAMP ?? new Date().toISOString().slice(0, 10);
const ROOT = process.env.PROBE_OUT
  ?? new URL(`out/${STAMP}-v3-conversational/`, import.meta.url).pathname;
mkdirSync(ROOT, { recursive: true });

const TEXT = readFileSync(process.env.PROBE_TEXT ?? `${ROOT}/excerpt.txt`, 'utf8')
  .normalize('NFKC')
  .trim();

const VOICE = process.env.PROBE_VOICE ?? 'deKmbWEKZdwxcKxxcfvP';
const FORMAT = 'mp3_44100_128';
const MP3_BYTES_PER_SECOND = 16000;

const BASE_SETTINGS = { stability: 0.65, similarity_boost: 0.75, speed: 1.0 };
const SETTING_SUPPORT = {
  eleven_v3: { style: false, speakerBoost: false },
  eleven_v3_conversational: { style: false, speakerBoost: true },
};

const ARMS = [
  { id: 'v3', model: 'eleven_v3', label: 'eleven_v3', price: '$0.10 / 1K · текущая модель' },
  {
    id: 'cv',
    model: 'eleven_v3_conversational',
    label: 'eleven_v3_conversational',
    price: '$0.05 / 1K · вдвое дешевле',
  },
];

function settingsFor(model) {
  const caps = SETTING_SUPPORT[model] ?? { style: true, speakerBoost: true };
  return {
    ...BASE_SETTINGS,
    ...(caps.style ? { style: 0.0 } : {}),
    ...(caps.speakerBoost ? { use_speaker_boost: true } : {}),
  };
}

async function synth(arm) {
  const url = `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/with-timestamps?output_format=${FORMAT}`;
  const t0 = Date.now();
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      text: TEXT,
      model_id: arm.model,
      language_code: 'ja',
      voice_settings: settingsFor(arm.model),
    }),
  });
  const wall = (Date.now() - t0) / 1000;
  if (!res.ok) throw new Error(`${arm.id} HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);

  const data = await res.json();
  if (!data.alignment) throw new Error(`${arm.id} answered without an alignment block`);

  const audio = Buffer.from(data.audio_base64, 'base64');
  writeFileSync(`${ROOT}/${arm.id}.mp3`, audio);
  writeFileSync(
    `${ROOT}/${arm.id}.json`,
    JSON.stringify({ text: TEXT, model: arm.model, voice: VOICE, alignment: data.alignment }, null, 2)
  );

  const starts = data.alignment.character_start_times_seconds;
  const ends = data.alignment.character_end_times_seconds;
  const alignedEnd = ends[ends.length - 1];
  const audioSeconds = audio.length / MP3_BYTES_PER_SECOND;
  return {
    ...arm,
    starts,
    alignedEnd,
    audioSeconds,
    tail: audioSeconds - alignedEnd,
    rate: TEXT.length / alignedEnd,
    wall,
    describedChars: data.alignment.characters.length,
  };
}

const esc = (s) => String(s).replace(/[&<>"]/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function page(runs) {
  const spans = [...TEXT].map((ch, i) => `<span data-i="${i}">${esc(ch)}</span>`).join('');
  const align = JSON.stringify(
    Object.fromEntries(runs.map((r) => [r.id, { s: r.starts.map((x) => Math.round(x * 1000) / 1000) }]))
  );
  const cards = runs.map((r) => `
    <div class="card" id="card-${r.id}">
      <h2>${esc(r.label)}</h2>
      <p class="price">${esc(r.price)}</p>
      <audio id="${r.id}" controls preload="metadata" src="${r.id}.mp3"></audio>
      <dl>
        <dt>длительность</dt><dd>${r.audioSeconds.toFixed(2)} с</dd>
        <dt>хвост без разметки</dt><dd>${r.tail.toFixed(3)} с</dd>
        <dt>скорость речи</dt><dd>${r.rate.toFixed(2)} зн/с</dd>
        <dt>генерация</dt><dd>${r.wall.toFixed(1)} с</dd>
      </dl>
    </div>`).join('');

  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>v3 vs v3 Conversational</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f4f1e9; --surface: #fbf8f1; --ink: #36312a; --muted: #a59c8d;
    --hair: rgba(54,49,42,.14); --accent: #44617b; --hi: rgba(68,97,123,.16);
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #161613; --surface: #1f1e1a; --ink: #dcd6c8; --muted: #736d60;
            --hair: rgba(220,214,200,.14); --accent: #c9a961; --hi: rgba(201,169,97,.22); }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--ink);
         font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
  main { max-width: 780px; margin: 0 auto; padding: 32px 20px 80px; }
  h1 { font-size: 19px; font-weight: 600; margin: 0 0 4px; }
  .sub { color: var(--muted); font-size: 13px; margin: 0 0 24px; }
  .players { display: grid; gap: 12px; grid-template-columns: 1fr 1fr; margin-bottom: 20px; }
  @media (max-width: 640px) { .players { grid-template-columns: 1fr; } }
  .card { background: var(--surface); border: 1px solid var(--hair);
          border-radius: 14px; padding: 14px 14px 12px; }
  .card.live { border-color: var(--accent); }
  .card h2 { font-size: 14px; font-weight: 600; margin: 0 0 2px; }
  .price { color: var(--accent); font-size: 12px; font-weight: 600; margin: 0 0 10px; }
  audio { width: 100%; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 2px 10px; margin: 12px 0 0; font-size: 12px; }
  dt { color: var(--muted); }
  dd { margin: 0; font-variant-numeric: tabular-nums; }
  .bar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap;
         margin-bottom: 22px; font-size: 12.5px; color: var(--muted); }
  button { font: inherit; color: var(--ink); background: var(--surface);
           border: 1px solid var(--hair); border-radius: 999px; padding: 6px 14px; cursor: pointer; }
  button:hover { border-color: var(--accent); }
  button.on { background: var(--accent); color: var(--surface); border-color: var(--accent); }
  article { background: var(--surface); border: 1px solid var(--hair); border-radius: 14px;
            padding: 22px 26px; font-family: "Hiragino Mincho ProN", "Yu Mincho", serif;
            font-size: 17px; line-height: 2.05; white-space: pre-wrap; }
  article span { cursor: pointer; border-radius: 3px; }
  article span.read { color: var(--muted); }
  article span.now { background: var(--hi); color: var(--ink); box-shadow: 0 0 0 2px var(--hi); }
</style>
</head>
<body>
<main>
  <h1>eleven_v3 &nbsp;vs&nbsp; eleven_v3_conversational</h1>
  <p class="sub">${TEXT.length} знаков · голос ${esc(VOICE)} · подсветка идёт из alignment каждой модели</p>
  <div class="players">${cards}</div>
  <div class="bar">
    <button id="swap">Переключить на ту же позицию</button>
    <button id="follow" class="on">Следить за текстом</button>
    <span>клавиши 1 / 2 — переключить, пробел — пауза, клик по знаку — перемотка</span>
  </div>
  <article id="text">${spans}</article>
</main>
<script>
const ALIGN = ${align};
const IDS = ${JSON.stringify(runs.map((r) => r.id))};
const el = {}, card = {};
for (const id of IDS) { el[id] = document.getElementById(id); card[id] = document.getElementById('card-' + id); }
const spans = Array.from(document.getElementById('text').children);
const followBtn = document.getElementById('follow');
let active = IDS[0], last = -1, raf = 0, follow = true;

const starts = () => ALIGN[active].s;

function indexAt(t) {
  const s = starts();
  let lo = 0, hi = s.length - 1, ans = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (s[mid] <= t) { ans = mid; lo = mid + 1; } else { hi = mid - 1; }
  }
  return ans;
}

function paint(i) {
  if (i === last) return;
  if (i > last) { for (let k = Math.max(0, last); k <= i; k++) spans[k].classList.add('read'); }
  else { for (let k = i + 1; k <= last && k < spans.length; k++) spans[k].classList.remove('read'); }
  if (last >= 0 && spans[last]) spans[last].classList.remove('now');
  if (i >= 0 && spans[i]) {
    spans[i].classList.add('now');
    if (follow) {
      const r = spans[i].getBoundingClientRect();
      if (r.top < 90 || r.bottom > innerHeight - 60) spans[i].scrollIntoView({ block: 'center', behavior: 'smooth' });
    }
  }
  last = i;
}

function tick() { paint(indexAt(el[active].currentTime)); raf = requestAnimationFrame(tick); }

function setActive(id) {
  if (active === id) return;
  active = id;
  for (const other of IDS) card[other].classList.toggle('live', other === id);
  last = -1;
  spans.forEach((s) => s.classList.remove('read', 'now'));
  paint(indexAt(el[id].currentTime));
}

function to(target) {
  const source = el[active], t = source.currentTime, playing = !source.paused;
  source.pause();
  el[target].currentTime = Math.min(t, el[target].duration || t);
  setActive(target);
  if (playing) el[target].play();
}

for (const id of IDS) {
  el[id].addEventListener('play', () => {
    for (const other of IDS) if (other !== id) el[other].pause();
    setActive(id);
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(tick);
  });
  el[id].addEventListener('pause', () => cancelAnimationFrame(raf));
  el[id].addEventListener('seeked', () => { if (active === id) paint(indexAt(el[id].currentTime)); });
}

document.getElementById('swap').onclick = () => to(IDS.find((id) => id !== active));
followBtn.onclick = () => { follow = !follow; followBtn.classList.toggle('on', follow); };

document.getElementById('text').addEventListener('click', (e) => {
  const i = e.target.dataset && e.target.dataset.i;
  if (i === undefined) return;
  el[active].currentTime = starts()[+i];
  paint(+i);
});

document.addEventListener('keydown', (e) => {
  if (e.key === '1') to(IDS[0]);
  if (e.key === '2') to(IDS[1]);
  if (e.code === 'Space') { e.preventDefault(); el[active].paused ? el[active].play() : el[active].pause(); }
});

card[IDS[0]].classList.add('live');
</script>
</body>
</html>
`;
}

function reread(arm) {
  const saved = JSON.parse(readFileSync(`${ROOT}/${arm.id}.json`, 'utf8'));
  const ends = saved.alignment.character_end_times_seconds;
  const alignedEnd = ends[ends.length - 1];
  const audioSeconds = statSync(`${ROOT}/${arm.id}.mp3`).size / MP3_BYTES_PER_SECOND;
  return {
    ...arm,
    starts: saved.alignment.character_start_times_seconds,
    alignedEnd,
    audioSeconds,
    tail: audioSeconds - alignedEnd,
    rate: saved.text.length / alignedEnd,
    wall: stats[arm.id] ?? 0,
    describedChars: saved.alignment.characters.length,
  };
}

let stats = {};
try { stats = JSON.parse(readFileSync(`${ROOT}/stats.json`, 'utf8')); } catch { /* no saved timings */ }

const runs = [];
for (const arm of ARMS) {
  const r = RENDER_ONLY ? reread(arm) : await synth(arm);
  runs.push(r);
  console.log(
    [arm.id, `model=${r.model}`, `chars=${TEXT.length}`, `described=${r.describedChars}`,
      `aligned_end=${r.alignedEnd.toFixed(3)}s`, `audio=${r.audioSeconds.toFixed(3)}s`,
      `tail=${r.tail.toFixed(3)}s`, `rate=${r.rate.toFixed(2)}ch/s`, `wall=${r.wall.toFixed(1)}s`].join('\t')
  );
}

if (!RENDER_ONLY) {
  writeFileSync(`${ROOT}/excerpt.txt`, TEXT);
  writeFileSync(`${ROOT}/stats.json`,
    JSON.stringify(Object.fromEntries(runs.map((r) => [r.id, Number(r.wall.toFixed(1))])), null, 2));
}
writeFileSync(`${ROOT}/index.html`, page(runs));
console.log(`\n${ROOT}/index.html`);
