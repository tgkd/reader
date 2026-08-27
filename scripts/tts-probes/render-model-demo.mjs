#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';

const ROOT = process.env.PROBE_OUT
  ?? new URL(`out/${process.env.PROBE_STAMP ?? new Date().toISOString().slice(0, 10)}-model-demo/`,
    import.meta.url).pathname;
const data = JSON.parse(readFileSync(`${ROOT}/cases.json`, 'utf8'));

const esc = (s) => String(s).replace(/[&<>"]/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const mark = (text, surface) => {
  const safe = esc(text);
  if (!surface) return safe;
  return safe.replace(esc(surface), `<mark>${esc(surface)}</mark>`);
};

const GUARD = 1.0;
const num = (v, d = 2) => (v === undefined ? '—' : v.toFixed(d));

const mean = (id, field) => {
  const xs = data.results.map((r) => r.runs[id]?.[field]).filter((x) => typeof x === 'number');
  return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : undefined;
};

const summaryRows = data.configs.map((cfg) => `
  <tr>
    <td><b>${esc(cfg.label)}</b><br><span class="chip">${esc(cfg.tag)}</span></td>
    <td class="n">${esc(cfg.cost)}</td>
    <td class="n">${num(mean(cfg.id, 'charsPerSecond'), 2)}</td>
    <td class="n">${num(mean(cfg.id, 'undescribed'), 3)}</td>
    <td class="n">${num(Math.max(...data.results.map((r) => r.runs[cfg.id]?.longestBlank ?? 0)), 2)}</td>
  </tr>`).join('');

const playerRow = (cfg, run) => {
  if (!run || run.error) {
    return `<div class="row bad"><div class="who"><b>${esc(cfg.label)}</b></div>
      <div class="err">${esc(run?.error ?? 'нет данных')}</div></div>`;
  }
  const over = run.undescribed > GUARD;
  return `<div class="row">
    <div class="who"><b>${esc(cfg.label)}</b><span class="chip">${esc(cfg.tag)}</span></div>
    <audio controls preload="none" src="${esc(run.file)}"></audio>
    <div class="metrics">
      <span title="длительность аудио">${num(run.audioSec, 2)} с</span>
      <span class="${over ? 'warn' : ''}" title="аудио, не описанное выравниванием; клиент отбраковывает > 1 с">
        неописано ${num(run.undescribed, 3)} с${over ? ' ⚠' : ''}</span>
      <span title="выравнивание склеивается обратно в исходный текст">${run.joinOK ? 'join ✓' : 'join ✗'}</span>
      <span title="самая длинная пауза, повешенная на пробельную позицию">пауза ${num(run.longestBlank, 2)} с</span>
    </div>
  </div>`;
};

const caseBlock = (c) => `
<section class="case" id="${esc(c.id)}">
  <header>
    <h2>${c.surface ? `${esc(c.surface)} <span class="reading">→ ${esc(c.reading)}</span>` : 'Связная проза'}</h2>
    <button class="seq" data-case="${esc(c.id)}">▶ подряд</button>
  </header>
  <p class="jp">${mark(c.text, c.surface)}</p>
  <p class="why">${esc(c.why)}</p>
  <p class="listen"><b>Что слушать:</b> ${esc(c.listen)}</p>
  <div class="players">${data.configs.map((cfg) => playerRow(cfg, c.runs[cfg.id])).join('')}</div>
</section>`;

const html = `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Сравнение моделей озвучки — Yomi</title>
<style>
  :root {
    --bg: #fbfaf8; --fg: #1a1a1a; --muted: #6b6b6b; --line: #e3e0da;
    --card: #ffffff; --accent: #8a5a2b; --warn: #b3261e; --mark: #ffe9a8;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #16150f; --fg: #ece7dc; --muted: #9b968b; --line: #322f27;
      --card: #1e1c15; --accent: #d8a45c; --warn: #ef8a80; --mark: #4a3a12;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 2rem 1.25rem 5rem; background: var(--bg); color: var(--fg);
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  }
  .wrap { max-width: 860px; margin: 0 auto; }
  h1 { font-size: 1.6rem; margin: 0 0 .25rem; letter-spacing: -.01em; }
  .sub { color: var(--muted); margin: 0 0 2rem; }
  h2 { font-size: 1.15rem; margin: 0; }
  .reading { color: var(--accent); font-weight: 500; }
  .lead { border-left: 3px solid var(--accent); padding: .1rem 0 .1rem 1rem; margin: 0 0 2rem; }
  .legend { display: grid; gap: .6rem; margin: 0 0 2.5rem; }
  .legend div { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: .7rem .9rem; }
  .legend b { margin-right: .5rem; }
  .legend p { margin: .3rem 0 0; color: var(--muted); font-size: .9rem; }
  .chip {
    display: inline-block; font-size: .68rem; letter-spacing: .04em; text-transform: uppercase;
    border: 1px solid var(--line); border-radius: 99px; padding: .1rem .5rem; color: var(--muted);
    margin-left: .4rem; white-space: nowrap;
  }
  .case { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 1.1rem 1.2rem; margin: 0 0 1.2rem; }
  .case header { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
  .jp {
    font-family: "Hiragino Mincho ProN", "Yu Mincho", "Noto Serif JP", serif;
    font-size: 1.5rem; line-height: 1.9; margin: .8rem 0 .6rem; white-space: pre-wrap;
  }
  mark { background: var(--mark); color: inherit; padding: 0 .1em; border-radius: 3px; }
  .why, .listen { margin: .2rem 0; color: var(--muted); font-size: .9rem; }
  .listen { color: var(--fg); }
  .players { margin-top: 1rem; display: grid; gap: .5rem; }
  .row {
    display: grid; grid-template-columns: 210px minmax(0, 1fr); gap: .5rem 1rem;
    align-items: center; padding: .5rem 0; border-top: 1px solid var(--line);
  }
  .row .who { font-size: .9rem; }
  .row audio { width: 100%; height: 34px; }
  .metrics {
    grid-column: 2; display: flex; flex-wrap: wrap; gap: .9rem;
    font-size: .78rem; color: var(--muted); font-variant-numeric: tabular-nums;
  }
  .warn { color: var(--warn); font-weight: 600; }
  .err { color: var(--warn); font-size: .85rem; }
  button.seq {
    background: transparent; border: 1px solid var(--line); color: var(--fg);
    border-radius: 99px; padding: .3rem .8rem; font-size: .8rem; cursor: pointer;
  }
  button.seq:hover { border-color: var(--accent); color: var(--accent); }
  table { width: 100%; border-collapse: collapse; margin: .5rem 0 2rem; font-size: .88rem; }
  th, td { text-align: left; padding: .5rem .6rem; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { color: var(--muted); font-weight: 500; font-size: .78rem; text-transform: uppercase; letter-spacing: .04em; }
  td.n { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  footer { color: var(--muted); font-size: .85rem; margin-top: 3rem; border-top: 1px solid var(--line); padding-top: 1rem; }
  code { background: var(--card); border: 1px solid var(--line); border-radius: 5px; padding: .1rem .35rem; font-size: .85em; }
  @media (max-width: 640px) {
    .row { grid-template-columns: 1fr; }
    .metrics { grid-column: 1; }
  }
</style>
</head>
<body>
<div class="wrap">
  <h1>Сравнение моделей озвучки</h1>
  <p class="sub">Голос ${esc(data.voice.name)} · ${data.results.length} текстов × ${data.configs.length} конфигураций ·
    сгенерировано ${esc(data.generated.slice(0, 16).replace('T', ' '))}</p>

  <div class="lead">
    <p>Каждый пример — это место, где токенизатор или модель уже ошибались. Всё, кроме модели и словаря,
    совпадает с продакшеном: <code>language_code: ja</code>, закреплённые <code>voice_settings</code>
    (отфильтрованные по возможностям модели), <code>stream/with-timestamps</code>, <code>mp3_44100_128</code>.</p>
    <p><b>«Неописано»</b> — сколько секунд аудио не покрыто выравниванием. Клиент отбраковывает главу
    при расхождении больше ${GUARD} с; всё, что ниже порога, кэшируется навсегда вместе с уходом подсветки.</p>
  </div>

  <div class="legend">
    ${data.configs.map((c) => `<div><b>${esc(c.label)}</b><span class="chip">${esc(c.tag)}</span>
      <span class="chip">${esc(c.cost)}</span><p>${esc(c.note)}</p></div>`).join('')}
  </div>

  <h2>Сводка</h2>
  <table>
    <thead><tr><th>конфигурация</th><th class="n">цена</th><th class="n">знаков/с</th>
      <th class="n">неописано, сред.</th><th class="n">макс. пауза</th></tr></thead>
    <tbody>${summaryRows}</tbody>
  </table>

  ${data.results.map(caseBlock).join('')}

  <footer>
    <p>Словарь произношения: <code>${esc(data.lexicon.id)}</code> v<code>${esc(data.lexicon.version)}</code> —
    заархивировать после прослушивания (<code>archive-dictionaries.mjs</code>).</p>
    <p>Пересобрать аудио: <code>node scripts/tts-probes/build-model-demo.mjs</code> ·
    перерисовать страницу бесплатно: <code>node scripts/tts-probes/render-model-demo.mjs</code></p>
  </footer>
</div>
<script>
  document.querySelectorAll('button.seq').forEach((btn) => {
    btn.addEventListener('click', () => {
      const players = [...btn.closest('.case').querySelectorAll('audio')];
      let i = 0;
      const next = () => {
        if (i >= players.length) { btn.textContent = '▶ подряд'; return; }
        const a = players[i];
        btn.textContent = '■ стоп (' + (i + 1) + '/' + players.length + ')';
        a.currentTime = 0;
        a.onended = () => { i += 1; next(); };
        a.play();
      };
      if (btn.textContent.startsWith('■')) {
        players.forEach((a) => { a.pause(); a.onended = null; });
        btn.textContent = '▶ подряд';
        return;
      }
      next();
    });
  });
</script>
</body>
</html>`;

writeFileSync(`${ROOT}/index.html`, html);
console.log(`wrote ${ROOT}/index.html`);
