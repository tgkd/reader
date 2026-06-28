# Design prompt — for claude.ai (visual mockup)

Paste the block below into a fresh **claude.ai** conversation to generate an
interactive iPhone mockup (HTML/CSS artifact) of the reader app. It is
self-contained — it does **not** assume any repo context — so it can be handed
to a design-only session. Iterate by replying to the artifact ("make the
highlight softer", "show the dark theme", "try the reader in yokogaki", etc.).

Decisions baked in (from the working session): **calm, paper-like, Apple
Books-register** aesthetic; three navigable screens **Library → Reader →
Dictionary sheet**; both **vertical (tategaki)** and horizontal reading; the
**word-synced highlight is animated** so the core feature can actually be judged.

---

```
You are a senior product designer. Design and build an interactive, clickable
visual mockup of an iOS app as a single self-contained artifact I can view and
tap through. This is a *design* deliverable (look, feel, layout, motion), not a
production app — mock all data, no backend.

## The app

A Japanese **reader** for learners and readers of Japanese. You load a Japanese
text (a novel, an article) and it plays high-quality narration while
**highlighting each word in sync with the audio** — like a karaoke read-along for
prose. Three things make it distinctive, and the design must serve all three:

1. **Word-synced highlighting.** As the narration speaks, the currently-spoken
   *word* is softly highlighted and the highlight glides word to word. Japanese
   has no spaces between words, so this word-by-word highlight is the whole point
   — it shows the reader where they are. This must feel calm and precise, never
   flickery or loud.
2. **Furigana.** Tiny kana pronunciation guides sit above (horizontal) or to the
   right of (vertical) each kanji, so a learner can read unfamiliar characters.
   Render these as real ruby text (`<ruby>漢字<rt>かな</rt></ruby>`), sized ~50%
   of the base text, in a muted color so they assist without shouting.
3. **Tap-to-define.** Tapping any word opens a dictionary definition — reading,
   part of speech, meanings, an example — as a sheet that rises from the bottom.

## Screens (make them navigable — tapping moves between them)

### 1. Library (home)
A quiet list of texts the reader has added. Each row: title (Japanese, with the
author in smaller text), a thin progress indicator (e.g. "42%" or a slim bar),
and a small marker if it has cached audio. Calm, generous spacing, content-first.
A simple top bar with the app wordmark and a single "+" to add a text. Tapping a
row opens the Reader. Use these mock entries (real works, so it reads true):
  • 吾輩は猫である — 夏目漱石 — 42%
  • こころ — 夏目漱石 — 0% (not started)
  • 銀河鉄道の夜 — 宮沢賢治 — 88%
  • 走れメロス — 太宰治 — 100% (finished)

### 2. Reader (the heart of the app — spend the most care here)
The reading surface fills the screen; UI chrome is minimal and recedes while
reading. Requirements:

  • **Support BOTH orientations with a toggle:**
    - **Tategaki (vertical):** top-to-bottom, columns flowing right-to-left
      (`writing-mode: vertical-rl`). Furigana sits to the *right* of each kanji.
      This is the authentic novel-reading mode — showcase it as the default for
      the Reader screen.
    - **Yokogaki (horizontal):** normal left-to-right; furigana sits *above*
      kanji. Provide a clear, unobtrusive toggle between the two modes.
  • **Furigana** over/beside every kanji, muted, ~50% size. (Use the readings I
    give below — don't invent furigana.)
  • **The synced highlight, ANIMATED.** Include a play/pause control; when
    playing, animate the highlight advancing word by word through the visible
    text on a timer (roughly one word every ~350–500 ms), looping, so I can
    actually see and judge the highlight-in-motion. The highlight should be a
    *soft* treatment fitting a paper aesthetic — e.g. a gentle warm tint behind
    the word, or a soft underline/marker — NOT a hard saturated yellow box.
    Show me the moving highlight; it is the single most important thing to get
    right.
  • **A slim audio transport** at the bottom: play/pause, a thin scrubber/progress
    line with elapsed/total time, and a speed control (0.75× / 1.0× / 1.25×).
    It should be able to fade/tuck away so the text is unobstructed, and reappear
    on tap. No big skeuomorphic player.
  • A minimal top area: chapter/work title, a back affordance to Library, and the
    orientation toggle. Tapping any word opens the Dictionary sheet (screen 3).

### 3. Dictionary sheet (tap-to-define)
A bottom sheet that rises over the Reader (the Reader stays dimmed behind it,
~⅓ to ½ height, draggable feel). For a tapped word it shows: the word large with
its reading in furigana/kana, part of speech, 1–3 numbered English meanings, one
short example sentence, and a "save to list" affordance. A small "play this word"
button. Dismiss by swiping down or tapping the dimmed area. Demonstrate it for
the word 猫 (ねこ): noun, "cat"; example 「猫が好きだ。」("I like cats.").

## Aesthetic direction — calm, paper-like, content-first (Apple Books register)

  • The **text is the hero**; the UI is quiet and gets out of the way. Generous
    margins, restful line/column spacing, nothing competing with the prose.
  • **Two themes, toggleable:** a light "paper" theme (warm off-white, soft ink —
    not pure #fff/#000) and a dark/night theme (deep neutral, gentle off-white
    text). Optionally a sepia in between. Make the theme toggle visible.
  • **Typography:** for Japanese *reading* body, use a Mincho (serif) feel —
    `"Hiragino Mincho ProN", "Yu Mincho", "Songti SC", serif`; for UI labels use
    a Gothic/sans — `"Hiragino Sans", "Yu Gothic", -apple-system, system-ui,
    sans-serif`. Latin UI text in SF/system. A clear, literary type scale.
  • **Restraint:** NO gradients, NO colored/heavy shadows, NO emoji. At most one
    quiet accent color, used sparingly (e.g. the highlight, progress, the active
    toggle). Hairline separators, not boxes everywhere. iOS-native motion: gentle,
    quick, eased — sheets slide, the highlight glides, transitions don't bounce.

## Sample content — use exactly this, with these furigana readings

Reader passage (Natsume Sōseki, opening of 吾輩は猫である):

  吾輩（わがはい）は猫（ねこ）である。名前（なまえ）はまだ無（な）い。
  どこで生（う）まれたかとんと見当（けんとう）がつかぬ。

So the ruby pairs are: 吾輩→わがはい, 猫→ねこ, 名前→なまえ, 無→な, 生→う,
見当→けんとう. Kana (は, である, まだ, い, どこで, まれたかとんと, がつかぬ)
take no furigana. Word boundaries for the highlight (each is one "word" the
highlight lands on): 吾輩 / は / 猫 / で / ある / 。/ 名前 / は / まだ / 無い / 。
/ どこ / で / 生まれた / か / とんと / 見当 / が / つかぬ / 。

## Build constraints

  • **One self-contained artifact.** React with **plain CSS / inline styles — NO
    Tailwind**, or a single vanilla HTML+CSS+JS file. No external UI kits, no CSS
    frameworks, no icon libraries (draw simple SF-style glyphs inline or use Unicode).
  • Render inside a realistic **iPhone frame** (≈393×852, rounded corners,
    Dynamic Island, status bar) centered on a neutral backdrop.
  • **Interactive:** I can tap a Library row → Reader; tap a word → Dictionary
    sheet → dismiss; toggle theme; toggle orientation; press play and watch the
    highlight animate.
  • Use real ruby markup for furigana and real `writing-mode: vertical-rl` for
    tategaki — don't fake either with absolute positioning.
  • A placeholder wordmark is fine (e.g. "Yomi") — the app isn't named yet.

Deliver the artifact, then give me a 4–6 line note on the key design choices you
made (highlight treatment, type, color, how tategaki + furigana read) and any one
alternative you'd want me to consider.
```

---

## Notes for iterating

- The single highest-value thing to scrutinize in the result is the **animated
  highlight** — a static screenshot can't tell you if it reads as calm vs.
  flickery. Press play and watch it glide.
- If the first pass feels too generic/templated, reply: *"Give me 2–3 distinctly
  different directions for the reader surface — vary the highlight treatment and
  the tategaki margins."*
- When a direction is chosen, the SwiftUI translation path is the
  `figma-swiftui` skill or a direct "build these screens in SwiftUI, iOS 17"
  follow-up; the real furigana renderer is `CTRubyAnnotation`
  (crib `ios-native/Jisho/Jisho/Furigana.swift`).
