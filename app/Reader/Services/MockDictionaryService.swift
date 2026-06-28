import Foundation
import ReaderCore

/// In-memory dictionary for base UI, seeded from the Yomi design's sample
/// entries and keyed by `dictionary_form` (so tapping an inflected surface —
/// 生まれた, つかぬ — resolves to its lemma 生まれる / つく). Production swaps in a
/// read-only SQLite impl over jisho-seed.db behind the same `DictionaryService`
/// protocol; the headword/reading/senses shape already matches that schema.
final class MockDictionaryService: DictionaryService {
    private let entries: [String: DictionaryEntry]

    init(entries: [String: DictionaryEntry]) { self.entries = entries }

    func lookup(dictionaryForm: String, reading: String?) -> DictionaryEntry? {
        entries[dictionaryForm]
    }

    static func seeded() -> MockDictionaryService {
        var id = 0
        func e(_ word: String, _ reading: String, _ pos: String,
               _ meanings: [String], ex: (String, String)? = nil) -> DictionaryEntry {
            id += 1
            return DictionaryEntry(
                id: id, word: word, reading: reading, priorityRank: 1,
                senses: meanings.map { Sense(glosses: [$0], partsOfSpeech: [pos]) },
                example: ex.map { Example(japanese: $0.0, english: $0.1) }
            )
        }

        let table: [String: DictionaryEntry] = [
            "猫":     e("猫", "ねこ", "noun", ["cat"], ex: ("猫が好きだ。", "I like cats.")),
            "吾輩":   e("吾輩", "わがはい", "pronoun · archaic, pompous first person", ["I; me"], ex: ("吾輩は猫である。", "I am a cat.")),
            "名前":   e("名前", "なまえ", "noun", ["name"], ex: ("名前を教えてください。", "Please tell me your name.")),
            "無い":   e("無い", "ない", "i-adjective", ["nonexistent; not having", "there is not"], ex: ("時間が無い。", "There is no time.")),
            "見当":   e("見当", "けんとう", "noun", ["estimate; guess", "aim; direction"], ex: ("見当がつかない。", "I have no idea.")),
            "生まれる": e("生まれる", "うまれる", "verb · ichidan", ["to be born"], ex: ("どこで生まれたの。", "Where were you born?")),
            "ある":   e("ある", "ある", "verb · godan", ["to be; to exist (inanimate)"], ex: ("机の上にある。", "It is on the desk.")),
            "は":     e("は", "は", "particle", ["topic marker (pronounced \"wa\")"]),
            "で":     e("で", "で", "particle", ["at; in", "by means of"]),
            "まだ":   e("まだ", "まだ", "adverb", ["still; (not) yet"]),
            "どこ":   e("どこ", "どこ", "pronoun", ["where; what place"]),
            "か":     e("か", "か", "particle", ["question marker"]),
            "が":     e("が", "が", "particle", ["subject marker"]),
            "つく":   e("つく", "つく", "verb · godan", ["to attach; to be attached", "(見当が〜) to have a clue"]),
        ]
        return MockDictionaryService(entries: table)
    }
}
