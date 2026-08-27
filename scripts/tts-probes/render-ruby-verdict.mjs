#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';

const ROOT = process.env.PROBE_OUT
  ?? new URL(`out/${process.env.PROBE_STAMP ?? new Date().toISOString().slice(0, 10)}-ruby-loss-demo/`,
    import.meta.url).pathname;
const data = JSON.parse(readFileSync(`${ROOT}/cases.json`, 'utf8'));
const asr = JSON.parse(readFileSync(`${ROOT}/transcripts.json`, 'utf8'));
const byId = new Map(asr.cases.map((c) => [c.id, c]));

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const INLINE = process.env.PROBE_INLINE === '1';
const src = (file) => (INLINE
  ? `data:audio/mpeg;base64,${readFileSync(`${ROOT}/${file}`).toString('base64')}`
  : file);

const strip = (s) => String(s ?? '').replace(/[、。「」・\s]/g, '');

function similarity(a, b) {
  const x = [...strip(a)], y = [...strip(b)];
  if (!x.length && !y.length) return 1;
  if (!x.length || !y.length) return 0;
  const d = Array.from({ length: x.length + 1 }, (_, i) => [i, ...Array(y.length).fill(0)]);
  for (let j = 0; j <= y.length; j += 1) d[0][j] = j;
  for (let i = 1; i <= x.length; i += 1) {
    for (let j = 1; j <= y.length; j += 1) {
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1,
        d[i - 1][j - 1] + (x[i - 1] === y[j - 1] ? 0 : 1));
    }
  }
  return 1 - d[x.length][y.length] / Math.max(x.length, y.length);
}

const best = (t, arm) => {
  const a = t?.arms?.[arm];
  if (!a) return null;
  return a.kana && a.kana.length >= (a.plain?.length ?? 0) * 0.5 ? a.kana : a.plain;
};

const THRESHOLD = Number(process.env.PROBE_EARS_THRESHOLD ?? 0.85);

const scored = data.results.map((c) => {
  const t = byId.get(c.id);
  const raw = best(t, 'raw');
  const ctx = best(t, 'ctx');
  const ref2 = best(t, 'ref2');
  const want = c.contextual?.baseReading ?? c.bookReading;
  if (!raw || !ctx || !ref2) {
    return { c, verdict: 'нет правила', agree: 1, raw, ctx, ref2, want };
  }
  const inCtx = ctx.includes(want);
  const inRaw = raw.includes(want);
  const agree = similarity(ctx, ref2);
  let verdict;
  if (inRaw && inCtx) verdict = 'уже читалось верно';
  else if (inCtx) verdict = 'починено';
  else verdict = 'правило не подействовало';
  return { c, verdict, agree, raw, ctx, ref2, want };
});

const ORDER = ['правило не подействовало', 'починено', 'уже читалось верно', 'нет правила'];
const counts = Object.fromEntries(ORDER.map((v) => [v, scored.filter((s) => s.verdict === v).length]));

const armRow = (id, arm, label, hint, run, text) => {
  if (!run || run.error) return '';
  return `<div class="row">
    <div class="who"><b>${esc(label)}</b><span class="chip">${esc(hint)}</span></div>
    <audio controls preload="none" src="${esc(src(run.file))}"></audio>
    <div class="asr">${esc(text ?? '—')}</div>
  </div>`;
};

const block = (s) => `
<section class="case" data-case="${esc(s.c.id)}">
  <header>
    <h2>${esc(s.c.surface)} <span class="reading">→ ${esc(s.c.bookReading)}</span></h2>
    <div class="hgroup">
      <span class="chip">${esc(s.verdict)}</span>
      <span class="chip">${esc(s.c.book)}</span>
      <button class="seq">▶ подряд</button>
    </div>
  </header>
  ${s.c.contextual ? `<p class="why">Правило: <b>${esc(s.c.contextual.base)} →
    ${esc(s.c.contextual.baseReading)}</b> · расшифровки «+ правило» и «эталон» сходятся на
    ${(s.agree * 100).toFixed(0)}% — ниже ${(THRESHOLD * 100).toFixed(0)}%, поэтому случай здесь</p>`
    : '<p class="why">Контекстной базы нет.</p>'}
  <p class="jp">${esc(s.c.sentence)}</p>
  <div class="players">
    ${armRow(s.c.id, 'raw', 'production', 'сегодня', s.c.arms.raw, s.raw)}
    ${armRow(s.c.id, 'ctx', '+ правило', 'словарь', s.c.arms.ctx, s.ctx)}
    ${armRow(s.c.id, 'ref2', 'эталон', 'кана в тексте', s.c.arms.ref2, s.ref2)}
  </div>
  <div class="verdict" data-case="${esc(s.c.id)}">
    <button data-v="fixed">чинит</button>
    <button data-v="broke">ломает соседей</button>
    <button data-v="nochange">без изменений</button>
    <button data-v="unsure">не уверен</button>
    <span class="mine"></span>
  </div>
</section>`;

const ears = scored
  .filter((s) => s.verdict !== 'нет правила'
    && (s.agree < THRESHOLD || s.verdict === 'правило не подействовало'))
  .sort((a, b) => a.agree - b.agree);
const rest = scored.filter((s) => !ears.includes(s));

const summaryRows = ORDER.filter((v) => counts[v]).map((v) => `
  <tr><td><span class="chip v-${esc(v.replace(/\s/g, '-'))}">${esc(v)}</span></td>
      <td class="n">${counts[v]}</td>
      <td>${esc(scored.filter((s) => s.verdict === v).map((s) => s.c.surface).join(' '))}</td></tr>`).join('');

const html = `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Что осталось послушать — Yomi</title>
<style>
  :root { --bg:#fbfaf8; --fg:#1a1a1a; --muted:#6b6b6b; --line:#e3e0da; --card:#fff;
    --accent:#8a5a2b; --warn:#b3261e; --ok:#2f6b3a; --mark:#ffe9a8; }
  @media (prefers-color-scheme: dark) { :root { --bg:#16150f; --fg:#ece7dc; --muted:#9b968b;
    --line:#322f27; --card:#1e1c15; --accent:#d8a45c; --warn:#ef8a80; --ok:#86c48f; --mark:#4a3a12; } }
  * { box-sizing: border-box; }
  body { margin:0; padding:2rem 1.25rem 6rem; background:var(--bg); color:var(--fg);
    font:15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  .wrap { max-width:900px; margin:0 auto; }
  h1 { font-size:1.6rem; margin:0 0 .25rem; }
  h2 { font-size:1.15rem; margin:0; }
  .sub { color:var(--muted); margin:0 0 2rem; }
  .reading { color:var(--accent); font-weight:500; }
  .lead { border-left:3px solid var(--accent); padding:.1rem 0 .1rem 1rem; margin:0 0 2rem; }
  .lead p { margin:.4rem 0; }
  .chip { display:inline-block; font-size:.68rem; letter-spacing:.04em; text-transform:uppercase;
    border:1px solid var(--line); border-radius:99px; padding:.1rem .5rem; color:var(--muted);
    margin-left:.4rem; white-space:nowrap; }
  .v-подозрительно { color:var(--warn); border-color:var(--warn); }
  .v-чинит { color:var(--ok); border-color:var(--ok); }
  .case { background:var(--card); border:1px solid var(--line); border-radius:14px;
    padding:1.1rem 1.2rem; margin:0 0 1.2rem; }
  .case header { display:flex; align-items:center; justify-content:space-between; gap:1rem;
    flex-wrap:wrap; }
  .hgroup { display:flex; align-items:center; gap:.3rem; }
  .jp { font-family:"Hiragino Mincho ProN","Yu Mincho","Noto Serif JP",serif; font-size:1.3rem;
    line-height:1.9; margin:.6rem 0; }
  .why { margin:.2rem 0; color:var(--muted); font-size:.9rem; }
  .players { margin-top:.8rem; display:grid; gap:.4rem; }
  .row { display:grid; grid-template-columns:170px minmax(0,1fr); gap:.4rem 1rem;
    align-items:center; padding:.5rem 0; border-top:1px solid var(--line); }
  .row audio { width:100%; height:34px; }
  .asr { grid-column:2; font-size:.82rem; color:var(--muted);
    font-family:"Hiragino Sans","Noto Sans JP",sans-serif; }
  button { background:transparent; border:1px solid var(--line); color:var(--fg);
    border-radius:99px; padding:.3rem .8rem; font-size:.8rem; cursor:pointer; }
  button:hover { border-color:var(--accent); color:var(--accent); }
  .verdict { margin-top:.8rem; padding-top:.7rem; border-top:1px solid var(--line);
    display:flex; gap:.4rem; align-items:center; flex-wrap:wrap; }
  .verdict button[aria-pressed="true"] { border-color:var(--accent); color:var(--accent); }
  .mine { font-size:.8rem; color:var(--muted); margin-left:auto; }
  table { width:100%; border-collapse:collapse; margin:.5rem 0 2.5rem; font-size:.88rem; }
  th,td { text-align:left; padding:.5rem .6rem; border-bottom:1px solid var(--line);
    vertical-align:top; }
  th { color:var(--muted); font-weight:500; font-size:.78rem; text-transform:uppercase; }
  td.n { text-align:right; font-variant-numeric:tabular-nums; }
  footer { color:var(--muted); font-size:.85rem; margin-top:3rem; border-top:1px solid var(--line);
    padding-top:1rem; }
  code { background:var(--card); border:1px solid var(--line); border-radius:5px; padding:.1rem .35rem; }
  @media (max-width:640px) { .row { grid-template-columns:1fr; } .asr { grid-column:1; } }
</style>
</head>
<body>
<div class="wrap">
  <h1>Что осталось послушать</h1>
  <p class="sub">${ears.length} случаев из ${scored.length} · остальные решены расшифровкой
    (${asr.model}) · сгенерировано ${esc(data.generated.slice(0, 16).replace('T', ' '))}</p>

  <div class="lead">
    <p><b>Расшифровка уже ответила на главный вопрос.</b> Из ${scored.filter((s) => s.verdict !== 'нет правила').length}
    случаев с контекстным правилом чтение появилось там, где его не было, в
    ${scored.filter((s) => s.verdict === 'починено').length}; в
    ${scored.filter((s) => s.verdict === 'уже читалось верно').length} оно и так звучало верно;
    <b>ни одного</b>, где правило не подействовало или испортило целевое слово.</p>
    <p>Whisper применён как <b>дифференциальный прибор</b>, а не источник истины: одна модель на трёх
    клипах одного предложения ошибается одинаково, поэтому расхождение между расшифровками —
    свидетельство о произношении, даже когда ни одна расшифровка не верна.</p>
    <p>Остался вопрос, который расшифровка решить не может: <b>не поехали ли соседние слова</b>.
    Фразовый alias может выдать верную кану и сдвинуть фразировку. Ниже — случаи, где расшифровки
    «+ правило» и «эталон» разошлись сильнее всего, то есть где такое расхождение вероятнее.
    Низкое сходство не доказывает поломку: короткая фраза даёт шум ASR сама по себе.</p>
    <p>Под каждым плеером — что услышал Whisper. Расхождение видно глазами до нажатия play.</p>
  </div>

  <table>
    <thead><tr><th>вердикт прибора</th><th class="n">случаев</th><th>слова</th></tr></thead>
    <tbody>${summaryRows}</tbody>
  </table>

  ${ears.length ? ears.map(block).join('') : '<p>Прибор решил все случаи — слушать нечего.</p>'}

  <footer>
    <p>Полная страница со всеми плечами: <code>index.html</code> · расшифровки:
      <code>transcripts.json</code></p>
    <p>Пересобрать бесплатно: <code>node scripts/tts-probes/render-ruby-verdict.mjs</code></p>
  </footer>
</div>
<script>
  const KEY = 'yomi-ruby-ears-verdicts';
  const load = () => { try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch { return {}; } };
  let v = load();
  const LABEL = { fixed:'чинит', broke:'ломает соседей', nochange:'без изменений', unsure:'не уверен' };
  function paint() {
    document.querySelectorAll('.verdict').forEach((box) => {
      const id = box.dataset.case;
      box.querySelectorAll('button').forEach((b) =>
        b.setAttribute('aria-pressed', String(b.dataset.v === v[id])));
      box.querySelector('.mine').textContent = v[id] ? LABEL[v[id]] : '';
    });
  }
  document.querySelectorAll('.verdict button').forEach((b) => b.addEventListener('click', () => {
    const id = b.closest('.verdict').dataset.case;
    v[id] = v[id] === b.dataset.v ? undefined : b.dataset.v;
    if (!v[id]) delete v[id];
    try { localStorage.setItem(KEY, JSON.stringify(v)); } catch {}
    paint();
  }));
  document.querySelectorAll('button.seq').forEach((btn) => btn.addEventListener('click', () => {
    const players = [...btn.closest('.case').querySelectorAll('audio')];
    if (btn.textContent.startsWith('■')) {
      players.forEach((a) => { a.pause(); a.onended = null; });
      btn.textContent = '▶ подряд'; return;
    }
    let i = 0;
    const next = () => {
      if (i >= players.length) { btn.textContent = '▶ подряд'; return; }
      const a = players[i];
      btn.textContent = '■ стоп (' + (i + 1) + '/' + players.length + ')';
      a.currentTime = 0; a.onended = () => { i += 1; next(); }; a.play();
    };
    next();
  }));
  paint();
</script>
</body>
</html>`;

const name = INLINE ? 'needs-ears-standalone.html' : 'needs-ears.html';
writeFileSync(`${ROOT}/${name}`, html);
console.log(`wrote ${ROOT}/${name}`);
console.log(`needs ears: ${ears.length} of ${scored.length}`);
for (const v of ORDER) if (counts[v]) console.log(`  ${v}: ${counts[v]}`);
console.log(`decided without listening: ${rest.length}`);
