# Starter books (bundled, seeded on first launch)

Eight short public-domain works from **青空文庫 (Aozora Bunko)**, converted to EPUB3 by
`scripts/build-starter-books.py` into `app/Reader/Resources/StarterBooks/`. They seed the
library on a fresh install and stay available from the Library `+` menu → *Sample Books*.
Seeding writes the eight ids to `reader.starterSeedPending` before the first save and strikes
each only once its own write has flushed, so a first launch killed mid-seed finishes the
remaining books on the next launch rather than shipping a half-seeded library.

Nothing but `.epub` may live in that resource directory — `project.yml` takes all of
`Reader/`, so any stray file there ships inside the app.

These are **committed**, unlike `jisho-compact.db`: together they are under 100 KB, and
committing them keeps Xcode Cloud from needing network access to aozora.gr.jp at build time.

| File | Work | Author | Chars | Chapters |
|---|---|---|---:|---:|
| `yamanashi.epub` | やまなし | 宮沢賢治 | 2,874 | 3 |
| `kumo-no-ito.epub` | 蜘蛛の糸 | 芥川竜之介 | 3,203 | 3 |
| `gon-gitsune.epub` | ごん狐 | 新美南吉 | 5,189 | 6 |
| `chumon-no-oi-ryoriten.epub` | 注文の多い料理店 | 宮沢賢治 | 5,937 | 1 |
| `rashomon.epub` | 羅生門 | 芥川竜之介 | 6,370 | 1 |
| `lemon.epub` | 檸檬 | 梶井基次郎 | 5,426 | 1 |
| `sangetsuki.epub` | 山月記 | 中島敦 | 6,977 | 1 |
| `yume-juya.epub` | 夢十夜 | 夏目漱石 | 19,359 | 10 |

Chapter counts are the converter's own splits on Aozora headings; oversized ones are split
again at import by `Chapter.maxRenderableChars`.

## Why EPUB and not Aozora text

The XHTML editions carry real `<ruby><rb>…</rb><rt>…</rt></ruby>`, which `EPUBImporter`
turns into `Chapter.sourceReadings` → `PronunciationLexicon` → correct narration of names.
Routing the plain-text editions through `TextImporter` would throw all of that away.

## Gaiji

Characters outside JIS X 0208 ship from Aozora as `<img class="gaiji"
alt="※(「てへん＋丑」、第4水準2-12-93)">`. `EPUBImporter.plain()` strips tags inside `<rb>`,
so an unresolved one would delete the ruby base outright. The converter resolves every
kuten code against the JIS X 0213 table from x0213.org and **exits non-zero on any it
cannot map** — 46 occurrences across these eight, 10 distinct characters. One of them,
`𤄃` (U+24103) in `檸檬`, is outside the BMP, so it also exercises the surrogate-pair path.

## What these books exposed

Auditing all 1,881 of their ruby annotations (`StarterBooksFuriganaProbe`) found the
overlay was discarding **305 of them, 139 distinct readings the book had spelled out and
the tokenizer got wrong** — character names (兵十 ひょうじゅう → へいじゅう, 犍陀多 かんだた),
counters (二人 ふたり → ににん), and gikun no dictionary can derive (洋杖 ステッキ → ようつえ,
快速調 アッレグロ). `bookReadings` accepted an annotation only if it fitted inside one MeCab
token, and MeCab segments by grammar while ruby marks a word. `SourceReadingOverlay` now
joins the token run an annotation covers. ごん狐 was the worst hit at 50 % applied.

## Provenance / license

All eight are 著作権消滅 (`作品著作権フラグ = なし` in Aozora's own index, which the converter
re-checks on every run and refuses to build otherwise). Aozora's terms allow free copying
and redistribution "有償・無償であるかを問わず" and *request* — do not require — that the
identifying information be kept. It is: each OPF carries `dc:source` (底本), `dc:rights`
and `dc:contributor` (入力者 / 校正者), and Settings → About credits 青空文庫.

## Regenerating

```bash
python3 scripts/build-starter-books.py     # caches downloads under build/aozora-cache/
```

Output is deterministic (fixed zip timestamps), so an unchanged upstream re-generates
byte-identical files. `StarterBooksTests` asserts the bundle matches `StarterLibrary`
and that ruby offsets still land on their own surfaces.
