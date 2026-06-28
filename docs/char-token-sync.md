# Char → token sync: design & algorithm

The deep dive on `ReaderCore/Sources/ReaderCore/CharTokenMapper.swift`. Read this
before changing the mapper. The one-paragraph version is in `CLAUDE.md`; this is
the *why* and the *how*, plus how to debug a bad capture.

## 1. The problem

ElevenLabs `with-timestamps` returns three parallel arrays:

```
characters:                    ["今","日","は","晴","れ"]
character_start_times_seconds: [0.00, 0.12, 0.24, 0.31, 0.42]
character_end_times_seconds:   [0.12, 0.24, 0.31, 0.42, 0.55]
```

`characters[i]` is voiced from `startTimes[i]` to `endTimes[i]`. That's
**per-character**. We want **per-word** spans to highlight, e.g. `今日` →
`[0.00, 0.24]`, `は` → `[0.24, 0.31]`, `晴れ` → `[0.31, 0.55]`.

Word boundaries don't exist in the text (no spaces), so they come from MeCab:

```
tokens: [今日(きょう), は, 晴れ(はれ)]   // surfaces: 今日 / は / 晴れ
```

The job: assign each token a `[start, end]` derived from the alignment chars it
covers. `start = min(startTimes over its chars)`, `end = max(endTimes over its
chars)`.

## 2. Why the naive approach is wrong

Every English tutorial does "split on spaces, then slice the timing arrays by
word length." For Japanese the naive analogue is positional slicing:

```
c = 0
for token of length L:
    start = startTimes[c]; end = endTimes[c + L - 1]; c += L
```

This assumes the API's `characters[]` equals the tokenized input **1:1**. It does
not, reliably:

- The API may **collapse or keep whitespace/control chars** the tokenizer dropped
  (or vice-versa) → indices drift by 1 and **every subsequent token is wrong**.
- **Punctuation** (、。「」) comes back as its own character with its own timing;
  MeCab may or may not make it its own token.
- **Surrogate pairs** (supplementary-plane kanji like 𠮷, emoji) are one Swift
  `Character` but can be one *or* a different number of array entries.
- **ElevenLabs language normalization** can rewrite numbers/dates/full-width forms,
  so `characters[]` ≠ what you sent unless you guard it.

A single off-by-one cascades. We need an alignment that **resynchronizes** after a
mismatch instead of trusting positions.

## 3. The algorithm (two-pointer tolerant alignment + clamp)

`CharTokenMapper.map(tokens:alignment:options:)`:

1. **Flatten** token surfaces into `(owningTokenIndex, Character)` pairs →
   `tokChars`. (So we always know which token a character belongs to.)
2. **Decode** alignment elements to `Character?` via `.first` (handles the empty
   strings the API occasionally emits; a surrogate-pair element is still one
   grapheme).
3. **Two pointers** `i` (over `tokChars`) and `j` (over alignment chars):
   - **Match** (`tokChars[i] == aChars[j]`): record alignment index `j` against
     token `tokChars[i].t`; advance both.
   - **Mismatch:** try to resync within a lookahead window `W` (default 8):
     - `aAhead` = does the token char appear soon *ahead in the alignment*? (the
       API inserted chars — e.g. a space/punctuation the tokenizer dropped) → skip
       the alignment forward to it.
     - `tAhead` = does the alignment char appear soon *ahead in the tokens*? (the
       API dropped chars present in the tokens) → skip the tokens forward to it.
     - both found → take the **smaller skip**; one found → take it; **neither** →
       treat as a substitution (pair them, advance both).
4. **Build spans:** per token, `start = min`/`end = max` of the `start/end` times
   of its matched alignment indices. A token that matched **nothing** gets `NaN`
   and is resolved next.
5. **Interpolate** `NaN` tokens: anchor `start` to the previous token's `end` and
   `end` to the next matched token's `start` (so a dropped/unvoiced token still
   gets a sane, zero-or-tiny interval in place).
6. **Monotonic clamp:** sweep so `start[k] ≥ start[k-1]` and `end[k] ≥ start[k]`.
   Token highlight times can then never run backwards even if raw timings jitter.

`matchedChars` on each `TokenSpan` records how many of the token's characters
actually matched — a built-in diagnostic. `matchedChars == surface.count` is a
clean token; `0` means fully interpolated.

### Complexity

O(N·W) worst case where N = total characters and W = lookahead — effectively
linear for the small constant W. Fine for chapter-sized text.

## 4. Gotcha → test matrix

Each row is an adversarial unit test in `CharTokenMapperTests.swift`, constructed
to fail the naive approach and pass the two-pointer one:

| Gotcha | Test | What it proves |
|---|---|---|
| Clean 1:1 | `testCleanMapping` | baseline: 食べ/ます tile correctly |
| Punctuation as own char | `testPunctuationAttachedToOwnToken` | 、 keeps its own timing on its own token |
| API kept whitespace tokenizer dropped | `testAlignmentHasExtraWhitespace` | extra alignment space is skipped, は still aligns |
| API dropped a token's char | `testTokensHaveCharDroppedByAPI` | unmatched token interpolates between neighbours |
| Surrogate-pair kanji | `testSurrogatePairKanji` | 𠮷 stays one unit, stream doesn't desync |
| Non-monotonic raw times | `testMonotonicClamp` | clamp keeps starts non-decreasing |
| NFKC folding | `testNFKCNormalizationFoldsZenkaku` | full/half-width + zenkaku digits fold |
| Empty input | `testEmptyTokens` | degenerate case returns [] |

`MeCabTokenizerTests.swift` then proves the two real-data preconditions: MeCab
**surfaces reconstruct the NFKC input 1:1** (`testSurfacesReconstructInput`) and
MeCab tokens **tile a clean alignment with no gaps**
(`testMeCabIntoMapperCleanAlignment`).

`AlignmentFixtureTests.swift` is the real proof on captured ElevenLabs data
(auto-skips until a fixture exists).

## 5. Tuning knobs

- **`Options.lookahead`** (default 8): how many characters ahead, on each side, the
  resync search scans. Larger tolerates bigger insert/drop runs (e.g. a long
  number expanded by language normalization) at O(N·W) cost. If real captures show
  desync after a specific construct, widen it before anything else.
- **Normalization**: the single biggest lever. Both sides must be NFKC and you must
  decide whether to let ElevenLabs apply *language* normalization
  (`apply_language_text_normalization`, JP-only, expands numbers/dates but raises
  latency). For sync fidelity, prefer sending already-normalized text and reading
  `alignment` (original); for a number-heavy corpus, consider tokenizing the *same*
  string the API normalized to.

## 6. Debugging a bad capture

When `AlignmentFixtureTests` fails or coverage is low, in order:

1. **Read the printed span table.** The test dumps `start–end surface (reading)`
   for the first 60 tokens. The first token whose time looks wrong marks where the
   two streams desynced.
2. **Normalization mismatch?** Confirm the capture script NFKC-normalized (it does)
   *and* that `MeCabTokenizer.tokenize` did (it does). If you added a path that
   skips one, fix it.
3. **`alignment` vs `normalized_alignment`?** The script saves `alignment`. If you
   switched it, indices now track normalized text the tokenizer never saw.
4. **Language normalization rewrote the text?** Numbers/dates/full-width. Either
   disable it on the request or tokenize the normalized string.
5. **Lookahead too small?** Widen `Options.lookahead`, re-run.
6. **Genuine tokenizer/engine disagreement?** Inspect `matchedChars` per token; the
   low ones localize the problem token. IPADic homograph/segmentation quirks are
   expected on some words — the research doc recommends a small hand-maintained
   reading-override table for the worst offenders (not yet built).

## 7. Deliberately out of scope (for the spike)

- A full edit-distance / LCS alignment. Greedy two-pointer + bounded lookahead
  handles real divergences and is O(N·W); only escalate if captures prove it
  insufficient.
- Sub-character (per-mora) highlighting. Token granularity is the product goal.
- Reading-override table for homographs (research doc §5) — a Phase-5 polish, not a
  sync concern.
