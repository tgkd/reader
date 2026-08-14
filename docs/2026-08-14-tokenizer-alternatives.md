# Tokenizer: what is actually broken, and what to do about it

*2026-08-14. Everything with a number attached was measured on this machine (macOS arm64,
Swift 6.4 / Xcode 27.0.0 Beta 5, Mecab-Swift 0.8.0 @ `1f09649`, IPADic as bundled). The corpus
is `samples/こころ（夏目漱石）.epub` — 165,665 NFKC chars, 486,171 UTF-8 bytes, 3,462 lines.
Method is in the appendix. The probes were throwaway and have been removed from the repo, so
these figures are re-derivable but not currently auditable — §5 stage 1 says which of them
should become permanent tests.*

---

## Verdict first

**Two faults, stacked — and only one of them is MeCab's.** Mecab-Swift throws away the byte
offsets MeCab hands it for free and re-finds every token with `String.range(of:)`. Where that
search fails the token is deleted with no error. It fails where MeCab splits inside a Swift
grapheme cluster, which in practice means Ideographic Variation Sequences — and MeCab
*also* mis-segments those, because it predates them.

**On clean text the wrapper loses nothing**, and the report should not imply otherwise: it
produced the same 105,763 nodes as the raw C API on the corpus, and the character-coverage
shortfall it shows (165,665 − 160,831 = 4,834) is exactly the byte shortfall MeCab itself
shows (486,171 − 481,337 = 4,834) — the same dropped whitespace counted in different units,
which our gap-token logic restores. What the wrapper costs on clean text is **speed**; what it
costs on IVS text is **readings** — MeCab's, and the book's own, and the narration's (§2.3).

So: **do not switch engines. Replace the wrapper.** A direct binding to the MeCab C API,
prototyped and measured below, is **2.8x faster end to end** and produces an identical token
stream on clean text (identical token count, identical lemma count, **zero** differing kanji
readings). It must ship together with variation-selector projection (§5) — byte offsets alone
break a character-count invariant the current code depends on. The engine, the dictionary,
`SpanTimeline` and the `CLAUDE.md` invariants are unaffected.

The alternatives are real but none of them beats that trade. Details in §4.

---

*Reviewed 2026-08-14 by a second model (`gpt-5.6-sol`) and a verification pass over the code.
Four claims in the first draft were wrong and are corrected in place: the misleading coverage
juxtaposition above, "silently" in §3.6, a false statement about `import mecab` in §5, and a
staging plan that would have shipped a broken invariant. Stage 0 and §6 are new.*

*Re-reviewed 2026-08-14 against the source, on the same toolchain and pin. Every file:line
citation resolves; the `sys.dic` section table, the 22-of-28 source count, the fixture inventory
and the 154-test suite all re-derive exactly; the IVS failure reproduces at the `MeCabTokenizer`
layer. Three substantive changes came out of that pass — the snap-to-grapheme repair in §5
stage 1, because the strip list did not cover §2.2's own example; the exit criterion of stage 0,
which pointed at options §4 had already disqualified; and §2.3, which is new: the same fault
silences the book's own ruby and the pronunciation lexicon. The stage 1 work order is new too.*

*Amended again as stage 1 commits 1–2 were built, 2026-08-14. Two claims did not survive contact
with the work and are corrected in place: §3.3's eight training-only files are **not** droppable
(`Dictionary::compile` shares a translation unit with `Dictionary::open`), and the staged
migration cannot keep both engines alive at once — they collide at link. The packaging decision
also moved from forking to vendoring; §5 records why.*

---

## 1. What the app actually needs

Narrow, and worth stating because it disqualifies most of the field:

| Need | Consumer | Currently from |
|---|---|---|
| Token boundaries whose surfaces rejoin to `nfkc(text)` **exactly** | `CharTokenMapper` → highlight sync | `annotation.range` + gap-filling |
| Kana reading per token | furigana | IPADic feature field **7** (読み) |
| Kanji lemma per token | tap-to-define | IPADic feature field **6** (原形) |
| Runs off the main actor, one pass per chapter | `TokenizerWorker` | actor serialisation |
| Works offline, free, no entitlement | the free-reading invariant | bundled 51 MB dictionary |

Note what is *not* needed: part of speech, conjugation type, pronunciation (発音), n-best
lattices, or anything else. **We read 2 of IPADic's 9 feature fields.** That fact reappears
in §3.4.

---

## 2. The bug: tokens are silently deleted

`Tokenizer.mecabTokenize` (Mecab-Swift, `Sources/Mecab-Swift/Tokenizer.swift`):

```swift
if let foundRange = text.range(of: searchString, options: [], range: searchRange, locale: nil) {
    let annotation = Annotation(token: token, range: foundRange, transliteration: transliteration)
    annotations.append(annotation)
    if foundRange.upperBound < text.endIndex {
        searchRange = foundRange.upperBound..<text.endIndex
    }
}
```

MeCab already gives the answer: `node.surface` is a pointer *into the input buffer* and
`node.length` is its byte length. Subtracting the base pointer is the exact offset, for free.
Instead the wrapper reconstructs the token as a Swift `String` and searches for it.

`String.range(of:)` matches on **grapheme-cluster boundaries**. MeCab does not know about
grapheme clusters — it was released in 2013, before Unicode had variation sequences in wide
use. When MeCab splits inside a cluster, the search cannot succeed, the `if let` fails, and
**the token vanishes with no error**. Our `MeCabTokenizer` then sees the hole, emits the text
as an untimed gap token, and the lossless invariant survives — so the failure is invisible
except as *missing furigana*.

### 2.1 Ideographic Variation Sequences — the real-world trigger

IVS (U+E0100–U+E01EF) is how modern commercial EPUBs pin the intended glyph of a name kanji —
辻󠄀, 葛󠄀, 舘󠄁 — a base character followed by an invisible selector. (Note 﨑 and 邊 are *not*
variation sequences: they are separate compatibility/traditional codepoints and tokenize
normally. It is the selector, not the unusual glyph, that causes this.) Exactly the characters
a reader most wants furigana on.

Input `葛\u{E0100}城さんは辻\u{E0101}さんと嵜\u{E0100}玉に行った。` (16 grapheme clusters):

| layer | result |
|---|---|
| MeCab, raw C API | 16 nodes, **60 of 60 bytes covered** — `葛@0+3/カズラ`, `\u{E0100}@3+4`, `城@7+3/ジョウ`, … |
| Mecab-Swift | **10 annotations, 13 of 16 chars.** `葛`, `辻`, `嵜` gone. Output begins `城/ジョウ` |
| Same text, selectors stripped first | `葛城/カツラギ`, `さん`, `は`, `辻/ツジ`, … — **correct** |

That table reads at the *wrapper* layer. At the layer the app sees, `MeCabTokenizer`'s
gap-filling turns the same input into **13 tokens covering all 16 chars**, with `葛󠄀`, `辻󠄁` and
`嵜󠄀` arriving as their full grapheme — base plus selector — carrying no reading and no lemma.
That is why `MeCabTokenizerTests` is green while the page is wrong: the text is all there, and
only the readings are gone.

Two distinct faults, stacked:

1. **MeCab treats the selector as its own token**, which breaks the compound: 葛城 (かつらぎ)
   becomes 葛 + selector + 城, and 城 is then read ジョウ. A correct wrapper does *not* fix this.
2. **The wrapper then deletes the orphaned kanji**, so the page shows a bare 葛 with no ruby
   and the word beside it ruby'd wrong.

At scale — 38 selectors injected into 20,032 chars of the corpus:

| | tokens | with reading |
|---|---|---|
| clean | 12,774 | 12,650 |
| with IVS | 12,788 | **12,626** |

**24 words lost their reading and 14 more were re-segmented, from 38 selectors.** Roughly
0.6 lost readings per selector, concentrated on proper nouns. This is a plausible answer to
"it doesn't work well all the time": it works fine on Aozora, and degrades on the modern
commercial books users actually import.

### 2.2 The other latent hazard

Any combining mark surviving NFKC has the same shape. A synthetic `が\u{3099}っこうへ行く。`
lost a **five-character run** to one stray combining dakuten — 2 annotations covering 3 of 8
chars, which reaches the app as one 5-character `が゙っこうへ` token with no reading at all. NFKC
composes the ordinary cases, so this is a corner, not a headline — but it is the case that
decides the shape of the fix in §5, because it splits a grapheme cluster with no variation
selector anywhere in it. Non-BMP kanji
(𠮟, 𩸽) are **fine** — full coverage, correctly no reading, because IPADic's 2007 vocabulary
has no entry. That is a dictionary-age issue, not a wrapper bug, and our `usableReading`
already rejects the surface fallback.

### 2.3 The same fault silences the book's own ruby — and the narration lexicon

This is what makes the bug worse than "missing furigana", and the first two drafts missed it.

`SourceReadingOverlay.bookReadings` attaches a publisher reading to a token only when the
annotation tiles that token exactly: a hit must satisfy `hit.end <= end`, and any remainder must
be kana or the whole token is refused (`SourceReading.swift:98-113`). A commercial EPUB rubies
葛城 as one group. The tokenizer hands back `葛󠄀` | `城`. The annotation overshoots token 0, and
token 1 begins *inside* the annotation on a non-kana character — so **neither token matches, and
the reading the publisher printed is dropped along with MeCab's**.

`PronunciationLexicon.tokenSpans` (`:183`) is built from the same `bookReadings`, so no rule is
minted for that name either. The complete failure on one IVS name is therefore: no furigana on
the name, *wrong* furigana on the word beside it, and a narration that mispronounces the name the
book had spelled out — precisely the case `PronunciationLexicon` exists to serve, defeated
before it runs.

It also constrains the repair. The projection must re-attach the selector to its base kanji
**inside `Token.surface`**, never strip it: `bookReadings` gates on
`Normalize.nfkc(surface) == token.surface` (`:113`), so a stripped surface stops matching the
book's own annotation and trades one silent drop for another.

---

## 3. The rest of the bill

### 3.1 A 5x tax for the re-search

Same corpus, same node count (105,763 — the wrapper is not losing anything on *clean* text,
only paying for it):

| | time |
|---|---|
| MeCab C API, parse + byte offsets | **76.4 ms** |
| Mecab-Swift `tokenize` | **377.7 ms** |
| `ReaderCore.MeCabTokenizer` end to end | 402.9 ms |

**4.94x.** Per token the wrapper does a `Data` copy, a `String(data:)`, a full `String` split
of the 9-field feature blob into `[String]` (to read 2 of them), and a Unicode-aware substring
search. That is ~5 heap allocations per token, ~530,000 for a book.

### 3.2 Maintenance

| | last functional change | notes |
|---|---|---|
| Mecab-Swift | **2024-05-14** (2025-03-31 was "fixed test") | 48 stars, 52 commits, MIT |
| MeCab core | **0.996, 2013-02-18** | upstream unmaintained; forks exist (`shogo82148/mecab`) |
| IPADic | **2007** | frozen |

The user's read is correct — but note the direction of the risk. MeCab is a finished,
dependency-free C++ program with a stable ABI; "unmaintained" for it mostly means "done".
The wrapper is where the defects live and where nobody is looking.

### 3.3 Dead weight in the build — real, and **not** droppable

The `mecab` target compiles **22 of 28** `.cpp` files. Eight of them — `learner.cpp`,
`lbfgs.cpp`, `feature_index.cpp`, `dictionary_compiler.cpp`, `dictionary_generator.cpp`,
`dictionary_rewriter.cpp`, `context_id.cpp`, `eval.cpp` — are model *training* and dictionary
*building*, and nothing a runtime tokenizer calls reaches them. That is most of the ~1 min cold
compile.

**The first draft concluded they could therefore be dropped. They cannot**, and this was settled
by trying it while vendoring (2026-08-14). `Dictionary::compile` is defined in `dictionary.cpp`,
the same translation unit as `Dictionary::open`, so the runtime object carries undefined
references to `ContextID`, `DictionaryRewriter`, `POSIDGenerator` and `FeatureIndex` whether or
not anything calls them — and the linker resolves symbols before it dead-strips. Excluding all
eight leaves 14 unresolved; putting `context_id` / `dictionary_generator` / `dictionary_rewriter`
back still leaves 6, all `FeatureIndex`, wanted by `dictionary.o` itself; `feature_index` then
pulls `learner_tagger` behind it. The only way to actually shed them is to patch `dictionary.cpp`
— a permanent divergence from a frozen upstream in exchange for compile time. Not taken. The
vendored target builds the same 22 files upstream does, and links with **zero** unresolved
symbols.

### 3.4 51 MB, two thirds of it payload we never read

`Reader.app` (Debug, iphoneos) is 151 MB: `Reader.debug.dylib` 55 MB,
`Mecab-Swift_IPADic.bundle` **51 MB**, `jisho-compact.db` 43 MB.

Parsing `sys.dic`'s header (49,199,027 bytes, 392,126 entries):

| section | bytes | share |
|---|---|---|
| double-array trie | 11,426,584 | 23.2 % |
| token array | 6,274,016 | 12.8 % |
| **feature blob** | **31,498,355** | **64.0 %** |

80 bytes of feature string per entry, of which we read fields 6 and 7. Download cost is
smaller than it looks — `sys.dic` gzips to 11.9 MB (24 %) — but installed footprint is real.
See §5, stage 2.

### 3.5 What is *not* wrong — corrections to `CLAUDE.md`

- **"the one-time ~50 MB IPADic load"** — there is no eager read. Opening the dictionary is
  **1.75 ms**; MeCab `mmap`s it. First-touch page faults are still real I/O (the first parse
  cost ~8 ms more than the second on 3,960 chars, warm), so the cost is not zero — it is just
  paid lazily and per page, not as a 50 MB load. Measured warm on macOS; this says nothing
  about a cold iOS launch. Moving off the main actor was still right.
- **"MeCab is not thread-safe"** — true of `mecab_sparse_tonode` on a shared tagger, which is
  the only API the wrapper exposes. MeCab's `mecab_model_new2` / `mecab_model_new_tagger` /
  `mecab_model_new_lattice` / `mecab_parse_lattice` path *is* safe for concurrent use over one
  shared dictionary, and I verified it works against our IPADic. The actor can stay for
  serialisation-by-design, but it is no longer forced by the engine.
- **Reading field choice is already correct.** IPADic field 7 (読み) is used, not field 8
  (発音). 発音 would give トーキョー / ワ for は — right for a TTS engine, wrong for ruby.

### 3.6 Two failure modes, and only one of them is visible

Worth separating carefully, because they are easy to conflate:

**Total init failure is visible.** `MeCabTokenizer.tokenize` returns a non-optional `[Token]`
(`JapaneseTokenizer.swift:16`), so `TokenizerWorker.tokenize` (`:8`) returns `nil` *only* when
`tokenizer` itself is nil — i.e. `try? MeCabTokenizer()` failed. `ReaderModel.load()` then sets
`loadState = .failed(L10n.readerFailedTokenizer)` (`:122`), rendered as a placeholder at
`ReaderView.swift:87`. So this case is not silent — and it is worse than "furigana stops
working": `load()` returns before `loadState = .ready`, taking down the whole reading surface.

**The per-token drop is silent, and that is the bug this report is about.** A dropped
annotation never produces a nil; the gap-token logic patches the hole and a full array is
returned, so `loadState` is always `.ready` and individual words quietly lose their furigana.
There is no state, no log, and no way for a user to report it as anything but "the readings are
sometimes missing".

Three smaller things in the same area:

- `TokenizerWorker` latches `initAttempted` and swallows the error with `try?` — no diagnostic,
  and no retry for a transient failure.
- `TokenizerWorker.readings(of:)` (`:24-31`) returns `nil` per surface on any mismatch, which
  silently weakens `DocumentLexicon` corroboration. Nothing surfaces this either.
- `IPADic.swift:19` force-unwraps `Bundle.module.url(...)!`, and `MeCabTokenizer.init`
  evaluates `IPADic()` before `try` — so a missing dictionary resource **traps**. It never
  reaches `try?`, and the visible `.failed` path above never runs.

---

## 4. Alternatives surveyed

| Option | Boundaries | Reading | Lemma | Installed | Build cost | Verdict |
|---|---|---|---|---|---|---|
| **Fix the wrapper, keep MeCab + IPADic** | ✅ byte-exact | ✅ | ✅ | 51 MB | none new | **Recommended** |
| Apple `NaturalLanguage` / `CFStringTokenizer` | ✅ good | ⚠️ via romaji | ❌ **none** | 0 MB | none | Fallback only |
| Vibrato (Rust) | ✅ | ✅ | ✅ | ≥ MeCab | Rust + XCFramework | No upside |
| Lindera (Rust) | ✅ | ✅ | ✅ | ≥ MeCab | Rust + XCFramework | No upside |
| Jagger (C++) | ✅ | ✅ | ✅ | ~30 MB RSS | model licence blocked | Park |
| sudachi.rs | ✅ | ✅ | ✅ | large | Rust + XCFramework | Only if vocabulary binds |
| Server-side tokenize | ✅ | ✅ | ✅ | 0 MB | Worker work | **Breaks free offline reading** |

### 4.1 Apple's frameworks — verified, and it settles the question

`NLTagger.availableTagSchemes(for: .word, language: .japanese)` returns exactly:

```
["Language", "Script", "TokenType"]
```

**No `Lemma`. No `LexicalClass`.** Confirmed by running it: every `.lemma` tag on Japanese
comes back `nil`, every `.lexicalClass` comes back `OtherWord`. Tap-to-define is keyed on
`dictionaryForm`, so `NaturalLanguage` cannot be the primary tokenizer. Not a documentation
gap — the capability is absent.

`CFStringTokenizer` with `ja_JP` is better than expected. Boundaries are sane and
`kCFStringTokenizerAttributeLatinTranscription` round-trips through `.latinToKatakana`
surprisingly well: 今日→キョウ, 学校→ガッコウ, 大きい→オオキイ, 行っ→イッ. But:

- **No lemma at all.**
- Readings are **romaji-mediated**, so they inherit every romanisation ambiguity, and the
  transcription is Apple's private behaviour with no contract.
- Proper nouns are worse than MeCab: `黄前久美子` → `黄/コウ` + `前久/サキヒサ` + `美子/ヨシコ`.

Real use: a **zero-cost fallback** if `MeCabTokenizer` init ever fails (§3.6) — degraded
furigana beats a blank reading surface. Not a replacement.

### 4.2 Vibrato / Lindera (Rust, MeCab-compatible)

Both are honest, MIT/Apache-2.0, actively developed reimplementations, and both would fix the
offset problem by construction. Neither is worth it here:

- They solve a problem we do not have. Our parse is **76 ms per book**; the wrapper is the
  cost, not the engine.
- They add a Rust toolchain, cross-compilation for three Apple targets, `lipo`, an XCFramework
  and a checksum step to a build that currently has none of that — including in Xcode Cloud,
  where `ci_post_clone.sh` would have to bootstrap Rust.
- **No size win.** Vibrato's UniDic models run 248–717 MB; its IPADic model is not smaller than
  MeCab's, because it is the same lexicon.
- Neither ships Swift bindings (Python and WASM only), so we would own the FFI layer anyway —
  the same ~120 lines recommended below, plus a toolchain.

### 4.3 Jagger — the interesting one, blocked on licensing

Pattern-based, deterministic, MeCab-format output *including readings and lemmas*, no
third-party dependencies, conservative C++, triple-licensed GPLv2 / LGPLv2.1 / **BSD**. Its
author reports 23–56x faster than MeCab/Vibrato/Vaporetto at 1/2–1/25 the memory, ~30 MiB
resident. On paper it is strictly better than what we run.

The blocker is the **model**, not the code. The only published model is KWDLC-trained, 262 MB,
and its own binding's README says the licence and terms of use are unclear. A permissively
licensed IPADic- or UniDic-trained model would have to be built by us — a training exercise
against a corpus, then a full re-validation of `CharTokenMapper`, the furigana overlay and
every committed alignment fixture, because segmentation would shift.

**Park it.** Revisit if a permissively licensed UniDic model appears, or if install size
becomes the binding constraint.

### 4.4 Server-side tokenisation

`docs/webapp.md` already proposes this for web, correctly. For iOS it is disqualified by a
product invariant, not a technical one: **reading extracted text is free, ungated and
offline**. Tokenising on the Worker puts furigana and tap-to-define behind the network and
arguably behind the entitlement. Not a candidate.

---

## 5. Recommendation

### Stage 0 — measure the real failure rate (cheap, and it gates everything below)

Neither this report nor the review that followed it established that IVS is what users are
actually hitting. The IVS numbers come from *injection* into a clean Aozora text; they prove
sensitivity, not prevalence. Kokoro contains zero variation selectors and zero non-BMP
characters — typical of public-domain sources, and not of the commercial EPUBs users import.

The decisive measurement needs no fork and no new library: over the real library, count tokens
where `reading == nil` **and** the surface contains an ideograph — that is exactly the
"missing furigana" symptom — and cross-check against the raw C node count for the same text.
Wrapper loss and IPADic OOV then separate cleanly: the wrapper loses nodes MeCab produced, the
dictionary produces nodes with no reading, and `node.stat == MECAB_UNK_NODE` gives the second
directly.

If node loss dominates, stage 1 is the whole fix. If OOV dominates, the answer is a
**dictionary** — and §4 does not contain it. Vibrato and Lindera run the same IPADic lexicon
(§4.2), so they cannot close a vocabulary gap, and §4.4 is refused on a product invariant that
prevalence does not touch. The real options in that branch are UniDic (larger, and its
short-unit-word segmentation fragments compounds, so every committed fixture would churn), a
small bundled user dictionary of proper nouns, or accepting it. One shortcut that looks obvious
is already closed: `jisho-compact.db` cannot serve as a reading fallback — 203,627 entries, one
kanji headword each and no JMnedict, so 葛城, 久美子 and 黄前 all miss and even 吾輩 is stored
only as 我輩. Stage 1 stays worth doing in that branch for the speed and the lost readings, but
it would not be the answer to the complaint.

### Stage 1 — replace the wrapper *and* project selectors, as one release

Bind the MeCab C API directly in `ReaderCore`, using `node.surface` offsets. Prototyped and
measured against the current path on the full corpus:

| | current | direct | |
|---|---|---|---|
| end to end | 391.8 ms | **142.2 ms** | **2.76x** |
| tokens | 106,569 | 106,569 | identical |
| lemmas | 105,056 | 105,056 | identical |
| **kanji readings differing** | — | — | **0** |
| lossless invariant | holds | holds (3,462 lines) | |

517 tokens (0.49 %) differ, **all** kana or punctuation, all from one deliberate divergence:
MeCab's OOV fallback where `Token.reading` returns the *surface* when feature field 7 is
absent — which for unknown words it always is, since `unk.dic`'s rows carry only 7 fields
(§6). That fallback is why `ロギン` currently gets ろぎん. Keep it: for kana surfaces it is
correct and free, and `TokenizerWorker.reading(of:)` requires `readings.count == tokens.count`
(`:29`), so dropping it would quietly shrink `DocumentLexicon` corroboration. `usableReading`
already rejects the kanji case (commit 93bf240).

**Caveat on this row:** the prototype was *not* re-run with the fallback restored, so
"identical" is a prediction from inspecting the 517 diffs, not a measurement. Counts also do
not prove values — identical token and lemma *counts* leave boundaries and lemma strings
unchecked. The merge gate should be an exact `(surface, reading, dictionaryForm)` tuple
comparison over the corpus, not these three numbers.

**Both were settled by the shipped code (2026-08-14).** Speed: **140.4 ms** best-of-5 over
163,576 chars / 106,597 tokens, same machine, same debug `swift test` — the prototype's 142.2 ms,
reproduced by what actually landed, against 402.9 ms for the path it replaced. Parity: the
committed golden stream matched **line for line**, all 13,709 tokens across all three fields,
with the fallback in place. The prediction held; it is no longer a prediction.

The shape, verbatim from the prototype:

```swift
normalized.withCString { s in
    let base = UnsafeRawPointer(s)
    mecab_lattice_set_sentence(lattice, s)
    guard mecab_parse_lattice(tagger, lattice) != 0 else { return }
    var node: UnsafePointer<mecab_node_t>? = UnsafePointer(mecab_lattice_get_bos_node(lattice))
    while let n = node {
        defer { node = UnsafePointer(n.pointee.next) }
        guard let sp = n.pointee.surface, n.pointee.length > 0 else { continue }
        let lo = UnsafeRawPointer(sp) - base
        let hi = lo + Int(n.pointee.length)
        if cursor < lo { emit(cursor, lo, nil, nil) }
        emit(lo, hi, reading, lemma)
        cursor = hi
    }
}
```

Gap emission stays exactly as `MeCabTokenizer` does it today, so paragraphs and indents still
survive. Feature fields are scanned in place by comma index — no `[String]` split.

**Byte offsets alone are not safe to ship.** MeCab splits `葛󠄀城` into three nodes, so a naive
binding emits `["葛", "\u{E0100}", "城"]`. Those rejoin correctly — `joined()` still equals
`nfkc(text)`, which is the only thing `MeCabTokenizerTests` asserts — but their *character
counts do not add up*: 1 + 1 + 1 = 3 against an `nfkc.count` of 2, because the selector fuses
into the preceding grapheme. Today every surface is a `Character`-aligned slice of the
normalised text, so the sum is exact. Four consumers depend on that:

| site | what it does |
|---|---|
| `TokenOffsets.swift:7,15` | running sum of `surface.count` — **saved reading position** (`ReaderModel.swift:715,721,742`) |
| `SourceReading.swift:80-95` | keys ruby by whole-string NFKC char offset, walks tokens by per-token count |
| `PronunciationLexicon.swift:186-190` | `offset += token.surface.count` |
| `CharTokenMapper.swift:14-19` | `for ch in tok.surface` |

The first three are **cumulative**, so one split grapheme drifts every later token for the rest
of the chapter — a cascading corruption strictly worse than today's bounded, local drop, and
`TokenOffsets` feeds "where I left off". `CharTokenMapper` is the resilient one: it walks
per-`Character` with an 8-token lookahead (`Options.lookahead = 8`) and re-syncs within a few
tokens rather than drifting.

So the binding needs **two** repairs, and they are not the same repair:

1. **Strip-before-tokenise — the segmentation fix.** Remove U+E0100–U+E01EF and U+FE00–U+FE0F,
   tokenise the stripped text, then map each node back onto a slice of the *original* normalised
   text so the selector rides along with its base kanji. Verified to restore 葛城/カツラギ and
   辻/ツジ. This is the repair that gets the readings back, and it is necessarily an enumeration.
2. **Snap-to-grapheme — the additivity fix.** Snap every node boundary *outward* to the nearest
   `Character` index of the normalised text, and merge nodes that collapse to empty. This one is
   general, and it is the only one of the two that makes the invariant below structurally true
   rather than true-by-list.

The second is not optional and the first does not imply it. §2.2's stray combining dakuten splits
a grapheme cluster with **no variation selector in it**, so strip-plus-byte-offsets emits `が` and
`゙` as separate surfaces — 2 characters where the NFKC text has 1 — and the new invariant fails
on the very example that motivates it. Every combining mark surviving NFKC and every emoji ZWJ
sequence has that shape; no enumeration closes the set.

Where a merge does fire, the merged surface no longer corresponds to any single node, so the
token must carry **no reading** (the first node's lemma may stay). That is lossy by construction
— but bounded, local, and no worse than what the wrapper already does there today, minus the
drift.

Required invariants, both of them:

```
tokens.map(\.surface).joined() == nfkc(text)
tokens.reduce(0) { $0 + $1.surface.count } == nfkc(text).count
```

The second is new. String equality survives a split grapheme perfectly, so the committed test
cannot catch this.

Packaging: **vendor MeCab 0.996 into `ReaderCore/Sources/CMeCab`** rather than fork Mecab-Swift.
Both were on the table — a fork would have to be public, since `ci_post_clone.sh` has no
`GITHUB_TOKEN` and Xcode Cloud resolves packages itself — and vendoring won because it removes a
repo to maintain and a resolution step, and because it makes the trim below ours to make. Decided
2026-08-14. Keep the upstream package as a dependency for the **`IPADic` product only**: that is
where the 51 MB dictionary lives, and it should stay a fetched resource, not tracked bytes.

Vendored cost is **492 KB**, not the 4.4 MB the sources weigh, because `ucstable.h` alone is
4.0 MB of EUC-JP / CP932 conversion tables and upstream already guards it: `MECAB_USE_UTF8_ONLY`
(`ucs.h:9`, `char_property.h:54`, `common.h:57`) drops those paths and defaults the charset to
UTF-8. The bundled `sys.dic` declares `utf8` in its header, so the table is unreachable for us
and the header is not vendored at all. That is a constraint on stage 2, and worth writing down:
**a rebuilt dictionary must stay UTF-8.** Everything else is carried verbatim — the same 22 of
28 `.cpp` upstream builds, since §3.3's eight turned out not to be droppable — with `BSD`,
`COPYING` and `AUTHORS` kept as resources, because MeCab's BSD option requires the notice to
survive into the binary.

**Why not just patch the fork's twelve lines?** The fork is happening anyway, and swapping
`range(of:)` for `node.surface` offsets inside `mecabTokenize` would fix the correctness bug
with no new binding layer in `ReaderCore`. It is the smaller change and it deserves naming — but
it leaves §3.1 on the table: the 4.94x is a per-token `Data` copy, a `String(data:)` and a
9-field `[String]` split as much as it is the search, and `DocumentLexicon.build` tokenises every
annotated chapter of the book once per reader session. It would also still have to carry both
repairs above, in someone else's code. Take the direct binding.

Two C-API details worth getting right, both verified in the vendored source:

- Take the offset base from `mecab_lattice_get_sentence(lattice)`, not the `withCString`
  pointer. `LatticeImpl::set_sentence` copies the sentence under `MECAB_ALLOCATE_SENTENCE`
  (`tagger.cpp:764-772`), so the two are not always the same pointer.
- Build the dictionary path with `mecab_model_new` argv-style rather than one escaped string.
  The current wrapper percent-encodes with `.urlPathAllowed` (`Tokenizer.swift:75`), but the
  vendored `param.cpp:211-225` only find-replaces the literal `"%20"` — every other escaped
  byte survives undecoded. That is wider than spaces: `.urlPathAllowed` escapes every non-ASCII
  byte, so a dictionary path containing a single Japanese character opens nothing — and per §3.6
  that failure *traps* at `IPADic.swift:19` rather than surfacing as `.failed`. Unreachable
  today, since iOS container paths are ASCII UUIDs; latent for any user-supplied dictionary.

Guard rails: `CharTokenMapperTests` must stay green, plus new tests for the additivity
invariant, exact `(surface, reading, dictionaryForm)` parity over the corpus, an IVS case, a
publisher-ruby-over-IVS case through `SourceReadingOverlay` (§2.3 — it pins that the selector
rides *in* the surface), and a `TokenOffsets` round-trip — reading position is the consumer
nothing currently covers.
`AlignmentFixtureTests` cannot serve as the safety net: it asserts only non-empty output, no
NaN, monotonic starts and `matchedChars > 0` on >90 % of spans (`:26-42`), and it
`XCTSkipIf`s itself out when fixtures are absent. None of the four committed fixtures contains
a variation selector, and they run 22–151 characters each.

### Stage 1 — the work, in order

Six commits. Two constraints set the shape, and both were found by doing it rather than by
planning it:

**The two engines cannot coexist in one binary.** Vendored `CMeCab` and upstream's `mecab`
(reached through the `Mecab-Swift` product, which `MeCabTokenizer` still needs) define the same
symbols, and the test bundle fails to link on a wall of `duplicate symbol`. So there is no
transition period with both tokenizers alive, and no "keep the old one around as the reference"
commit. The swap is atomic.

**Which is why the reference is committed rather than computed.**
`corpus/kokoro-tokens.tsv` holds the exact `(surface, reading, dictionaryForm)` stream today's
tokenizer produces for the corpus — 13,709 lines. It outlives the code that produced it, so it
can gate a swap that nothing else can.

1. **Corpus fixture and golden stream.** ✅ `ReaderCore` cannot open an EPUB — `EPUBImporter`
   lives in the app target — so `samples/こころ（夏目漱石）.epub` (tracked) was extracted once the
   way `EPUBImporter.strip` does it: body only, `<rt>`/`<rp>` dropped, block tags to newlines,
   entities decoded, whitespace collapsed. 16 spine items, 21,168 chars, stored
   **pre-normalisation** so the tests exercise `Normalize.nfkc` at the tokenizer's own boundary.
   `CorpusInvariantTests` asserts losslessness, additivity and the golden stream;
   `YOMI_REGEN_GOLDEN=1` rewrites the golden when a change is deliberate. Suite green at 157.
2. **Vendor the engine.** ✅ 492 KB under `Sources/CMeCab`, 22 objects, **zero** unresolved
   symbols (`nm -u` across the target, minus what it defines itself — the check that replaces a
   link this commit cannot yet perform). The target is declared but deliberately depended on by
   nothing, because of the collision above; it is built and verified with
   `swift build --target CMeCab`. `MECAB_USE_UTF8_ONLY` and the six excluded CLI entry points
   are the only divergence from upstream's build.
3. **The swap, atomic.** ✅ `Mecab-Swift` dropped (only `IPADic` remains), `CMeCab` added,
   `MeCabTokenizer` rewritten onto the direct binding: `mecab_model_new` argv-style, one lattice
   per call, offset base from `mecab_lattice_get_sentence`, feature fields scanned in place by
   comma index with `omittingEmptySubsequences: false`, OOV fallback preserved, gap emission
   unchanged. **The golden did not move** — 13,709 tokens identical across all three fields,
   which was the prediction: the corpus is Aozora with zero variation selectors, so the binding
   had nothing to disagree with the wrapper about, and any diff would have been a bug in the
   binding rather than a repair.
4. **Both repairs.** ✅ `ClusterProjection` carries them, and it is skipped entirely when the
   text needs neither: the selector map is built only if a selector is present, the
   grapheme-boundary table only if `unicodeScalars.count != count`. Clean Japanese pays one
   scan and nothing else. A node whose projected range gets *widened* by the snap loses its
   reading (the reading no longer describes the surface); a node fully absorbed into the
   previous cluster is dropped and takes the previous token's reading with it. Validated by the
   tests the golden cannot see: the IVS name, publisher-ruby-over-IVS through
   `SourceReadingOverlay`, the dakuten snap, CRLF, and a clean-text control.
5. **Guard rails.** ✅ `TokenOffsets` round-trip over clean / IVS / combining-mark text, and the
   §6 feature-field pin, both as a direct unit test of the comma scanner (empty column keeps its
   index; past the last column is absent, not empty) and behaviourally (`ロギン` → ろぎん proves
   `unk.dic`'s seven-field shape still drives the fallback). The golden diff to read line by
   line turned out to be empty.

   Worth recording, because it cost three test failures: `"葛󠄀城".hasPrefix("葛")` is **false**.
   `葛` and `葛`+selector are different `Character`s, so the obvious test predicate silently
   finds nothing — the same grapheme trap, one level up, in the tests written to catch it.
6. **The app target.** ✅ `xcodebuild test` on an iPhone 17 Pro simulator: **161 tests, 0
   failures** — which is the first proof the vendored C++ links for arm64-simulator, something
   no macOS `swift test` can give. `RealBookRubyProbe` over `samples/こころ（夏目漱石）.epub`:
   113 chapters, 110 annotated, 5,347 publisher readings, 564 distinct overrides, and every
   watchlist word still rendering (躊躇→ちゅうちょ, 几帳面→きちょうめん, 苗字→みょうじ,
   華奢→きゃしゃ, 咀嚼→そしゃく). A run on a physical device is still outstanding.

   One snag worth saving the next person: `RealBookRubyProbe` gates on a `YOMI_EPUB` environment
   variable, and **neither** `xcodebuild ... TEST_RUNNER_YOMI_EPUB=…` **nor** an
   `environmentVariables:` block in `project.yml` gets it into a *hosted unit test* — the first
   is a UI-test-runner mechanism, and xcodegen (this version) emits nothing into the scheme for
   the second, leaving `shouldUseLaunchSchemeArgsEnv = "YES"` pointing at an empty launch
   environment. The probe was run by pinning the path in the file, then reverting. Either wire
   it through a test plan or accept that it is an Xcode-only affordance.

Not in this stage: `AppServices`, `TokenizerWorker`, `SpanTimeline`, `CharTokenMapper`, the
`CLAUDE.md` invariants, `ContentKey`. The public surface does not move — `MeCabTokenizer()` and
`tokenize(_:) -> [Token]`.

Stage 0 needs less scaffolding than it reads like: `app/ReaderTests/RealBookRubyProbe.swift` is
already an env-gated (`YOMI_EPUB`) harness that walks a real book's chapters through
`MeCabTokenizer` and the ruby overlay. The measurement is roughly twenty lines added to it.

### Stage 2 — optional, ~23 MB (do last)

Rebuild IPADic from its CSV source with the feature columns trimmed to 原形 + 読み. Feature
blob 31.5 MB → roughly 8 MB, so `sys.dic` ~49 MB → **~26 MB**. IPADic's CSVs carry explicit
left/right context ids, so the connection matrix is untouched.

The `posid` caveat the first draft left open is **answerable and answered**: `mecab-dict-index`
derives `node.posid` by matching the feature string against `pos-id.def`, so stripping POS
fields zeroes it — but `IPADic.partOfSpeech(posID:)` is its only consumer and nothing in
`ReaderCore` or `app/Reader` reads `Annotation.partOfSpeech` at all (verified by grep). So this
is not a blocker.

What actually justifies deferring it is packaging and validation cost, not risk of breakage:
it needs a host-side `mecab-dict-index` step, a rebuilt-dictionary diff proving identical
surfaces, costs, lemmas and readings across corpora, new feature indices agreed between the
adapter and `unk.dic`, and a GitHub release asset the way `jisho-compact.db` already is so
Xcode Cloud can fetch it. Meanwhile the App Store *download* cost of the dictionary is already
only ~12 MB (it gzips to 24 %); only installed footprint improves.

### Not recommended

Switching engines. Every candidate costs a toolchain, an FFI layer we would write anyway, and
a re-validation of the alignment fixtures — to fix a bug that lives in 40 lines of Swift.

---

## 6. Residual risks and things still unknown

**The feature-schema hazard is real in the code and absent in our data.** `Token.swift:24` uses
`split(separator: ",")`, and Swift's `omittingEmptySubsequences` defaults to `true` — so one
empty feature column would shift 原形 and 読み silently. I parsed the shipped dictionaries to
settle it: all **392,126** `sys.dic` feature rows have exactly 9 fields and **zero** empty ones,
and `unk.dic`'s 40 rows have exactly 7. So it cannot bite with bundled IPADic today. It would
bite with a user dictionary or a re-built one (§5 stage 2) — the direct adapter should split
with `omittingEmptySubsequences: false` and pin the field count in a test.

That same `unk.dic` schema is the precise mechanism behind the OOV fallback discussed in §5:
7 fields means index 7 (読み) does not exist, so `Token.reading` returns the surface; index 6
exists but is `*`, so the lemma is correctly nil.

**Fixing segmentation churns the pronunciation dictionaries, at a one-time cost.** Better
tokenisation changes which candidates survive `PronunciationLexicon`'s gates, which changes the
canonical rule set, which changes the hash the Worker resolves to a dictionary locator. Per
`CLAUDE.md` that mints one undeletable ElevenLabs dictionary per chapter, and identity is
currently per chapter rather than per book. **`ContentKey` is untouched** — it hashes only voice
plus NFKC text (`ContentKey.swift:8`) — so no audio is re-billed and nothing cached is
invalidated. The churn is real but bounded and one-time. It is also asymmetric in our favour:
per §2.3, an IVS name currently yields *no* rule at all, so stage 1 mostly adds rules where the
lexicon was silent rather than rewriting rules it already had.

**Corollary, and a hard rule for stage 1:** selector stripping must live *inside* the
tokenizer. `Normalize.nfkc` is shared by the tokenizer, the TTS request body and `ContentKey`.
Stripping there would reshape the hash input and re-bill every chapter containing a variation
selector — exactly the failure f5ad953 removed the model from the key to stop.

**Answered, 2026-08-14, against the live API on device.** ElevenLabs' alignment **does** emit a
variation selector as its own timed entry: 葛 at 6.02 s, `U+E0100` at 6.34 s, 城 at 6.46 s —
the invisible character is given a twelfth of a second of its own. So `aChars` holds a bare 葛
and a lone selector where the token stream holds one composed 葛󠄀, and neither side's lookahead
can match the other's character. The mapper's "both missing" branch advances past it and
re-syncs within a character or two, exactly as hoped. Measured on a chapter with five
selectors: at two sampled moments the highlight was on the token the audio was speaking (once
exactly, once one character ahead, inside the readout's own rounding). The cost of a selector
is two characters of local slack, not drift.

**What that measurement did surface is a pronunciation bug, in the lexicon rather than the
tokenizer.** The rule minted from publisher ruby carries the selector in its key —
`葛󠄀城 → かつらぎ`, `U+845B U+E0100 U+57CE` — and ElevenLabs applies dictionary entries by exact
string match. A book that writes the same name both ways therefore gets it right where the
selector appears and wrong where it does not: on the test chapter, two 葛城 out of three were
Katsuragi and the bare one came back as something like "kakasho". `EPUBImporter.propagate`
already spreads a stated reading to every *identical* occurrence; it now treats a variation
selector as the glyph-level detail it is, so both spellings are annotated and both become
rules. Note the furigana was right at all three sites throughout — IPADic knows 葛城 — which is
the asymmetry to remember: **the reader can be right on the page and wrong in the ear, and only
the ear is billed.**

Not a defect, for the record: the same chapter reads 四 as し where the furigana says よん. Both
are correct Japanese for an enumerated 四, IPADic picked one and ElevenLabs the other, and
nothing in the pipeline is positioned to say which a given book means.

---

## Appendix — how this was measured

Five throwaway XCTest probes in `ReaderCoreTests`, run with `swift test`, since removed
(archived in the session scratchpad). `ReaderCore` is green at **154 tests, 0 failures** after
cleanup; nothing in the repo was modified.

**Read the timings as ratios, not as budgets.** `swift test` builds debug, on macOS arm64, with
no warm-up protocol, repetition count or variance. The relative ordering (raw C ≪ direct
binding ≪ wrapper) is robust and is what the argument rests on; the absolute figures are not an
iPhone benchmark. Two further caveats the first draft skipped: chapters are capped at
`Chapter.maxRenderableChars` = 4,000 (`Document.swift:68`), so a 165,665-char book overstates
per-reader-open cost by ~40x — but `DocumentLexicon.build` (`:20-23`) tokenizes *every*
annotated chapter once per reader session, so whole-book cost is the right measure for that
path. And the 4.94x is the wrapper's *total* overhead — surface decoding, feature-array
construction and annotation building as well as the `range(of:)` search — not the search alone.

1. **Coverage/segmentation** — IVS, NFD dakuten, non-BMP kanji, emoji through both
   `Mecab_Swift.Tokenizer` and `ReaderCore.MeCabTokenizer`, comparing annotation char coverage
   against input length.
2. **Raw C API** — `mecab_new2` + `mecab_sparse_tonode`, byte offsets via
   `UnsafeRawPointer(node.surface) - base`; isolates engine cost from wrapper cost. Also
   verified the `mecab_model_*` / `mecab_parse_lattice` path against IPADic.
3. **Apple frameworks** — `NLTagger.availableTagSchemes(for:language:)`, `.lemma` and
   `.lexicalClass` enumeration, `NLTokenizer`, and `CFStringTokenizer` +
   `kCFStringTokenizerAttributeLatinTranscription` → `.latinToKatakana`.
4. **Corpus** — Kokoro EPUB, `<rt>`/`<rp>` stripped, tags removed, NFKC'd; timing and coverage
   for raw C / wrapper / `MeCabTokenizer`, plus 38 injected IVS selectors into the first
   20,032 chars.
5. **Prototype parity** — the direct binding above vs. `MeCabTokenizer` over the whole corpus:
   token/reading/lemma counts, a per-token diff, a kanji-only diff, and the lossless invariant
   line by line.

The re-review added a sixth, also removed and also archived: the IVS, stripped-IVS, stray-dakuten,
non-BMP and CRLF cases through `MeCabTokenizer` alone, printing every token with its reading and
lemma plus `lossless` and `additive` for each. It is the seed of the stage 1 tests — both
invariants are already in it — and it is what §2.1's token-layer paragraph and §2.2's `が゙っこうへ`
figure come from. `sys.dic`'s header, the fixture inventory and the `.cpp` counts were re-derived
directly from the checkout rather than through a test.

Dictionary sections came from parsing `sys.dic`'s 72-byte header
(`<10I` = magic, version, type, lexsize, lsize, rsize, dsize, tsize, fsize, dummy + 32-byte
charset). Bundle sizes are from the Debug `iphoneos` build in DerivedData.
