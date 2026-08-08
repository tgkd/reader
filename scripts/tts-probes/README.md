# TTS probes

Throwaway-looking scripts that are not throwaway: each one answers a question about
ElevenLabs' behaviour that its documentation does not, and several of the answers were
surprising enough to change the design. They are kept so the next person does not re-derive
them, and so a claim can be re-checked when upstream changes.

Findings live in `docs/2026-08-07-pronunciation-dictionaries.md`; this is the apparatus.

## Running

Needs `ELEVEN_KEY` in the repo's `.env` (same file `capture-alignment.mjs` reads).

```bash
node scripts/tts-probes/<probe>.mjs
```

Output goes to `scripts/tts-probes/out/` unless `PROBE_OUT` says otherwise. That directory is
gitignored: the probes generate audio, and some of them read copyrighted book text.

Some probes take input through the environment rather than arguments, so a path with spaces or
a `!` cannot be mangled by a shell:

| variable | used by |
|---|---|
| `PROBE_TEXT` | a chapter to synthesize — `model-alignment-repeat`, `lexicon-end-to-end`, `lexicon-excerpt`, `build-sync-viewer` |
| `PROBE_RULES` | a JSON array of `{string_to_replace, alias}` — `lexicon-end-to-end` |
| `PROBE_OUT` | where audio and pages are written |
| `AIWORK_DEV_VARS` | path to aiwork's `.dev.vars` — `gateway-management` only |

To get a real rule set out of a real book, run the app-target probe and keep the `LEXJSON`
line:

```bash
TEST_RUNNER_YOMI_EPUB=<book.epub> xcodebuild test -project app/Reader.xcodeproj \
  -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath app/build -only-testing:ReaderTests/RealBookLexiconProbe
```

The `TEST_RUNNER_` prefix is load-bearing. Without it the variable never reaches the test
process, the probe skips, and the run still reports success.

## What each one settles

**`alias-fires`** — whether an alias rule matches inside continuous Japanese. It does, but only
with `word_boundaries: false`; at the default it is a silent no-op, which is indistinguishable
from the model having read the name correctly. Includes a Latin control, without which "did not
fire" and "fired but changed nothing" are the same measurement.

**`alias-alignment`** — what `alignment.characters` contains when a rule fires. The original
submitted text, with the aliased characters absorbing the spoken alias. This is the fact the
whole feature rests on: it means `CharTokenMapper` and `ContentKey` need no changes.

**`alias-collision`** — whether a rule fires *inside* a longer word. It does, at any position,
and a realistic collision is subtle enough to pass unnoticed on listening. This is why the
lexicon builder has an occurrence gate.

**`dictionary-versioning`** — whether a pinned version keeps working after the dictionary is
updated. It does, over one mutation; long-term retention is still unmeasured.

**`locator-failure`** — what a bad locator does. An archived dictionary, an unknown id and a
stale version all return **404 with no audio**. Since the locator rides on every reader
request, that is a total narration outage, which is why the Worker drops the locator and
retries.

**`gateway-management`** — whether Cloudflare's AI Gateway forwards ElevenLabs *management*
endpoints, not just inference. `GET` and `POST` both do, on the gateway credential alone, so
the Worker can create a book's dictionary itself. `PATCH` (archive) is still untested, which
only matters if reclamation is ever automated — §10 argues it should not be.

**`config-matrix`** — voice against `voice_settings` against `language_code`, one variable at a
time. Written after a playground result disagreed with a production one and three things
differed at once.

**`voice-sweep`** — every catalog voice on a name-dense sentence. Voice does not rescue an
irregular proper noun, but it does change ordinary words.

**`model-alignment-repeat`** — the same chapter through the same model N times. `eleven_v3`
fails the client's 1 s alignment guard on roughly three runs in four, which a single
measurement had missed entirely.

**`lexicon-end-to-end`** — a real rule set uploaded as a real dictionary, narrating a real
chapter. The whole chain.

**`full-set-equivalence`** — whether attaching a book's WHOLE lexicon narrates a chapter
differently from attaching only the rules that occur in it. It does not, across two books and
21 runs. This is the gate for the per-book identity change (§12): the whole design rests on
absent rules being inert, which is an inference about ElevenLabs' matching rather than a
documented contract. Takes `PROBE_RUNS`; **use at least 4.** At n=2 it once reported a
regression that vanished at n=6 — a two-sample spread is not a variance estimate, and this
script will happily print a verdict from one.

**`alias-chaining`** — whether a rule can fire on text another rule produced. It cannot. This is
the one hole in the inertness argument above, and it is closed with a decoy long enough to be
unmistakable in the duration, plus a control proving the decoy is audible when its surface really
is present.

**`archive-dictionaries`** — cleanup. Dictionaries cannot be deleted, only archived, and an
archived one 404s at synthesis, so archive nothing that anything might still pin.

## Cost

Everything here spends real money, billed per character of submitted text:
**$0.05 per 1,000 characters on flash**, $0.10 on multilingual/v3.

A 4,000-character chapter is **$0.20 per run**, so anything that repeats a chapter adds up fast:
`full-set-equivalence` at 3 arms x 3 runs is ~$1.80, and `model-alignment-repeat` at five runs is
~$1.00. The short synthetic probes (`alias-fires`, `alias-collision`, `alias-chaining`) are
fractions of a cent. Read the script and do the arithmetic before running it.

Prices are per model, so re-check them against `TTS_MODEL` rather than carrying a $/hour figure
across a model change — narration used to cost twice this on the multilingual rate.
