# Sample books (manual import / dev testing)

Public-domain Japanese texts from **青空文庫 (Aozora Bunko)**, converted into the
formats the importers accept. Use them to exercise the import → tokenize → render →
(OCR) paths in the real app; they are **not** unit-test fixtures.

| File | Format | Source | Exercises |
|---|---|---|---|
| `こころ（夏目漱石）.epub` | EPUB3, extractable text + `<ruby>` furigana | 夏目漱石『こころ』 | Long book: ~182k chars, **113 spine chapters** (spine ordering). Many sections exceed `Chapter.maxRenderableChars` (~4k) → **oversized-chapter auto-split**. `<rt>/<rp>` ruby present → the importer's furigana-strip path. Free (extracted text, no OCR). |
| `銀河鉄道の夜（宮沢賢治）.pdf` | PDF, born-digital text layer (HeiseiMin-W3) | 宮沢賢治『銀河鉄道の夜』 | **65 pages → 65 chapters**. Real `PDFPage.string` text layer → no OCR, no subscription. |
| `こころ（スキャン版）.epub` | EPUB3, fixed-layout, `<img>`-only (no text) | 夏目漱石『こころ』(rendered) | **Image-only spine** → `.images` slot → cloud OCR. Non-subscriber → Membership prompt (`ocrUnavailable`); subscriber → OCR in bounded windows (16 pages crosses the 8-page window). |
| `銀河鉄道の夜（スキャン版）.pdf` | PDF, image-only pages (no text) | 宮沢賢治『銀河鉄道の夜』(rendered) | **No text layer** (16 bitmap pages) → OCR path, same membership gate as above. |

## Provenance / license

All source texts are public domain (author died > 70 years ago) via Aozora Bunko
(<https://www.aozora.gr.jp/>). The scanned variants are the same texts rendered to
grayscale page bitmaps (Hiragino Mincho) — synthetic "scans", not real scans.

## Regenerating

The generator scripts (`build.py`, `build_scanned.py`) live outside the repo; they
clean the Aozora Shift-JIS source (strip header/footer/notes, convert `｜base《reading》`
ruby), then emit these files. Ask if you want them checked in.
