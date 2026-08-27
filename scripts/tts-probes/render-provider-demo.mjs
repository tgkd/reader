#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';

const ROOT = process.env.PROBE_OUT
  ?? new URL(`out/${process.env.PROBE_STAMP ?? new Date().toISOString().slice(0, 10)}-provider-demo/`,
    import.meta.url).pathname;
const data = JSON.parse(readFileSync(`${ROOT}/cases.json`, 'utf8'));

const esc = (s) => String(s).replace(/[&<>"]/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const mark = (text, surface) => {
  const safe = esc(text);
  return surface ? safe.replace(esc(surface), `<mark>${esc(surface)}</mark>`) : safe;
};
const GUARD = 1.0;
const num = (v, d = 2) => (typeof v === 'number' ? v.toFixed(d) : '—');

const stat = (id, field, pick) => {
  const xs = data.results.map((r) => r.runs[id]?.[field]).filter((x) => typeof x === 'number');
  if (!xs.length) return undefined;
  return pick === 'max' ? Math.max(...xs) : xs.reduce((a, b) => a + b, 0) / xs.length;
};
const joinFails = (id) => data.results
  .filter((r) => r.runs[id] && !r.runs[id].error && !r.runs[id].joinOKIgnoringBlanks).length;

const summary = data.configs.map((cfg) => `
  <tr>
    <td><b>${esc(cfg.label)}</b><br><span class="chip">${esc(cfg.tag)}</span></td>
    <td class="n">${num(stat(cfg.id, 'charsPerSecond'), 2)}</td>
    <td class="n">${num(stat(cfg.id, 'undescribed'), 3)}</td>
    <td class="n">${num(stat(cfg.id, 'undescribed', 'max'), 3)}</td>
    <td class="n ${joinFails(cfg.id) ? 'warn' : ''}">${joinFails(cfg.id)} / ${data.results.length}</td>
  </tr>`).join('');

const row = (cfg, run) => {
  if (!run || run.error) {
    return `<div class="row"><div class="who"><b>${esc(cfg.label)}</b></div>
      <div class="err">${esc(run?.error ?? 'нет данных')}</div></div>`;
  }
  const over = run.undescribed > GUARD;
  const expected = run.joinOK ? run.expectedUnits : run.expectedNonBlank;
  const unitsOff = !run.joinOKIgnoringBlanks;
  const blanksOnly = !run.joinOK && run.joinOKIgnoringBlanks;
  return `<div class="row">
    <div class="who"><b>${esc(cfg.label)}</b><span class="chip">${esc(cfg.provider)}</span></div>
    <audio controls preload="none" src="${esc(run.file)}"></audio>
    <div class="metrics">
      <span>${num(run.audioSec)} с</span>
      <span class="${over ? 'warn' : ''}" title="аудио, не описанное выравниванием; клиент отбраковывает > 1 с">
        неописано ${num(run.undescribed, 3)} с${over ? ' ⚠' : ''}</span>
      <span class="${run.joinOKIgnoringBlanks ? '' : 'warn'}"
        title="склейка меток обратно в текст">${run.joinOKIgnoringBlanks
          ? (blanksOnly ? 'склейка ✓ (без пробелов)' : 'склейка ✓') : 'склейка ✗'}</span>
      <span class="${unitsOff ? 'warn' : ''}" title="меток выравнивания против размечаемых символов">
        меток ${run.units}/${expected}</span>
    </div>
  </div>`;
};

const block = (c) => `
<section class="case">
  <header>
    <h2>${c.surface ? `${esc(c.surface)} <span class="reading">→ ${esc(c.reading)}</span>` : 'Связная проза'}</h2>
    <button class="seq">▶ подряд</button>
  </header>
  <p class="jp">${mark(c.text, c.surface)}</p>
  <p class="why">${esc(c.why)}</p>
  ${c.reference && !c.reference.error ? `
  <div class="ref">
    <div class="who"><b>эталон</b><span class="chip">как должно звучать</span><br>
      <span class="kana">${esc(c.reference.text)}</span></div>
    <audio controls preload="none" src="${esc(c.reference.file)}"></audio>
  </div>` : ''}
  <div class="players">${data.configs.map((cfg) => row(cfg, c.runs[cfg.id])).join('')}</div>
</section>`;

const html = `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ElevenLabs против Cartesia — Yomi</title>
<style>
  :root { --bg:#fbfaf8; --fg:#1a1a1a; --muted:#6b6b6b; --line:#e3e0da; --card:#fff;
          --accent:#8a5a2b; --warn:#b3261e; --mark:#ffe9a8; --ref:#f2f6f2; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#16150f; --fg:#ece7dc; --muted:#9b968b; --line:#322f27; --card:#1e1c15;
            --accent:#d8a45c; --warn:#ef8a80; --mark:#4a3a12; --ref:#1a2018; }
  }
  * { box-sizing: border-box; }
  body { margin:0; padding:2rem 1.25rem 5rem; background:var(--bg); color:var(--fg);
         font:15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  .wrap { max-width:880px; margin:0 auto; }
  h1 { font-size:1.6rem; margin:0 0 .25rem; }
  .sub { color:var(--muted); margin:0 0 2rem; }
  h2 { font-size:1.15rem; margin:0; }
  .reading { color:var(--accent); font-weight:500; }
  .lead { border-left:3px solid var(--accent); padding:.1rem 0 .1rem 1rem; margin:0 0 2rem; }
  .legend { display:grid; gap:.6rem; margin:0 0 2.5rem; }
  .legend div { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:.7rem .9rem; }
  .legend p { margin:.3rem 0 0; color:var(--muted); font-size:.9rem; }
  .chip { display:inline-block; font-size:.68rem; letter-spacing:.04em; text-transform:uppercase;
          border:1px solid var(--line); border-radius:99px; padding:.1rem .5rem; color:var(--muted);
          margin-left:.4rem; white-space:nowrap; }
  .case { background:var(--card); border:1px solid var(--line); border-radius:14px;
          padding:1.1rem 1.2rem; margin:0 0 1.2rem; }
  .case header { display:flex; align-items:center; justify-content:space-between; gap:1rem; }
  .jp { font-family:"Hiragino Mincho ProN","Yu Mincho","Noto Serif JP",serif;
        font-size:1.35rem; line-height:2; margin:.8rem 0 .6rem; white-space:pre-wrap; }
  mark { background:var(--mark); color:inherit; padding:0 .1em; border-radius:3px; }
  .why { margin:.2rem 0 0; color:var(--muted); font-size:.9rem; }
  .ref { display:grid; grid-template-columns:210px minmax(0,1fr); gap:.5rem 1rem; align-items:center;
         background:var(--ref); border:1px dashed var(--line); border-radius:10px;
         padding:.6rem .8rem; margin:1rem 0 .2rem; }
  .kana { font-family:"Hiragino Mincho ProN",serif; font-size:1.05rem; color:var(--accent); }
  .players { margin-top:.4rem; display:grid; gap:.5rem; }
  .row { display:grid; grid-template-columns:210px minmax(0,1fr); gap:.5rem 1rem;
         align-items:center; padding:.5rem 0; border-top:1px solid var(--line); }
  .row .who { font-size:.9rem; }
  .row audio, .ref audio { width:100%; height:34px; }
  .metrics { grid-column:2; display:flex; flex-wrap:wrap; gap:.9rem; font-size:.78rem;
             color:var(--muted); font-variant-numeric:tabular-nums; }
  .warn { color:var(--warn); font-weight:600; }
  .err { color:var(--warn); font-size:.85rem; }
  button.seq { background:transparent; border:1px solid var(--line); color:var(--fg);
               border-radius:99px; padding:.3rem .8rem; font-size:.8rem; cursor:pointer; }
  button.seq:hover { border-color:var(--accent); color:var(--accent); }
  table { width:100%; border-collapse:collapse; margin:.5rem 0 2rem; font-size:.88rem; }
  th, td { text-align:left; padding:.5rem .6rem; border-bottom:1px solid var(--line); vertical-align:top; }
  th { color:var(--muted); font-weight:500; font-size:.75rem; text-transform:uppercase; letter-spacing:.04em; }
  td.n { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }
  footer { color:var(--muted); font-size:.85rem; margin-top:3rem; border-top:1px solid var(--line); padding-top:1rem; }
  code { background:var(--card); border:1px solid var(--line); border-radius:5px; padding:.1rem .35rem; font-size:.85em; }
  @media (max-width:640px) { .row, .ref { grid-template-columns:1fr; } .metrics { grid-column:1; } }
</style>
</head>
<body>
<div class="wrap">
  <h1>ElevenLabs против Cartesia</h1>
  <p class="sub">${esc(data.results.length)} текстов × ${esc(data.configs.length)} конфигураций ·
    голоса: ElevenLabs ${esc(data.voices.ElevenLabs)}, Cartesia ${esc(data.voices.Cartesia)} ·
    ${esc(data.generated.slice(0, 16).replace('T', ' '))}</p>

  <div class="lead">
    <p>Имена стоят <b>внутри абзаца</b>, а не в изолированной фразе: контекстное чтение берётся из
    контекста, и на 18 знаках его просто нет. У каждого случая есть <b>эталон</b> — то же имя,
    записанное каной, — чтобы «неправильно» было слышно, а не казалось.</p>
    <p><b>Неописано</b> — секунды аудио без выравнивания (клиент отбраковывает главу при &gt; ${GUARD} с).
    <b>Меток</b> — сколько единиц выравнивания вернул провайдер против числа размечаемых символов.
    Cartesia для японского размечает <i>посимвольно</i>, как и ElevenLabs, но <b>не размечает
    пробелы</b>: склейка сходится с текстом без пробельных символов. Это не дефект — ровно так же
    ведёт себя MeCab, и <code>MeCabTokenizer</code> уже отдаёт пробелы как untimed gap tokens.
    Поэтому <code>CharTokenMapper</code> переделывать не пришлось бы.</p>
  </div>

  <div class="lead" style="border-left-color:var(--warn)">
    <p><b>Найдено при добавлении арма «Cartesia + словарь»:</b> каждое сработавшее правило словаря
    Cartesia теряет ~0.25–0.33 с выравнивания. Тексты без правил не меняются вовсе
    (0.015–0.031 с), два правила дают 0.774 с, три — 0.820 и <b>0.991 с</b> при клиентском пороге
    1.0 с. На реальной главе с десятком имён это гарантированная отбраковка. У ElevenLabs
    словарь выравнивание не трогает (0.042 с со словарём и без).</p>
  </div>

  <div class="legend">
    ${data.configs.map((c) => `<div><b>${esc(c.label)}</b><span class="chip">${esc(c.tag)}</span>
      <p>${esc(c.note)}</p></div>`).join('')}
  </div>

  <h2>Сводка</h2>
  <table>
    <thead><tr><th>конфигурация</th><th class="n">знаков/с</th><th class="n">неописано, сред.</th>
      <th class="n">неописано, макс.</th><th class="n">склейка не сходится</th></tr></thead>
    <tbody>${summary}</tbody>
  </table>

  ${data.results.map(block).join('')}

  <footer>
    <p>Cartesia идёт через Cloudflare AI Gateway (provider key в шлюзе, новых секретов в Worker нет),
    <code>Cartesia-Version: 2026-03-01</code>, SSE + <code>add_timestamps</code>.
    По докам: «Only the Bytes endpoint supports all container formats; our other endpoints (SSE,
    WebSockets) only support <code>raw</code>» — поэтому Cartesia здесь raw PCM, завёрнутый в WAV,
    а ElevenLabs остаётся mp3.</p>
    <p>Словарь ElevenLabs: <code>${esc(data.lexicon.id)}</code> (заархивировать после прослушивания) ·
    словарь Cartesia: <code>${esc(data.cartesiaDict?.id ?? '—')}</code>, ${esc(data.cartesiaDict?.items ?? 0)} правил.
    Оба собраны из одних и тех же чтений рубя, так что арма со словарём теперь есть у обоих провайдеров.</p>
    <p>Пересобрать: <code>node scripts/tts-probes/build-provider-demo.mjs</code> ·
    перерисовать бесплатно: <code>node scripts/tts-probes/render-provider-demo.mjs</code></p>
  </footer>
</div>
<script>
  document.querySelectorAll('button.seq').forEach((btn) => {
    btn.addEventListener('click', () => {
      const players = [...btn.closest('.case').querySelectorAll('audio')];
      if (btn.textContent.startsWith('■')) {
        players.forEach((a) => { a.pause(); a.onended = null; });
        btn.textContent = '▶ подряд';
        return;
      }
      let i = 0;
      const next = () => {
        if (i >= players.length) { btn.textContent = '▶ подряд'; return; }
        const a = players[i];
        btn.textContent = '■ стоп (' + (i + 1) + '/' + players.length + ')';
        a.currentTime = 0;
        a.onended = () => { i += 1; next(); };
        a.play();
      };
      next();
    });
  });
</script>
</body>
</html>`;

writeFileSync(`${ROOT}/index.html`, html);
console.log(`wrote ${ROOT}/index.html`);
