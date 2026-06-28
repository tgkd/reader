#!/usr/bin/env bash
#
# Build a compact, read-only tap-to-define DB from the full jisho-seed.db.
#
# Drops the bulk the reader never uses — the FTS5 tables (words_fts/meanings_fts
# + shadow tables) and the search_ngrams column — plus unused columns/tables,
# and keeps only ONE example per word. Full WORD coverage is preserved so any
# tapped token still resolves; only fuzzy-search infrastructure is removed.
#
# Output (default app/Reader/Resources/jisho-compact.db) is bundled in the Reader
# app and gitignored — regenerate with this script. Lookup uses idx_words_word
# (exact base form), so the dropped FTS indexes don't matter.
#
# Usage: scripts/build-compact-dict.sh [SRC_DB] [OUT_DB]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/../../jisho-data/assets/db/jisho-seed.db}"
OUT="${2:-$HERE/../app/Reader/Resources/jisho-compact.db}"

[ -f "$SRC" ] || { echo "source DB not found: $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

sqlite3 "$OUT" <<SQL
ATTACH DATABASE '$SRC' AS src;

CREATE TABLE words (id INTEGER PRIMARY KEY, word TEXT, reading TEXT, reading_hiragana TEXT, priority_rank INTEGER DEFAULT 999);
INSERT INTO words SELECT id, word, reading, reading_hiragana, priority_rank FROM src.words;

CREATE TABLE meanings (id INTEGER PRIMARY KEY, word_id INTEGER, meaning TEXT, part_of_speech TEXT, misc TEXT, field TEXT);
INSERT INTO meanings SELECT id, word_id, meaning, part_of_speech, misc, field FROM src.meanings;

-- One example per word (the card shows only one); examples are sparse anyway.
CREATE TABLE examples (word_id INTEGER, japanese_text TEXT, english_text TEXT, reading TEXT);
INSERT INTO examples SELECT word_id, japanese_text, english_text, reading FROM src.examples
  WHERE word_id IS NOT NULL AND id IN (SELECT MIN(id) FROM src.examples WHERE word_id IS NOT NULL GROUP BY word_id);

CREATE INDEX idx_words_word ON words(word);
CREATE INDEX idx_words_reading ON words(reading);
CREATE INDEX idx_words_reading_hiragana ON words(reading_hiragana);
CREATE INDEX idx_meanings_word_id ON meanings(word_id);
CREATE INDEX idx_examples_word_id ON examples(word_id);

DETACH DATABASE src;
VACUUM;
SQL

echo "Built $OUT ($(ls -lh "$OUT" | awk '{print $5}'))"
sqlite3 "$OUT" "SELECT 'words', COUNT(*) FROM words UNION ALL SELECT 'meanings', COUNT(*) FROM meanings UNION ALL SELECT 'examples', COUNT(*) FROM examples;"
