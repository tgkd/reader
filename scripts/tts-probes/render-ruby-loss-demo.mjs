#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';

const ROOT = process.env.PROBE_OUT
  ?? new URL(`out/${process.env.PROBE_STAMP ?? new Date().toISOString().slice(0, 10)}-ruby-loss-demo/`,
    import.meta.url).pathname;
const data = JSON.parse(readFileSync(`${ROOT}/cases.json`, 'utf8'));

const esc = (s) => String(s).replace(/[&<>"]/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const mark = (text, needle) => {
  const safe = esc(text);
  if (!needle) return safe;
  return safe.replace(esc(needle), `<mark>${esc(needle)}</mark>`);
};

const at = (span) => (span ? `${span.start.toFixed(2)}–${span.end.toFixed(2)} с` : 'не найдено');

const INLINE = process.env.PROBE_INLINE === '1';
const src = (file) => {
  if (!INLINE) return file;
  const bytes = readFileSync(`${ROOT}/${file}`);
  return `data:audio/mpeg;base64,${bytes.toString('base64')}`;
};

const CAUSE = {
  singleCharacterToken: 'односимвольный токен — правилом не выразить',
  noCandidate: 'кандидат не построен',
};
const cause = (c) => CAUSE[c] ?? (c.startsWith('unannotatedOccurrence')
  ? 'книга разметила не все вхождения'
  : (c.startsWith('ambiguousInBook') ? 'книга читает эту поверхность двумя способами' : c));

const armRow = (id, arm, label, hint, run) => {
  if (!run || run.error) {
    return `<div class="row bad"><div class="who"><b>${esc(label)}</b></div>
      <div class="err">${esc(run?.error ?? 'нет данных')}</div></div>`;
  }
  return `<div class="row">
    <div class="who"><b>${esc(label)}</b><span class="chip">${esc(hint)}</span></div>
    <audio controls preload="none" data-case="${esc(id)}" data-arm="${esc(arm)}"
      src="${esc(src(run.file))}"></audio>
    <div class="metrics">
      <span>${run.audioSec.toFixed(2)} с</span>
      <span title="где в клипе звучит целевое слово">цель ${at(run.target)}</span>
      <span>${run.joinOK ? 'join ✓' : 'join ✗'}</span>
    </div>
  </div>`;
};

const caseBlock = (c) => `
<section class="case" id="${esc(c.id)}" data-case="${esc(c.id)}">
  <header>
    <h2>${esc(c.surface)} <span class="reading">→ ${esc(c.bookReading)}</span></h2>
    <div class="hgroup">
      <span class="chip">${esc(c.book)}</span>
      <span class="chip">×${c.count}</span>
      <button class="seq" data-case="${esc(c.id)}">▶ подряд</button>
    </div>
  </header>
  <p class="jp">${mark(c.sentence, c.surface)}</p>
  <p class="why">Книга печатает <b>${esc(c.bookReading)}</b>, MeCab читает
    <b>${esc(c.mecabReading || '—')}</b>. Правило не отправляется: ${esc(cause(c.cause))}.</p>
  <p class="listen"><b>Что слушать:</b> звучит ли <b>+ контекстное правило</b> так же, как
    <b>эталон (фраза)</b> — и не поехали ли при этом соседние слова. <b>production</b> — как звучит
    сегодня.</p>
  <div class="players">
    ${armRow(c.id, 'raw', 'production', 'что слышно сегодня', c.arms.raw)}
    ${c.arms.ctx ? armRow(c.id, 'ctx', '+ контекстное правило',
        c.contextual ? `${c.contextual.base} → ${c.contextual.baseReading}` : 'правило',
        c.arms.ctx) : ''}
    ${c.arms.ref2 ? armRow(c.id, 'ref2', 'эталон (фраза)', 'кандидат заменён каной', c.arms.ref2) : ''}
    ${armRow(c.id, 'ref', 'эталон (знак)', 'только целевой знак', c.arms.ref)}
  </div>
  ${c.arms.ctx ? '' : '<p class="why">Контекстной базы нет — этот случай механизм не чинит.</p>'}
  <div class="verdict" data-case="${esc(c.id)}">
    <button data-v="fixed">правило чинит</button>
    <button data-v="broke">правило ломает соседей</button>
    <button data-v="nochange">ничего не изменилось</button>
    <button data-v="unsure">не уверен</button>
    <span class="mine"></span>
  </div>
</section>`;

const p = data.population;
const html = `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Слышна ли потеря рубя — Yomi</title>
<style>
  :root {
    --bg: #fbfaf8; --fg: #1a1a1a; --muted: #6b6b6b; --line: #e3e0da;
    --card: #ffffff; --accent: #8a5a2b; --warn: #b3261e; --ok: #2f6b3a; --mark: #ffe9a8;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #16150f; --fg: #ece7dc; --muted: #9b968b; --line: #322f27;
      --card: #1e1c15; --accent: #d8a45c; --warn: #ef8a80; --ok: #86c48f; --mark: #4a3a12;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 2rem 1.25rem 6rem; background: var(--bg); color: var(--fg);
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  }
  .wrap { max-width: 860px; margin: 0 auto; }
  h1 { font-size: 1.6rem; margin: 0 0 .25rem; letter-spacing: -.01em; }
  .sub { color: var(--muted); margin: 0 0 2rem; }
  h2 { font-size: 1.15rem; margin: 0; }
  .reading { color: var(--accent); font-weight: 500; }
  .lead { border-left: 3px solid var(--accent); padding: .1rem 0 .1rem 1rem; margin: 0 0 2rem; }
  .lead p { margin: .4rem 0; }
  .chip {
    display: inline-block; font-size: .68rem; letter-spacing: .04em; text-transform: uppercase;
    border: 1px solid var(--line); border-radius: 99px; padding: .1rem .5rem; color: var(--muted);
    margin-left: .4rem; white-space: nowrap;
  }
  .case { background: var(--card); border: 1px solid var(--line); border-radius: 14px;
    padding: 1.1rem 1.2rem; margin: 0 0 1.2rem; }
  .case header { display: flex; align-items: center; justify-content: space-between; gap: 1rem;
    flex-wrap: wrap; }
  .hgroup { display: flex; align-items: center; gap: .3rem; }
  .jp {
    font-family: "Hiragino Mincho ProN", "Yu Mincho", "Noto Serif JP", serif;
    font-size: 1.35rem; line-height: 1.95; margin: .8rem 0 .6rem; white-space: pre-wrap;
  }
  mark { background: var(--mark); color: inherit; padding: 0 .1em; border-radius: 3px; }
  .why, .listen { margin: .2rem 0; color: var(--muted); font-size: .9rem; }
  .listen { color: var(--fg); }
  .players { margin-top: 1rem; display: grid; gap: .5rem; }
  .row {
    display: grid; grid-template-columns: 200px minmax(0, 1fr); gap: .5rem 1rem;
    align-items: center; padding: .5rem 0; border-top: 1px solid var(--line);
  }
  .row .who { font-size: .9rem; }
  .row audio { width: 100%; height: 34px; }
  .metrics {
    grid-column: 2; display: flex; flex-wrap: wrap; gap: .9rem;
    font-size: .78rem; color: var(--muted); font-variant-numeric: tabular-nums;
  }
  .err { color: var(--warn); font-size: .85rem; }
  button {
    background: transparent; border: 1px solid var(--line); color: var(--fg);
    border-radius: 99px; padding: .3rem .8rem; font-size: .8rem; cursor: pointer;
  }
  button:hover { border-color: var(--accent); color: var(--accent); }
  .verdict { margin-top: .9rem; padding-top: .8rem; border-top: 1px solid var(--line);
    display: flex; gap: .4rem; align-items: center; flex-wrap: wrap; }
  .verdict button[aria-pressed="true"] { border-color: var(--accent); color: var(--accent);
    background: color-mix(in srgb, var(--accent) 12%, transparent); }
  .mine { font-size: .8rem; color: var(--muted); margin-left: auto; }
  .tally { position: sticky; top: 0; z-index: 5; background: var(--bg);
    border-bottom: 1px solid var(--line); padding: .7rem 0; margin: 0 0 1.5rem;
    display: flex; gap: 1.2rem; align-items: center; flex-wrap: wrap;
    font-size: .85rem; font-variant-numeric: tabular-nums; }
  .tally b { font-size: 1rem; }
  .tally .same { color: var(--ok); }
  .tally .diff { color: var(--warn); }
  footer { color: var(--muted); font-size: .85rem; margin-top: 3rem;
    border-top: 1px solid var(--line); padding-top: 1rem; }
  code { background: var(--card); border: 1px solid var(--line); border-radius: 5px;
    padding: .1rem .35rem; font-size: .85em; }
  @media (max-width: 640px) {
    .row { grid-template-columns: 1fr; }
    .metrics { grid-column: 1; }
  }
</style>
</head>
<body>
<div class="wrap">
  <h1>Чинит ли контекстное правило</h1>
  <p class="sub">Голос ${esc(data.voice.name)} · ${esc(data.model)} ·
    ${data.results.length} случаев × 2 плеча ·
    сгенерировано ${esc(data.generated.slice(0, 16).replace('T', ' '))}</p>

  <div class="lead">
    <p>Замер по восьми стартовым книгам нашёл <b>250 мест</b>, где книга напечатала чтение,
    MeCab читает иначе, и правило произношения до API не доезжает. Цифра — верхняя граница:
    место считается непокрытым, если правило не накрывает <i>каждый</i> знак токена.</p>
    <p>Вопрос страницы один: <b>слышна ли эта разница вообще.</b> Если оба клипа звучат
    одинаково, потеря существует на бумаге, а не в ушах, и трогать ворота лексикона незачем.</p>
    <p><b>production</b> — предложение так, как его отправляет приложение сегодня, без словаря.
    <b>эталон</b> — тот же текст с подставленной книжной каной. Односимвольное правило отправить
    нельзя (ElevenLabs требует базу от двух знаков), поэтому эталон делается подстановкой в текст.</p>
    <p><b>Второй прогон.</b> Замер нашёл контекстную базу для ${data.contextualCases ?? 0} из
    ${data.results.length} случаев: вместо неотправляемого односимвольного правила берётся более
    длинная строка, чьё чтение заверено книгой в каждом вхождении. Правила загружены настоящим
    словарём ElevenLabs (${data.dictionary?.rules ?? 0} записей,
    <code>${esc(data.dictionary?.id ?? '—')}</code>).</p>
    <p>Взято ${p.chosenPairs} пар из ${p.distinctPairs}: все повторяющиеся плюс выборка из
    хвоста в ${p.tailLength} одиночных. <b>Не озвучено ${p.droppedPairs} пар
    (${p.droppedOccurrences} вхождений)</b> — страница покрывает верхушку, а не всё.</p>
  </div>

  <div class="tally">
    <span>Прослушано <b id="done">0</b> из ${data.results.length}</span>
    <span class="same">чинит <b id="nsame">0</b></span>
    <span class="diff">ломает соседей <b id="ndiff">0</b></span>
    <span>без изменений <b id="nnochange">0</b></span>
    <span>не уверен <b id="nunsure">0</b></span>
    <button id="copy">скопировать вердикты</button>
    <button id="reset">сбросить</button>
  </div>

  ${data.results.map(caseBlock).join('')}

  <footer>
    <p>Пересобрать аудио (тратит деньги):
      <code>PROBE_CASES=&lt;loss.json&gt; node scripts/tts-probes/build-ruby-loss-demo.mjs</code></p>
    <p>Перерисовать страницу бесплатно:
      <code>node scripts/tts-probes/render-ruby-loss-demo.mjs</code></p>
    <p>Случаи выгружает <code>RubyCoverageProbe.testDescribedSiteCoverage</code>
      строкой <code>LOSSJSON</code>.</p>
  </footer>
</div>
<script>
  const KEY = 'yomi-ruby-ctx-verdicts';
  const load = () => { try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch { return {}; } };
  const save = (v) => { try { localStorage.setItem(KEY, JSON.stringify(v)); } catch { /* private mode */ } };
  let verdicts = load();

  const LABEL = { fixed: 'чинит', broke: 'ломает соседей', nochange: 'без изменений', unsure: 'не уверен' };

  function paint() {
    let fixed = 0, broke = 0, nochange = 0, unsure = 0;
    document.querySelectorAll('.verdict').forEach((box) => {
      const id = box.dataset.case;
      const v = verdicts[id];
      box.querySelectorAll('button').forEach((b) => {
        b.setAttribute('aria-pressed', String(b.dataset.v === v));
      });
      box.querySelector('.mine').textContent = v ? LABEL[v] : '';
      if (v === 'fixed') fixed += 1;
      if (v === 'broke') broke += 1;
      if (v === 'nochange') nochange += 1;
      if (v === 'unsure') unsure += 1;
    });
    document.getElementById('nsame').textContent = fixed;
    document.getElementById('ndiff').textContent = broke;
    document.getElementById('nnochange').textContent = nochange;
    document.getElementById('nunsure').textContent = unsure;
    document.getElementById('done').textContent = fixed + broke + nochange + unsure;
  }

  document.querySelectorAll('.verdict button').forEach((b) => {
    b.addEventListener('click', () => {
      const id = b.closest('.verdict').dataset.case;
      verdicts[id] = verdicts[id] === b.dataset.v ? undefined : b.dataset.v;
      if (!verdicts[id]) delete verdicts[id];
      save(verdicts);
      paint();
    });
  });

  document.getElementById('reset').addEventListener('click', () => {
    verdicts = {}; save(verdicts); paint();
  });

  document.getElementById('copy').addEventListener('click', async () => {
    const rows = [...document.querySelectorAll('.case')].map((s) => ({
      id: s.dataset.case,
      word: s.querySelector('h2').textContent.trim().replace(/\\s+/g, ' '),
      verdict: verdicts[s.dataset.case] ?? null,
    }));
    const text = JSON.stringify(rows, null, 2);
    try { await navigator.clipboard.writeText(text); } catch { console.log(text); }
    const b = document.getElementById('copy');
    b.textContent = 'скопировано';
    setTimeout(() => { b.textContent = 'скопировать вердикты'; }, 1500);
  });

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

  paint();
</script>
</body>
</html>`;

const name = INLINE ? 'standalone.html' : 'index.html';
writeFileSync(`${ROOT}/${name}`, html);
const mb = (Buffer.byteLength(html) / 1e6).toFixed(1);
console.log(`wrote ${ROOT}/${name} (${data.results.length} cases, ${mb} MB)`);
if (!INLINE) console.log('PROBE_INLINE=1 embeds the audio into one portable file');
