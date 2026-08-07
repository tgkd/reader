# Findings — 2026-08-07: pronunciation dictionaries

Whether ElevenLabs alias dictionaries can fix Japanese proper nouns without breaking the
word-synced highlight, and whether `eleven_v3` can be made safe enough to return to.

Everything numbered below was measured against the live API on 2026-08-07 with the
production configuration — `eleven_flash_v2_5`, voice Shizuka (`WQz3clzUdMqvBf0jswZQ`),
`language_code: ja`, the pinned `voice_settings`, `stream/with-timestamps`,
`mp3_44100_128`. Where something is inferred rather than observed it says so.

**This supersedes one line in `2026-08-03-findings.md`.** See §6.

---

## 0. The short version

- **Keep `eleven_flash_v2_5`; `eleven_v3` is closed, not deferred** (§4). It sounds better and
  still fails ~75 % of chapter generations against the client's alignment guard, at double the
  price. Confirmed by listening 2026-08-07.
- Alias rules fire inside CJK, and in every case tested the returned alignment still
  described the audio well inside the client's guard. The mechanism works.
- They must use `word_boundaries: false`. At the default they silently never fire on CJK.
- **Confirmed by listening (2026-08-07): all eight aliased clips read correctly, all eight
  un-aliased ones were wrong.** The correction is real on the cases tested.
- **Supplying the reading is the only remedy.** Checked by elimination (§7): all five Japanese
  voices, with and without our settings, plus v3 and multilingual_v2, all read the test names
  wrong. Configuration cannot fix an irregular proper noun; only the book's own ruby knows it.
- **Not yet shippable.** Reviewed 2026-08-07 (§9). The mechanism is sound; the *selection*
  problem is unsolved — the safety check proposed in §8 was measured to have no
  discriminating power, the small-kana gate in §7 is vacuous as written, and a bad global
  rule has no rollback. §9 lists what must be settled first.

The dictionary is a **remote resource on the ElevenLabs account**, not something the client
carries: rules are uploaded once via `add-from-rules`, and a synthesis request references
them only as `{pronunciation_dictionary_id, version_id}`. That is what makes the lifecycle
questions in §3 real, and what makes a bad locator an outage rather than a degradation.

---

## 1. Alias rules match inside CJK — but only with `word_boundaries: false`

Absurd alias (`黄前` → a long kana run, so firing is a large duration jump rather than a
judgement call), plus a Latin positive control so a non-firing rule is distinguishable
from a broken matcher.

| cell | audio |
|---|---|
| Latin control, no dictionary | 1.91 s |
| Latin control, `word_boundaries: true` | 10.40 s — **fired (+8.49 s)** |
| CJK, no dictionary | 1.67 s |
| CJK, `word_boundaries: false` | 5.44 s — **fired (+3.76 s)** |
| CJK, `word_boundaries: true` | 2.04 s — **did not fire** |
| CJK, `eleven_multilingual_v2`, no dictionary | 1.80 s |
| CJK, `eleven_multilingual_v2`, `word_boundaries: false` | 8.49 s — **fired (+6.69 s)** |

`word_boundaries` defaults to `true`, and at that default a CJK rule is a silent no-op —
indistinguishable from the model happening to read the name correctly. That is why this
was previously written off as impossible.

**Alias, not phoneme.** Phoneme rules work only on `eleven_flash_v2` (English-only) and
`eleven_v3`. For Japanese there is no alignment-exact model that accepts IPA, so the
choice is not open.

**Billing — inferred, not measured.** ElevenLabs documents per-*input*-character billing, so
a 2-character surface spoken as 8 kana should still bill 2. No before/after credit
accounting was taken, and nothing documents whether substitution happens before or after
metering; one usage-endpoint read would settle it. Aliases are character-neutral under that
rule, but they are **not** duration-neutral: a long alias lengthens the audio, which costs
synthesis time, connection duration and head-start latency even when it costs no credits.

## 2. The returned alignment describes the original text, and stays honest

The load-bearing question: with an alias firing, does `alignment.characters` come back as
the submitted text or the substituted text? If substituted, `WorkerTTSService`'s
`joined() == text` guard rejects every affected response and the whole approach dies.

Text `黄前久美子です。今日はいい天気ですね。` (19 chars):

| cell | audio | alignment end | undescribed | joinOK | chars | backwards |
|---|---|---|---|---|---|---|
| no dictionary | 4.862 s | 4.830 s | 0.032 s | true | 19/19 | 0 |
| alias `おうまえ` | 4.626 s | 4.597 s | 0.029 s | true | 19/19 | 0 |
| alias `ぬるぽ`×6 | 9.015 s | 8.963 s | **0.052 s** | true | 19/19 | 0 |

Per-character, long-alias cell against the control:

```
      no dictionary          with long alias
 黄   0.000 → 0.453          0.000 → 2.183
 前   0.453 → 1.010          2.183 → 5.004
 久   1.010 → 1.277          5.004 → 5.352
 美   1.277 → 1.428          5.352 → 5.492
```

**The aliased characters absorb nearly all of the spoken alias.** 黄前 grows from 1.010 s to
5.004 s — an added 3.994 s — while total audio grows 4.153 s and the alignment end 4.133 s.
The remainder is spread through the rest of the utterance: 久 starts 3.994 s later, 美
4.075 s later. The model **re-times the whole utterance rather than splicing**, so "everything
after shifts by exactly the insertion" is wrong; the shift is close to uniform but not exact.
What matters holds regardless: the character list never changes length, and no timing runs
backwards.

Consequences:

- `CharTokenMapper` needs no change — it matches display characters against alignment
  characters, and both are still the submitted text. Verified against
  `CharTokenMapper.swift:19` and `:53-55`.
- `ContentKey = sha256(voice + nfkc(text))` needs no change **for a global dictionary**,
  where every request carries identical rules. A locator is not text, so no already-paid
  chapter is invalidated and nothing is re-billed. **This does not extend to book-scoped
  rules** — see the scoping note in §7 Phase 2.
- The `audioAlignmentMismatch` guard (1.0 s) is never approached. Worst observed is
  0.052 s, ~20x inside it and indistinguishable from the no-dictionary baseline.

Re-measured across the eight real cases in §5: undescribed 0.028–0.052 s, `joinOK` true on
all sixteen generations.

**Scope of the claim.** This is alignment fidelity for one model, one voice, these rules and
these texts — not a contractual property of the API. Two limits worth keeping in mind:

- Upstream behaviour can change, so this needs a regression probe, not a one-time result.
- **The guards run after playback has already started.** `WorkerTTSService.swift:113`
  publishes each chunk via `onChunk` — wired straight into `SynthesisStream.publish`
  (`AppServices.swift:38-40`) — while the `joined() == text` check sits at `:80` and the
  1.0 s tolerance at `:87`, both after accumulation finishes. A dictionary response that
  broke the alignment would be heard and highlighted before it was rejected. It would never
  be sealed into the cache, but the guard is not a shield for the current listen.

## 3. Capacity, lifecycle, and the Worker's credential

**Rules per dictionary.** 142, 500, 1,000 and 5,000 all accepted, `version_rules_num`
echoing what was sent. The expected ~142 entries per book is not near any limit. The
3-locator cap is per *request*, not per rule.

**Deletion.** `DELETE /v1/pronunciation-dictionaries/{id}` → **405 Method Not Allowed**.

**Archiving.** `PATCH /v1/pronunciation-dictionaries/{id}` accepts `archived: boolean` and
returns `archived_time_unix`; all 13 probe dictionaries archived successfully. So a hidden
state exists and hard delete is merely missing. **"Archived" is not proven to mean
"reclaimable"** — no account quota was measured before and after, so whether archived
dictionaries stop counting against a limit is an inference, not a result.

**And archiving is destructive to anything still pinning it — see §10.** An archived
dictionary returns 404 at synthesis rather than being ignored, so "create at first synthesis,
archive when the book is deleted" is only safe with reference counting across devices,
re-imports and retries. Read §10 before designing any per-book lifecycle.

**Version pinning.** Created version A with a long alias, mutated the dictionary to
version B, then synthesized again pinned to A:

| cell | audio |
|---|---|
| no dictionary | 1.67 s |
| pinned A, before the update | 5.67 s |
| pinned A, **after** the update to B | 4.68 s |
| pinned B | 1.81 s |

A still fires A's alias after the dictionary moved on. *Caveat:* A came back 5.67 s then
4.68 s — both unmistakably the long alias against a 1.67 s baseline, but not identical, and
this was not repeated enough times to call the difference noise with confidence. Only one
mutation and no long delay were tested.

**The Worker holds no ElevenLabs key** — only `AI_GATEWAY_TOKEN`, with the provider key
stored BYOK at the gateway (`aiwork/src/index.ts:54`, `:331-348`). Narration proves the
*inference* path works; management calls are a different class. Measured:

```
GET {gateway}/elevenlabs/v1/pronunciation-dictionaries   (cf-aig-authorization only)  -> 200
GET {gateway}/elevenlabs/v1/models                       (same auth)                  -> 200
```

The gateway forwards management endpoints too, so **no second credential is needed** — the
read path is proven. **Only `GET` was tested.** Phase 2 needs `POST` (create) and `PATCH`
(archive) through the gateway, and neither has been: every probe dictionary in this
investigation was created out-of-band with the raw key. Phase 1 does not need them — its
locator is created by hand once — so this blocks Phase 2 only.

## 4. `eleven_v3` is disqualified twice, not once — decided 2026-08-07

**Decision: stay on `eleven_flash_v2_5`.** Confirmed by listening on the same day: v3 does
sound better on names and context, and it still produces random artifacts. The measurements
below say why that is not a tradeoff worth taking, and the question is now closed rather than
deferred. It should only be reopened if ElevenLabs publishes an alignment fix — and then only
by re-running the twelve-generation protocol at full chapter length, because nothing shorter
detects the defect.

**Re-measured 2026-08-07 on the identical 851-character chapter, and the defect is
intermittent — which is worse than being constant.**

| model | run | undescribed | against the 1.0 s guard |
|---|---|---|---|
| `eleven_v3` | 1 | **8.29 s** | rejected |
| `eleven_v3` | 2 | **0.77 s** | passes |
| `eleven_flash_v2_5` | 1 | 0.04 s | passes |
| `eleven_flash_v2_5` | 2 | 0.03 s | passes |

Same text, same route, same day. So v3 has not been fixed since 08-03, and the defect is
**stochastic**. Five further consecutive runs of the identical chapter pinned the rate:

```
sample A:  0.11s   5.08s   7.08s   7.00s   4.43s      4 of 5 rejected
sample B:  8.68s   0.05s  10.76s   6.28s   7.96s      4 of 5 rejected
```

**Two independent five-run samples, both 4 of 5 rejected.** Across all twelve v3 generations
of this chapter measured on 2026-08-07, **nine exceeded the 1.0 s guard — a ~75 % failure
rate**, with a worst case of 10.76 s. The audio length varies by up to 15 s (6 %) across runs
of identical input, which is the same instability seen from the other side. flash was within
0.04 s on every run it has ever been measured on, including the control in sample B.

The synced-reading view at `~/Downloads/yomi-tts-findings/v3-sync.html` plays each of these
runs with the highlight driven by the returned timings, which makes the failure concrete: on a
rejected run the text finishes and the voice carries on talking for several more seconds.

**Where the missing time is not.** The obvious hypothesis for this particular page — a
character list, dense with full-width spaces that NFKC folds to ordinary ones — was that v3
vocalises something in the blank positions. It does not. All 186 blank characters carry
timings, totalling 44–48 s (about a fifth of the audio), with the longest individual pauses at
1.6–2.0 s landing exactly on the breaks between entries. The formatting pauses are budgeted
correctly. The deficit is that the alignment simply *ends* 4–7 s before the audio does.

Intermittency is the disqualifier, not the magnitude. A constant defect could be compensated;
a coin flip cannot. A rejected response is still billed by ElevenLabs — the synthesis happened,
the client simply refused it — so at v3's doubled rate, a ~50 % rejection rate makes the
effective cost of one *usable* chapter roughly **four times** flash's. Against ~$2.00/hour on
flash and a $0.99/month subscription with no overage, that is not a tradeoff, it is an outage
generator. And the user-visible failure is not degraded sync but "TTS failed", because
`audioAlignmentMismatch` rejects before anything reaches the cache.

No documented parameter targets timestamp *coverage* — `stability` targets expressive variance,
`seed` targets reproducibility, and `apply_text_normalization` is a text-rewrite switch. A fixed
`seed` might make failure reproducible, but reproducible-wrong is not the goal.

Worth recording: `stability` on v3 is documented as three modes (Creative ~0.0 "prone to
hallucinations", Natural ~0.5, Robust ~1.0), and the 2026-08-03 matrix sent `0.65`, which
v3 accepted. So the run most likely tested Natural and **Robust has never been measured**.
That is the only remaining thread if the model is ever revisited.

But the second disqualifier survives any alignment fix: **v3 bills 1.0 credit/char against
flash's 0.5** (`scripts/eleven-matrix.mjs:58`). ~$2.00/hour becomes ~$4.00/hour against a
$0.99/month subscription. On a plan with no overage, exhausting credits is an outage.

**The defect is length- or content-dependent, so short samples cannot test for it.** Measured
2026-08-07: the same 25-character sentence on `eleven_v3`, both Shizuka and Daisuke, both bare
and in the production configuration, returned **0.03–0.05 s** undescribed with `joinOK` true in
all four cells — indistinguishable from flash. Nothing was wrong at that length.

That kills the obvious cheap test. An earlier draft of this section proposed a two-stage
retest starting with 300–900-character excerpts, escalating to full chapters only if those
passed; on this evidence that first stage would have passed a model that is broken at chapter
length, and the escalation would never have happened. **Any v3 retest has to run at full
chapter length from the start**, budgeted at the 4,000-character cap — around 120,000 credits
for 30 generations, which is a ceiling to plan against, not an average. There is no cheap
version of this experiment.

## 5. It sounds better — confirmed by listening

§1–§3 prove an alias fires, that the alignment survives, and that the lifecycle is workable.
None of them prove the narration improved; only ears can. Eight real failure cases from
`2026-08-03-findings.md` §4 were generated twice — once exactly as production sends today,
once with one alias rule — and laid out as an A/B page at
`~/Downloads/yomi-tts-findings/index.html` (audio in `audio/`, metrics in `cases.json`).

Cases: 黄前→おうまえ, 希美→のぞみ, 緑輝→サファイア, 鎧塚→よろいづか, 生れ→うまれ,
秀一→しゅういち, 明静工科→みょうじょうこうか, 洛秋→らくしゅう.

**Result (2026-08-07, listened through): 8 of 8 wrong before, 8 of 8 correct after.** So
`eleven_flash_v2_5` really does misread these names — the weakness was not imagined — and a
kana alias really does fix it, with no cost to the alignment.

**What this does and does not establish.** The eight were *selected* from the 08-03 findings
precisely because they were known failures, so the sample carries **no base rate**: it says
nothing about how often a chapter contains such a name, and "8 of 8" must not be read as a
prevalence estimate. It is also n=1, unblinded, and judged by someone who knew which clip
carried the alias — survivable for a categorical right/wrong reading judgement, not for
anything subtler. It supports exactly one claim: *these eight are wrong today and fixed by an
alias.*

Two consequences worth keeping:

- It covers the case that drove the move to `eleven_v3` in the first place. 生れ→うまれ is a
  global rule, not a book-scoped one, so Phase 1 alone recovers v3's headline advantage on
  flash's alignment and flash's price.
- **The failures are ordinary misreadings, not invented ones.** An earlier draft claimed 秀一
  came out as *kyuuichi*, a reading no source proposes, and built an argument on it. That
  claim is **withdrawn**: it rests on one unblinded listen of a confusable pair (きゅう against
  the correct しゅう), and the same listener later corrected a second mishearing of exactly
  this kind — hearing *himae* for what was, on a second pass, **きまえ**. Where a reading is
  one mora away from another, casual listening is not evidence.
- **What the corrected observation shows is more useful anyway.** v3 reads 黄前 as きまえ:
  黄 with its ordinary kun reading き, plus 前 まえ. IPADic independently produces きぜん —
  also き. Both are *reasonable* readings of the characters; both are wrong for this surname.
  Nothing is malfunctioning. An irregular proper noun simply has no derivable answer, so no
  model and no tokenizer can be expected to find one, and **only the book that prints the ruby
  knows it.** That is the strongest argument in this document for the book-scoped design.

## 6. Correction to `2026-08-03-findings.md`

That document lists, under "Ruled out by measurement, so don't re-litigate":

> pronunciation dictionaries (alias matching is whitespace/word bounded, so it cannot match
> inside CJK at all)

**This is wrong as written.** It is true only at the `word_boundaries` default, which was
not known to be settable. §1 refutes the categorical form. Left standing, that line will
block the approach again.

The 08-03 experiment survives in `~/Downloads/yomi-tts-findings/pronunciation/`, and it
shows exactly how the conclusion went wrong: `without-dict.mp3` is 209,859 bytes and
`with-dict.mp3` is 211,531 — 13.12 s against 13.22 s on the same seven-name line. The
dictionary had no effect, which was read as "aliases cannot match CJK". The observation was
right; the inference was one level too strong. The rule was simply never applied, because
`word_boundaries` defaulted to `true` — the same silent no-op §1 reproduces deliberately.
This is why the Latin positive control matters: without it, "did not fire" and "fired but
changed nothing" are the same measurement.

The neighbouring §4.4 reasoning is *not* affected and still holds: sending a pronunciation
**rewrite** would put the alignment on characters that are not on the page and would have
to enter `ContentKey`. A dictionary does neither — that is exactly why it is the right
mechanism.

---

## 7. Recommended shape

Config stays in the Worker so narration can be retuned without an App Store release —
same principle as `TTS_MODEL` and the `voice_settings`.

**Direction decided 2026-08-07: the book's own ruby is the primary source, not a global
lexicon.** Where a book carries furigana and parses cleanly, build that book's dictionary
from it and trust the author. Where a book carries none, send no dictionary and let the model
read — do **not** substitute a generic lexicon (§8 measures why that fails in both directions).
The global list stays a small hand-curated exception set for orthography classes no book
annotates, such as 生れ→うまれ, and it is the *narrower* half of the plan, not the foundation.

This reverses the emphasis of the two phases below: Phase 1 is a stopgap that buys one class
of fix cheaply, and Phase 2 is the actual design. Sequencing is still Phase 1 first, because
it is an env var against a persistence change — but it should stay small enough that it never
becomes the thing being maintained.

**Phase 1 — global lexicon, Worker-only, no client change.**
A curated dictionary of corrections that are true regardless of book — old orthography
(生れ→うまれ) is the clearest class. Worker holds `{id, version_id}` in env (alongside
`TTS_MODEL`) and attaches the locator to every reader request. The client keeps sending
exactly `{text, voice_id, stream}`; the request body stays assembled field by field. Entries
are added by updating the dictionary and bumping the pinned version in env — no app release,
no cache invalidation.

Do **not** populate it with "common surnames and place names" as an earlier draft of this
section said. Those classes are heavily reading-ambiguous in Japanese and contradict §8's own
admission rule; a global entry has to be a surface whose reading does not depend on context,
which most two-kanji names are not.

**Phase 2 — book-scoped readings, needs a wire field.**
The candidate set exists, but **not where this document previously claimed**.
`readingIndex` (`EPUBImporter.swift:89-102`) computes the useful set — unique, multi-char
ruby groups, 142 entries / 2,494 occurrences in the measured volume — and then uses it only
to drive propagation. What lands in `Chapter.sourceReadings` is `propagate`'s output, seeded
from the chapter's *own unfiltered* annotations (`EPUBImporter.swift:108-110`), so
single-character and locally ambiguous ruby persists: `EPUBImporterTests.swift:143` asserts
a chapter whose `sourceReadings` surface list is exactly `["黄"]`. The persisted model is
therefore *not* the filtered rule set, and the 142/2,494 figure describes the transient index.

Phase 2 needs a distinct persisted candidate structure: whole ruby groups, the raw reading
as well as the repaired one, provenance, ambiguity status, and a stable rule-set identity.
"One request field" understates it — server-side idempotent creation, book identity,
versioning and cleanup are all unresolved.

Scope must stay **per book**: 緑輝→サファイア is a name in one volume and wrong everywhere
else.

**Cache identity under per-book rules — noted, accepted, not fixed (decided 2026-08-07).**
`ContentKey` is voice + text only (`ContentKey.swift:7-8`) and `DiskAudioStore` names its
files from it alone (`DiskAudioStore.swift:16-17`), so in principle two books sharing a
byte-identical chapter would share one cache entry while wanting different rules. Review
raised this as critical; it is not. Two *different* books do not contain the same 4,000
characters. The only realistic version is the **same** book imported twice from different
sources — an EPUB carrying ruby and a plain-text extract of it — where the text can coincide
and only one side has readings. The outcome there is that one import plays the other's
audio: a missing improvement, not a wrong pronunciation, and identical to the already-accepted
stale-cache policy. Not worth a rule fingerprint in the key, which would cost the invariant
that the key names only what the client can see. Revisit only if a case appears where the two
sides disagree rather than one being absent.

**The gate for Phase 2 — flattened small kana (§4.3 of the 08-03 doc).**
That EPUB had every 小書き kana flattened, and restoration is heuristic; §4.3 is explicit
that "only proper nouns rely on the rule alone" — precisely the entries a dictionary would
hold. Today a bad restoration yields wrong furigana: visible, and a reader self-corrects.
As a TTS alias it yields wrong narration, cached as paid audio `ContentKey` cannot
invalidate.

Gate **per entry, not per book** — a book-level gate would reject every entry on the only
book measured, including all the ones the feature exists for. The intent is to admit entries
the repair never touched, and require MeCab agreement in the flattened space for the rest.

**The test proposed earlier for this — `restoreSmallKana(raw) == raw` — does not work, and
cannot be made to work on the data as persisted.** Two independent reasons:

1. `repairFlattenedKana` (`EPUBImporter.swift:64-87`) replaces the reading **in place** and
   never keeps the original, so by the time anything could be gated there is no `raw` to
   compare against — only the repaired form.
2. Even given the repaired form, the comparison is vacuous: `restoreSmallKana` is idempotent,
   because its trigger sets are large kana only (`KanaRepair.swift`: `yoonFollowers` is
   `やゆよヤユヨ`, `digraphFollowers` is `アイエオ`). Running it on already-restored text is a
   no-op, so `restoreSmallKana(persisted) == persisted` holds for touched and untouched
   entries alike — it passes everything, in exactly the flattened-book case it exists for.

So this gate is unbuilt, not merely unimplemented. Making it real requires persisting the raw
pre-repair reading alongside the repaired one (see the Phase 2 structure above) and gating on
whether those two differ. Until that exists, entries from a book detected as flattened have
**no** working trust gate.

**Do not** build rules from MeCab readings generally. IPADic is wrong on exactly the proper
nouns at issue (黄前→きぜん, 希美→きみ), and `Token` carries no POS to filter on
(`TokenSpan.swift:3-11`). Nor is POS one field away: the dependency collapses posIDs 36…67
into a single `.noun` with no proper-noun case — `IPADic.swift:38-55`, which lives in the
MeCab-Swift checkout (`ReaderCore/.build/checkouts/Mecab-Swift/Sources/IPADic/IPADic.swift`),
not in this repository's own sources.

**Do not gate on "the book and MeCab disagree" either.** That was the obvious way to pick
which readings deserve a rule, and §5 kills it: 秀一 came out as *kyuuichi*, a reading
neither source proposes. The model is a third opinion with its own failure mode, so
tokenizer disagreement predicts nothing about whether narration needs help — you would have
to listen to every name to know.

The tempting way out was that the question then does not need answering: if an alias asserting
the *correct* reading were inaudible when the model already had it right, one could simply
assert every authoritative reading and never predict which are needed.

**Measured 2026-08-07, and the premise does not hold.** Four ordinary words the model reads
unaided (東京, 学校, 先生, 天気) were generated with and without a redundant alias asserting
the reading the model already produces. The readings were unaffected, as expected — but the
aliased side consistently carries **slightly longer pauses** around the substituted word.
Small per occurrence, and inaudible as a reading error; but a book-scoped lexicon fires on the
order of 2,500 times per volume (§4.2 of the 08-03 doc), and that is a lot of small pauses
inserted into prose that had none.

So **"assert everything trustworthy" is dead as a free lunch.** A redundant alias costs
something, which means each entry has to be worth its cost, which means necessity matters
after all — the thing §5 appeared to excuse us from deciding. The workable form is narrower:
assert readings where there is reason to believe the model needs help, not every reading that
can be justified.

**And the model's errors are not confined to proper nouns.** In the same run, 学校 — an
everyday word, not a name — was **mispronounced without the alias** and corrected with it.
That was the control case, chosen because it was supposed to be safe. It means the failure
surface is wider than "rare names and old orthography", and that predicting which entries are
needed cannot be done from word class alone. It does not, however, rescue a generic
dictionary: §8's collision measurement kills that independently.

### Neither the voice nor the model is the fix — checked by elimination

Before committing to a dictionary it was worth asking whether the names could be fixed by
choosing something differently. Everything available was tried on the same name-dense sentence
(黄前, 鎧塚, 秀一), and listened through on 2026-08-07:

| candidate | result |
|---|---|
| all five catalog Japanese voices — Shizuka, Maiko, 広小路学, Ishibashi, Daisuke | **all read the names wrong** |
| each of those with production settings *and* bare (no `voice_settings`, no `language_code`) | no difference to the names |
| `eleven_v3`, the model that reads names best | wrong too — 黄前 as きまえ |
| `eleven_multilingual_v2` | already known wrong on old orthography |

So the reading cannot be obtained by configuration. Not by voice, not by settings, not by
model, not by paying double. This is the elimination result the rest of the design rests on:
**an irregular proper noun has to be supplied, because nothing derives it** — and the only
component that already holds the answer is the book's own ruby.

**That result covers irregular proper nouns only. For ordinary words the voice does matter,
and our default is the weaker one.** On 学校まで歩いて行きました。 Daisuke reads がっこう
correctly, while Shizuka reads something closer to **こうこう** — which is not a plausible
reading of 学校 at all, but is exactly 高校, a word this very chapter is full of. Same model,
same settings, same text; only the voice differs.

Two consequences, both outside the dictionary's scope:

- The default voice is worth revisiting on pronunciation grounds after all, not only on
  delivery. The catch is `ContentKey`: changing the default orphans every chapter cached under
  Shizuka for users who never chose a voice, so the honest move is to make a better voice
  available and prominent rather than to silently switch the default.
- A common word misread by one voice and not another is **not** a dictionary problem. Adding
  学校→がっこう globally would paper over a voice defect with an irreversible rule, which is the
  worst available trade. Fix the voice, not the lexicon.

**Not recommended: v3 as an offline reading oracle.** `/v1/forced-alignment` returns where
submitted characters occurred, not how a kanji sequence was pronounced — it cannot emit
おうまえ. Scribe would transcribe back to kanji-mixed orthography, not kana. The idea
fails structurally, not merely on cost.

**Already-cached chapters: decided 2026-08-07 — do nothing.** A dictionary change cannot
alter `ContentKey`, so chapters already generated keep their old pronunciation and only new
synthesis is corrected. No per-chapter regenerate affordance, no invalidation, no re-billing.
This is the same policy the model change took, and for the same reason: audio the user paid
for is theirs, and silently re-billing it to fix a name is the worse failure.

**But that decision cuts both ways, and only the harmless direction was considered.** The
benign case is a name fixed today staying wrong in chapters generated yesterday. The
symmetric case is worse: ship one *wrong* global rule and every chapter generated while it
was live is permanently mispronounced. Nothing records which lexicon version produced a cache
entry — `DiskAudioStore` can `remove(_:)` and `clear()`, but neither is addressable by rule
version — so the only remedy is wiping the library and paying to regenerate all of it.

**A global rule is therefore effectively irreversible once audio is cached.** That, more than
implementation effort, is the argument for keeping Phase 1 very small and for gating entries
on evidence rather than plausibility.

---

## 8. The remaining problem is the lexicon, and the hazard is substring matching

The transport is settled: rules fire, alignment survives, the lifecycle works, the Worker
has the credential. What is left is deciding *what goes in the dictionary* — and that is
harder than it looks for one reason.

**`word_boundaries: false` is not "match this word". It is "match this substring, anywhere,
in any book, forever."** There is no morphological awareness behind it; the same property
that lets 黄前 match inside 黄前久美子 lets any rule match inside any longer word that
happens to contain it. A rule is not a statement about a word, it is a rewrite over raw
text.

That asymmetry decides how the two phases are gated:

**Global lexicon (Phase 1)** carries the higher risk, because a rule asserted globally must
hold across every book the user will ever import — including ones not written yet. A surface
is only safe here if it is unambiguous *as a substring of arbitrary Japanese*, which is much
stronger than being unambiguous in one novel. Keep it small, hand-reviewed, and biased
toward long distinctive surfaces and orthography that has exactly one reading. 生れ→うまれ
qualifies. A common two-kanji given name generally does not.

**Book-scoped (Phase 2)** has a smaller blast radius — one book — but **it does not escape
substring collision**, as an earlier draft of this section claimed. Its filters are about
which readings are *authoritative*, not about where they *match*. Within a single book a
candidate can still occur as the intended name, inside a longer unrelated word, inside a
different name that reads differently, and in both annotated and unannotated positions. The
importer already propagates readings by raw substring search (`EPUBImporter.swift:116-120`),
so the hazard is familiar; a dictionary rule simply moves it upstream into the audio. Phase 2
therefore needs three gates, not one: authoritative provenance, small-kana integrity (§7),
and occurrence/overlap safety across the whole normalized book.

### Mid-word matching confirmed — and it is quiet

Every earlier demonstration that a rule fires happened to place the surface at index 0 of the
submitted text (`黄前久美子です。`), so mid-string matching had never actually been isolated.
It has now been, with an alias long enough that firing is a duration jump rather than a
judgement (2026-08-07):

| rule | position | audio |
|---|---|---|
| 紙 in `紙を買いました。` | index 0, standalone (control) | 1.49 → 4.18 s |
| 紙 in `手紙を書きました。` | **index 1, inside a compound** | 1.52 → 6.72 s |
| 時 in `時計を見てください。` | index 0, inside 時計 | 1.70 → 5.57 s |
| 花 in `花火大会に行きます。` | index 0, inside 花火 | 2.17 → 5.20 s |
| 気 in `天気が良いですね。` | **index 1, inside a compound** | 1.62 → 6.59 s |

All five fire. Position in the string is irrelevant, and being inside a word is no protection
whatsoever. The §8 hazard is a measured property, not a theoretical one.

**The dangerous part is how it sounds when the alias is realistic.** The same three compounds
were also generated with the *correct short* alias (紙→かみ in 手紙, and so on), which should
yield て-かみ instead of てがみ — rendaku lost. On listening, those were **not obviously
wrong**; the corruption is subtle enough to pass. So a colliding rule does not announce
itself: it quietly degrades every occurrence of an unrelated word, throughout a whole book,
in audio that is then cached and paid for. That is a worse failure mode than a loud one, and
it is the reason a collision check cannot be skipped on the grounds that "we would notice".

**The jisho substring check proposed here does not work. Measured, and retracted.** The idea
was to test a candidate against the bundled tap-to-define database — if the surface appears
inside other headwords with incompatible readings, reject it — and thereby "convert most of
'is this rule safe?' from judgement into a query". Run against the shipped
`app/Reader/Resources/jisho-compact.db` (203,627 rows), the count of headwords containing
each candidate as a substring is:

```
黄前 0   希美 0   緑輝 0   鎧塚 0   秀一 0   洛秋 0   明静 0
生れ 0   ← the worked example this section offered as a rule that "qualifies"
山田 0   田中 1   鈴木 1
```

It admits **100 % of the candidate set**, so it discriminates nothing. Worse, it is blind by
construction to the hazard that actually applies: the database is JMdict-derived and contains
no name dictionary, so a name colliding inside another name — the entire risk class for a
proper-noun lexicon — is invisible to it. 山田 returning zero is the proof, not a reassurance.

What survives is much weaker: the query is a **rejection heuristic** and never an admission
criterion. A non-zero result is a reason to lengthen the surface or drop it; a zero result
means nothing at all.

For **book-scoped** rules a real check does exist, and it is the one to build: scan every
occurrence of the candidate in that book's own NFKC-normalized text and require that each
occurrence coincides with an authoritative ruby span carrying the same reading, rejecting
overlapping candidates. That is a bounded, checkable claim about the actual blast radius.

For **global** rules there is no equivalent. No finite dictionary query establishes safety
"in arbitrary Japanese forever", so global admission stays human judgement over a
deliberately short list — which is why §7 pairs it with irreversibility.

### A generic dictionary built from jisho is not an option. Measured.

The tempting fallback for books with no ruby is to synthesize a lexicon from the bundled
dictionary — take every word with exactly one reading and assert it. Two measurements kill it.

**It has zero coverage of the problem.** Exact-match lookups in `jisho-compact.db` for the
eight cases that motivated this entire investigation:

```
黄前 0   希美 0   緑輝 0   鎧塚 0   秀一 0   洛秋 0   明静工科 0   生れ 0
```

Not one of them exists in the database. That is not a coincidence — it is the same fact from
the other side. The model fails on rare proper nouns and pre-war orthography, which is exactly
the class a general vocabulary dictionary does not contain. A jisho-derived lexicon could not
have fixed a single case in §5.

**And it would actively break ordinary text.** 199,298 words have exactly one reading;
50,253 of those are two characters long, the most collision-prone length. Of a 300-entry
sample of those, **219 (73 %) occur inside some other headword** — and under
`word_boundaries: false` every one of those is a rewrite that fires there too. Japanese
compounds change reading precisely at those joins:

```
紙 [かみ]  inside  手紙 [てがみ]      rendaku
時 [とき]  inside  時計 [とけい]
花 [はな]  inside  花火 [はなび]
本 [ほん]  inside  日本 [にほん]
```

A rule 紙→かみ turns 手紙 into て-かみ. Scaled to tens of thousands of entries this
approaches transcribing the book into kana — and kanji are what the model uses to find word
boundaries and pitch accent, so it would degrade the very prosody the feature exists to
protect.

**Conclusion: no generic dictionary, at any size.** For a book with trustworthy ruby, use that
book's ruby. For a book without it, send nothing and let the model read — it already handles
ordinary vocabulary correctly, which is why every failure in §5 was a name.

Two smaller constraints that belong with the above:

- **Rules must be authored in the same normalized form the Worker sends.** `WorkerTTSService`
  NFKC-normalizes at its boundary (`:54`); a rule written in another form silently never
  fires — the same failure mode as the `word_boundaries` default.
- **A surface split across a chunk boundary cannot fire.** `ChunkingTTSService` splits on
  `SynthesisLimits.maxRequestChars`; chapters are capped well below it so this path is not
  exercised today, but it is a silent no-op if that ever changes.

## 9. Review, 2026-08-07 — what blocks shipping

This document was reviewed after it was written, by a second model and an independent
verifier reading the code. §0–§6 survived; the design sections did not, and the corrections
are folded in above. What follows is what remains open, in the order it should be settled.

**Blocking Phase 1:**

1. **A bad locator is a total narration outage. Measured — see §10.** Three of four
   bad-locator cases return **404** with no audio, including an *archived* dictionary. Needs
   the Worker-side fallback in §10 before a locator rides on every request.
2. **Redundant aliases are audible. Measured — see §7.** They add small pauses, so
   "assert everything trustworthy" is out and entries must earn their place. Still open:
   how much of a chapter's prosody a full book lexicon costs in aggregate — four words is not
   a paragraph, and the effect might compound or might vanish in context.
3. **A collision is quiet. Measured — see §8.** Rules fire mid-word, and a realistic colliding
   alias does not sound obviously wrong. So the collision check is mandatory, and the check
   proposed in §8 does not work. **Nothing currently proposed fills this gap for global
   rules** — this is the real blocker.
4. **The narration/furigana divergence** (below), now sharper: 学校 showed the model errs on
   ordinary vocabulary too, so the set of words wanting a global alias is larger than "names",
   and every one of them is a word the page will render with MeCab's reading.

**Blocking Phase 2:** everything in Phase 1, plus `POST`/`PATCH` through the gateway (§3),
archived-quota behaviour (§3), the persisted candidate structure and the raw pre-repair
reading (§7), the cache-identity scoping decision (§7), and idempotent per-book creation
under concurrent chapter requests.

### The divergence nobody had raised

Yomi shows furigana *and* speaks the text, and the two now come from different sources. A
global rule 黄前→おうまえ corrects the **audio only**. Display readings come from MeCab,
overridden by publisher ruby where a book has it (`ReaderModel.swift:151` →
`SourceReadingOverlay.apply`). So in any book without ruby on that surface — TXT, PDF, OCR
output, most EPUBs — the page keeps printing IPADic's きぜん while the voice says おうまえ,
with the highlight tying them together character by character.

For an app whose whole premise is synchronized text and furigana, a visible disagreement
between what is shown and what is heard may be worse than the mispronunciation it fixes. The
admission criterion in §8 is only "is this safe as a substring"; it needs a second clause —
**"and does this agree with what the page will show"** — which in practice means a global
alias should be paired with a display-side reading rather than shipped alone.

This is not a reason to abandon the approach. Book-scoped rules (Phase 2) do not have the
problem at all, because they come from the same ruby that already drives the display. It is a
reason the global phase is narrower than it looked.

## 10. A bad locator is a 404, and archiving causes one

Measured 2026-08-07, production request shape, rule `黄前→おうまえ`:

| locator | result |
|---|---|
| none (baseline) | 200, 1.67 s |
| **archived** dictionary, valid version | **404** `pronunciation_dictionary_not_found` |
| unknown dictionary id | **404** same |
| valid id, wrong `version_id` | **404** same |
| valid id, `version_id` omitted | 200, 1.70 s (rule did not fire) |

Three consequences, and the first one inverts a recommendation made earlier in this document.

**Archiving is not safe cleanup — it is a kill switch.** §3 proposed "create at first
synthesis, archive when the book is deleted", reasoning that archiving made per-book
dictionaries reclaimable. It does, but an archived dictionary stops resolving: any request
still pinning it fails outright rather than degrading. So archiving is only safe once nothing
can reference the dictionary again, and "nothing" has to account for another device that still
has the book, a re-import, and any retry of a failed synthesis. Reference counting is not
optional if per-book dictionaries are archived at all; the safer default is to leave them.

**The Phase 1 global locator is a single point of failure for all narration.** It rides on
every reader request, so a typo in the env var, a stale `version_id` after a lexicon update,
or an accidental archive takes narration to zero — surfaced to the user through
`WorkerTTSService.swift:67-70` as "TTS failed (404)", indistinguishable from a billing
problem. There is no partial failure mode: it is either fine or total.

**The mitigation is small and belongs in the Worker.** On a 404 whose body carries
`pronunciation_dictionary_not_found`, retry once with the locator dropped. That converts the
outage into exactly the degradation everyone assumed it already was — narration continues,
pronunciation is merely uncorrected — and it costs one retry on a path that should never fire.
Pair it with a startup or deploy-time validation of the pinned locator, so a bad env value is
caught before it reaches a user. Note the retry spends characters twice on the failing
request, which is acceptable only because it should be a never-path; do not make it a general
retry policy.

`version_id` may be omitted without a 404, but that is not a fallback: it did not apply the
rule, and an unpinned locator would silently follow the dictionary's latest version, which is
the mutable-shared-state failure §3 exists to avoid.

## Reproducing

Probe scripts are not committed — they create remote resources. The shapes:

- alias firing: create dictionaries differing only in `word_boundaries`, synthesize the
  same text against each, compare durations; include a Latin control so a non-firing rule
  is distinguishable from a broken one, and make the alias long enough that firing is not a
  judgement call.
- alignment fidelity: `scripts/eleven-matrix.mjs` already reports `joinOK`, `audioSec`,
  `alignSec` and backwards starts; add `pronunciation_dictionary_locators` to its request.
- gateway passthrough: `GET {gatewayBase}/elevenlabs/v1/pronunciation-dictionaries` with
  only `cf-aig-authorization`.

Twelve probe dictionaries were created during this investigation and archived afterwards.
