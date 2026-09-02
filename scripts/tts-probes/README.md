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
| `PROBE_TEXT` | a chapter to synthesize — `model-alignment-repeat`, `lexicon-end-to-end`, `lexicon-excerpt`, `build-sync-viewer`, `v3-conversational-compare` |
| `PROBE_RULES` | a JSON array of `{string_to_replace, alias}` — `lexicon-end-to-end` |
| `PROBE_OUT` | where audio and pages are written |
| `PROBE_VOICE` | voice id to narrate with — `v3-conversational-compare` |
| `PROBE_RENDER_ONLY` | rebuild a probe's page from audio already on disk, spending nothing — `v3-conversational-compare` |
| `AIWORK_DEV_VARS` | path to aiwork's `.dev.vars` — `gateway-management` only |

To get a real rule set out of a real book, run the app-target probe and keep the `LEXJSON`
line:

```bash
TEST_RUNNER_YOMI_EPUB=<book.epub> xcodebuild test -project app/Reader.xcodeproj \
  -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath app/build -only-testing:ReaderTests/RealBookLexiconProbe
```

The `TEST_RUNNER_` prefix used to be load-bearing, and **on Xcode 27 it no longer works at all**:
measured 2026-08-27, the variable does not reach the test process, `RealBookLexiconProbe` and
`RealBookRubyProbe` both `XCTSkip`, and the run still reports **TEST SUCCEEDED**. A skipped probe
is indistinguishable from a passing one unless you read the log for `Test skipped`.

Until the injection is fixed, drive these probes from a test that reads the bundled books through
`StarterLibrary` instead of an environment variable — `RubyCoverageProbe` does that and runs
without any env at all.

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

**`build-model-demo`** + **`render-model-demo`** — the listening harness. Nine texts (eight
recorded misreadings from `docs/2026-08-03-findings.md` §4, plus 200 characters of continuous
prose) x five configurations: `multilingual_v2` as production sends it, the same plus the alias
lexicon, `v3_conversational` (0.5x, never auditioned), `eleven_v3`, and `flash_v2_5` as the audio
older users already have cached. Everything but the model and the dictionary matches production.
`build-` spends money and writes `audio/` + `cases.json`; `render-` turns that JSON into
`index.html` and is free, so the page can be reshaped without re-billing. Measurements alone
cannot answer whether narration got BETTER — that needs ears, and this is what they listen to.

First run, 2026-08-26: `eleven_v3` cleared all eight short cases (max 0.050 s undescribed) and
then left **1.952 s undescribed on the 200-character prose sample** — above the client's 1.0 s
guard, i.e. a chapter the app would refuse after paying for it. Length and blanks trigger the
defect; names never did.

**`build-ruby-loss-demo`** + **`build-ruby-ctx-arm`** + **`render-ruby-loss-demo`** +
**`render-ruby-verdict`** + **`transcribe-arms.py`** — the harness that settled whether publisher
ruby the lexicon *cannot* send is audibly lost, and whether a contextual base fixes it. `build-` takes
the `LOSSJSON` dump from `RubyCoverageProbe` and synthesizes two arms per case (production, and the
same sentence with the target replaced by its kana); `build-ruby-ctx-arm` adds a third arm through a
real ElevenLabs dictionary of contextual bases plus a phrase-level reference; `render-` are free and
reshape the pages without re-billing. `transcribe-arms.py` runs Whisper large-v3 locally over every
clip.

First run, 2026-08-27, 36 sampled cases: **33 of 35 valid pairs audibly different**, so the tail is
real. With contextual bases, the reading appeared where it had been absent in **28 of 28** cases that
needed it, and **nothing was broken** — 30 cases decided by transcript comparison, 6 by ear.

Two things that made the transcription usable. Whisper is a **differential instrument**: one model
mistakes three clips of one sentence the same way, so a difference between transcripts is evidence
about pronunciation even when no transcript is correct. And the hiragana `initial_prompt` is
load-bearing — without it Whisper normalizes to kanji and erases exactly what is being measured.

**`v3-conversational-compare`** — whether `eleven_v3_conversational` can replace `eleven_v3`, which
is what `TTS_MODEL` names today. It costs half as much per character ($0.05 against $0.10), and the
question was whether the reader can use it at all: it is documented as tuned for realtime
conversation, and the whole one-chapter-one-request rule was derived from v3's own alignment
defects. Measured over 989 characters of book prose, one request each: it accepts
`with-timestamps` and describes every character, its unlabelled tail is 0.022 s against v3's
0.076 s, it speaks at the same pace (6.70 against 6.54 chars/s), and it generates 3.6x faster
(16.2 s against 58.1 s of wall time for ~150 s of speech). Nothing there says how it *reads* —
that is the listening page it writes, which drives a per-character highlight off each model's own
alignment so a sync difference is visible rather than argued about.

**And the page immediately found one, which is why conversational is not a recommendation.** Over
one run of four short quoted lines (`その曲、やめて` / `え?` / `ダフニスとクロエ。嫌い` /
`あ、すみません`), conversational's alignment places `ダフニスとクロエ。嫌い` at 46.40-47.15 s —
a window that is a measured 0.60 s of SILENCE in its own audio (pauses at 45.46-45.86,
46.46-47.06, 49.18-49.80; the line is really spoken in the 47.06-49.18 run) — and gives
`あ、すみません` 0.28 s for nine characters. From there the alignment runs ~2.3 s ahead of the
audio and reabsorbs the error across the following 128-character paragraph, which it starts at
47.52 s against a real 49.80 s and still ends within 0.16 s of the truth. A highlight driven by
it leads by two seconds and then slides back — visible on the page, and the reason this was not
caught by the tail measurement, which only looks at the END of the request.

v3's alignment over the same four lines is exact: every line boundary lands within ~0.1 s of a
real pause (`ダフニスとクロエ。嫌い` 45.88-47.68 against a speech run of 45.96-47.68). So on this
sample the cheaper model buys its half-price and 3.6x speed with the defect the expensive one no
longer has, mid-chapter rather than at the tail. Also still unmeasured: the truncation ceiling
(v3 stops at a measured 546-556 s regardless of submitted length; `TTS_MAX_REQUEST_CHARS` simply
assumes the same 1500 for conversational) and behaviour on name-dense text.

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

**`collapse/`** — where `eleven_v3`'s undescribed time actually sits. `pause-lag.py <mp3>
<alignment.json>` compares the audio's speech envelope with the alignment's predicted one and prints
the best lag per 20 s window: a step from ~0 to +1.9 s at 260 s on `names-cap1500-s01` located a
15-character phrase the alignment had given 0.16 s. `repair-sim.py <mp3> <alignment.json>
[anchors.json]` finds interior collapsed runs, stretches them to absorb the residual, and scores the
result against Whisper word anchors (`{"charIdx": whisperStart}`). `words.py <wav> <t0> <t1>
[offset]` dumps Whisper words with timestamps in a window (run with
`uv run --with faster-whisper`). Findings in
`.claude/notes/investigations/2026-09-02-v3-collapses-a-spoken-phrase-mid-request.md`. Do not trust
a naive word-in-text anchor matcher over a whole 1500-char file — it cascades onto the wrong
occurrence; anchor over a 90 s window.
