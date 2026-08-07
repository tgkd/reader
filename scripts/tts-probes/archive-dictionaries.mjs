#!/usr/bin/env node
/**
 * Archive every probe dictionary this investigation created, and in doing so verify the
 * claim that decides the whole lifecycle design: DELETE returns 405, but PATCH accepts
 * `archived: true`. If archiving works, per-book dictionaries ARE reclaimable and the
 * shared-mutable-dictionary design (with its race and its dependence on undocumented
 * version immutability) is unnecessary.
 */
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

try { process.loadEnvFile(new URL('../../.env', import.meta.url)); } catch { /* ambient */ }
const KEY = process.env.ELEVEN_KEY || process.env.ELEVENLABS_KEY;
if (!KEY) { console.error('no ELEVEN_KEY'); process.exit(1); }

const IDS = [
  'bTim13lM7L7g0owXGItU', 'H4P32GOj8xktC3uYcQn5',                        // probe 1
  'wrIlrlptjBy7PzTrjqxf', 'vyl2ZiUSm1IXVIvSgI9U', 'N6V3mClBK11uZuZBmmRC', // probe 2
  'teUsKr1QTWiEuJ5rIO2O', '3hz6HuMVaZo1fFB9PnTy',                        // probe 3
  'vArR7wGfyzR8GNLZcU8t', 'w0z2W5quGRVT6g0a1X6y',                        // probe 4
  'sWEdTGtBhTCDv5Pub0g3', 'jUWy7clszweND3V4jr0f',
  'AOiBOJMpdmXQPz8Kw7d6',                                                // probe 5
  'VRoP5nZal9EX0Th4Tpdm',                                                // demo lexicon
];

let ok = 0;
for (const id of IDS) {
  const res = await fetch(`https://api.elevenlabs.io/v1/pronunciation-dictionaries/${id}`, {
    method: 'PATCH',
    headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ archived: true }),
  });
  const body = await res.text();
  if (res.ok) {
    const j = JSON.parse(body);
    console.log(`  ${id} -> archived (archived_time_unix=${j.archived_time_unix ?? 'null'})`);
    ok++;
  } else {
    console.log(`  ${id} -> HTTP ${res.status}: ${body.slice(0, 160)}`);
  }
}
console.log(`\n${ok}/${IDS.length} archived.`);
console.log(ok === IDS.length
  ? 'Archiving WORKS -> per-book dictionaries are reclaimable; no shared mutable object needed.'
  : 'Archiving did NOT fully work -> the lifecycle question is still open.');
