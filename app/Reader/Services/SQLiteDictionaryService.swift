import Foundation
import SQLite3
import ReaderCore

/// Read-only tap-to-define over the bundled compact dictionary DB (built by
/// `scripts/build-compact-dict.sh` from jisho-seed.db). Opens it `immutable=1`
/// (no -wal/-shm, no locking — correct for a shipped read-only seed) and resolves
/// a MeCab `dictionary_form` (+ the reading from the same tokenize pass, to
/// disambiguate homographs) to a `DictionaryEntry`.
///
/// Failable init: returns nil when the DB isn't bundled, so `AppServices` can
/// fall back to the seeded mock.
final class SQLiteDictionaryService: DictionaryService {
    private let db: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(resource: String = "jisho-compact", ext: String = "db") {
        guard let path = Bundle.main.path(forResource: resource, ofType: ext) else { return nil }
        var handle: OpaquePointer?
        let uri = "file:\(path)?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let handle else { return nil }
        db = handle
    }

    deinit { sqlite3_close(db) }

    func lookup(dictionaryForm: String, reading: String?) -> DictionaryEntry? {
        let readingHira = reading ?? ""   // MeCab readings are already hiragana

        // Step 1: best entry id — match the headword, tie-break to the reading
        // (homographs like 上 うえ/かみ/じょう), then commonness. Fall back to a
        // kana/reading match for base forms not stored as `word` (する/いる…).
        var id = firstId("""
            SELECT id FROM words WHERE word = ?1
            ORDER BY (reading_hiragana = ?2) DESC, priority_rank ASC, id ASC LIMIT 1;
            """, [.text(dictionaryForm), .text(readingHira)])
        if id == nil {
            id = firstId("""
                SELECT id FROM words WHERE reading = ?1 OR reading_hiragana = ?1
                ORDER BY priority_rank ASC, id ASC LIMIT 1;
                """, [.text(dictionaryForm)])
        }
        guard let wordId = id else { return nil }

        // Step 2: senses in JMdict order; POS is empty on continuation senses,
        // so carry the last non-empty POS forward.
        let senseRows = query("""
            SELECT w.word, w.reading, w.priority_rank, m.meaning, m.part_of_speech, m.misc, m.field
            FROM words w JOIN meanings m ON m.word_id = w.id
            WHERE w.id = ?1 ORDER BY m.id;
            """, [.int(wordId)])
        guard let head = senseRows.first else { return nil }

        var senses: [Sense] = []
        var lastPOS: [String] = []
        for r in senseRows {
            let glosses = split(r.text("meaning"), "; ")
            guard !glosses.isEmpty else { continue }
            var pos = split(r.text("part_of_speech"), ", ")
            if pos.isEmpty { pos = lastPOS } else { lastPOS = pos }
            senses.append(Sense(glosses: glosses, partsOfSpeech: pos,
                                misc: nonEmpty(r.text("misc")), field: nonEmpty(r.text("field"))))
        }
        guard !senses.isEmpty else { return nil }

        // Step 3: one example (optional — only ~5% of entries have one).
        let example = query("SELECT japanese_text, english_text, reading FROM examples WHERE word_id = ?1 LIMIT 1;",
                            [.int(wordId)]).first.flatMap { r -> Example? in
            guard let jp = r.text("japanese_text"), let en = r.text("english_text") else { return nil }
            return Example(japanese: jp, english: en, reading: r.text("reading"))
        }

        return DictionaryEntry(
            id: wordId,
            word: head.text("word") ?? dictionaryForm,
            reading: head.text("reading") ?? readingHira,
            priorityRank: head.int("priority_rank") ?? 999,
            senses: senses,
            example: example)
    }

    // MARK: - Tiny read-only query layer (crib of JishoCore/Database.swift)

    private enum Bind { case text(String); case int(Int) }

    private struct Row {
        let cols: [String: Any]
        func text(_ k: String) -> String? { cols[k] as? String }
        func int(_ k: String) -> Int? { (cols[k] as? Int64).map(Int.init) }
    }

    private func firstId(_ sql: String, _ binds: [Bind]) -> Int? {
        query(sql, binds).first?.int("id")
    }

    private func query(_ sql: String, _ binds: [Bind]) -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            }
        }
        let n = sqlite3_column_count(stmt)
        let names = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var cols: [String: Any] = [:]
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: cols[names[Int(c)]] = sqlite3_column_int64(stmt, c)
                case SQLITE_NULL: break
                default:
                    if let t = sqlite3_column_text(stmt, c) { cols[names[Int(c)]] = String(cString: t) }
                }
            }
            rows.append(Row(cols: cols))
        }
        return rows
    }

    private func split(_ s: String?, _ sep: String) -> [String] {
        (s ?? "").components(separatedBy: sep)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
