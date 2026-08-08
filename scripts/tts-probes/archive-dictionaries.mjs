#!/usr/bin/env node
/**
 * Archive probe dictionaries, selected by name.
 *
 * Archiving is the only cleanup ElevenLabs offers — DELETE returns 405 — and it is NOT a soft
 * one: an archived dictionary answers 404 at synthesis rather than being ignored, so archiving
 * anything a request might still pin takes narration to zero for that book. See §10 of
 * docs/2026-08-07-pronunciation-dictionaries.md.
 *
 * Hence two rules, both enforced here rather than left to the operator:
 *
 *   1. Selection is by name PREFIX and nothing is hardcoded, because a list of ids copied from
 *      an old run is exactly how the wrong thing gets archived.
 *   2. Anything the WORKER minted is refused outright. Those are named `yomi-<16 hex>` and are
 *      reachable from a KV mapping in production; archiving one degrades a real book's narration
 *      permanently, because the mapping survives and keeps resolving to a dead locator.
 *
 * Dry run by default. Pass --apply to actually archive.
 *
 *   node scripts/tts-probes/archive-dictionaries.mjs probe-           # show what would go
 *   node scripts/tts-probes/archive-dictionaries.mjs probe- --apply
 */
try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY'); process.exit(1); }

const args = process.argv.slice(2);
const apply = args.includes('--apply');
const prefixes = args.filter((a) => !a.startsWith('--'));
if (!prefixes.length) {
  console.error('usage: archive-dictionaries.mjs <name-prefix> [more-prefixes] [--apply]');
  process.exit(1);
}

/// The Worker names what it creates `yomi-<first 16 of the rule-set hash>`. Production KV maps
/// that hash to this dictionary, so it must never be archived from here.
const WORKER_MINTED = /^yomi-[0-9a-f]{16}$/;

const api = (path, init = {}) => fetch(`https://api.elevenlabs.io/v1/${path}`, {
  ...init,
  headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', ...(init.headers || {}) },
});

const list = await (await api('pronunciation-dictionaries?page_size=100')).json();
const live = (list.pronunciation_dictionaries || []).filter((d) => !d.archived_time_unix);

const matched = live.filter((d) => prefixes.some((p) => d.name.startsWith(p)));
const refused = matched.filter((d) => WORKER_MINTED.test(d.name));
const targets = matched.filter((d) => !WORKER_MINTED.test(d.name));

console.log(`live dictionaries: ${live.length}`);
console.log(`matching ${prefixes.join(', ')}: ${matched.length}\n`);

for (const d of refused) {
  console.log(`  REFUSED ${d.name} (${d.id}) — Worker-minted, may be pinned in production KV`);
}
for (const d of targets) {
  console.log(`  ${apply ? 'archiving' : 'would archive'} ${d.name} (${d.id})`);
}

const untouched = live.filter((d) => !matched.includes(d));
if (untouched.length) {
  console.log(`\nleft alone (${untouched.length}): ${untouched.map((d) => d.name).join(', ')}`);
}

if (!apply) {
  console.log('\ndry run — pass --apply to archive');
  process.exit(0);
}

let ok = 0;
console.log('');
for (const d of targets) {
  const res = await api(`pronunciation-dictionaries/${d.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ archived: true }),
  });
  const body = await res.text();
  if (res.ok) {
    console.log(`  ${d.name} -> archived`);
    ok++;
  } else {
    console.log(`  ${d.name} -> HTTP ${res.status}: ${body.slice(0, 160)}`);
  }
}
console.log(`\n${ok}/${targets.length} archived.`);
