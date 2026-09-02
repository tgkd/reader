import { readFileSync, writeFileSync, existsSync } from 'node:fs';

try { process.loadEnvFile('/Users/paveltrofimov/Projects/j/reader/.env'); } catch {}
const KEY = process.env.ELEVEN_KEY;
if (!KEY) { console.error('ELEVEN_KEY missing'); process.exit(1); }

for (const base of process.argv.slice(2)) {
  const out = `${base}.forced.json`;
  if (existsSync(out)) { console.log(`${base} SKIP (exists)`); continue; }
  const text = readFileSync(`${base}.txt`, 'utf8');
  const form = new FormData();
  form.append('file', new Blob([readFileSync(`${base}.mp3`)], { type: 'audio/mpeg' }), 'audio.mp3');
  form.append('text', text);
  const t0 = Date.now();
  const r = await fetch('https://api.elevenlabs.io/v1/forced-alignment', {
    method: 'POST', headers: { 'xi-api-key': KEY }, body: form });
  if (!r.ok) { console.log(`${base} HTTP ${r.status} ${(await r.text()).slice(0, 300)}`); continue; }
  const j = await r.json();
  writeFileSync(out, JSON.stringify(j));
  const chars = j.characters ?? [];
  console.log(`${base.split('/').pop()} chars=${chars.length}/${[...text].length} words=${(j.words ?? []).length} ` +
              `loss=${j.loss} end=${chars.at(-1)?.end} in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}
