import Foundation

/// A reading the SOURCE gave for a run of the chapter's text — publisher ruby,
/// not something inferred.
///
/// This exists because the tokenizer cannot supply these. MeCab + IPADic is
/// reliable on ordinary words and does not know proper nouns, which is exactly
/// where a publisher bothers to annotate: measured on 響け！ユーフォニアム 2, the
/// book reads 黄前 as おうまえ where MeCab says きぜん, 希美 as のぞみ where MeCab
/// says きみ, 鎧塚 as よろいづか where MeCab drops the rendaku, and 緑輝 as
/// サファイア — which is not a reading at all but a name, and which nothing but the
/// book could ever produce. The import used to delete all 370 of the book's ruby
/// annotations on the grounds that the reader renders its own furigana.
///
/// `start`/`length` are character offsets into `Chapter.text` AS STORED — the raw
/// imported string, before any normalization. `surface` is carried as a checksum:
/// if the range no longer extracts it (a chapter edited or re-split under an older
/// build, a corrupted file), the annotation is dropped rather than trusted, because
/// a misplaced reading is worse than an absent one.
public struct SourceReading: Codable, Equatable, Sendable {
    public let start: Int
    public let length: Int
    public let surface: String
    public let reading: String

    public init(start: Int, length: Int, surface: String, reading: String) {
        self.start = start
        self.length = length
        self.surface = surface
        self.reading = reading
    }

    public var end: Int { start + length }
}

public extension Array where Element == SourceReading {
    /// Keep only annotations that still describe `text`: in range, non-empty, and
    /// extracting exactly the surface they were recorded with. Overlaps are
    /// resolved by keeping the earlier one, so a later bad annotation can never
    /// displace a good one.
    func validated(against text: String) -> [SourceReading] {
        // Spelled out: inside `extension Array where Element == SourceReading`,
        // a bare `Array(text)` resolves to `[SourceReading]`.
        let chars = [Character](text)
        var kept: [SourceReading] = []
        for r in sorted(by: { $0.start < $1.start }) {
            guard r.length > 0, !r.reading.isEmpty,
                  r.start >= 0, r.end <= chars.count,
                  String(chars[r.start..<r.end]) == r.surface,
                  r.start >= (kept.last?.end ?? 0) else { continue }
            kept.append(r)
        }
        return kept
    }
}

/// Applies source readings to a tokenizer's output.
///
/// The tokens come from `Normalize.nfkc(text)` while the annotations index the raw
/// `text`, so the offsets have to be carried across that boundary — done here once
/// per chapter by normalizing prefixes, then verified by comparing surfaces. A
/// mismatch drops the annotation instead of moving a reading somewhere it does not
/// belong.
public enum SourceReadingOverlay {

    /// Replace `reading` on every token the annotations cover EXACTLY.
    ///
    /// A token is rewritten only when one or more consecutive annotations TILE it with
    /// no gap and no overhang. That covers the two shapes real markup produces:
    ///
    ///   • one annotation per token — 黄/おう then 前/まえ, which MeCab also splits;
    ///   • several annotations inside one token — the book writes 秀一 as 秀/しゆう plus
    ///     一/いち while MeCab keeps 秀一 whole and reads it ひでかず. Concatenating the
    ///     run gives しゅういち. Before this, per-character ruby simply lost against any
    ///     token coarser than itself, and a character's name was read wrong.
    ///
    /// The reverse — ONE annotation spanning SEVERAL tokens, as with 緑輝 (one ruby base,
    /// two MeCab tokens, read サファイア) — is still not applied. Putting the reading on
    /// the first token would render サファイア over 緑 and leave 輝 bare, and spreading
    /// one interval across several tokens gives them all the same start, which
    /// `SpanTimeline.index(at:)` — a rightmost search — resolves to the last of them, so
    /// the earlier ones would never highlight. That case needs the renderer to take
    /// ranges rather than tokens; until then those annotations are carried, not applied.
    /// Tiling has no such problem: it writes ONE token's reading and changes no spans.
    ///
    /// `dictionaryForm` is untouched: the lemma stays MeCab's, so tap-to-define keeps
    /// looking up 黄前 rather than おうまえ.
    public static func apply(_ readings: [SourceReading],
                             to tokens: [Token],
                             text: String) -> [Token] {
        let valid = readings.validated(against: text)
        guard !valid.isEmpty else { return tokens }

        // Raw offset → normalized offset. NFKC is applied to the whole string
        // downstream, so a prefix's normalized length is where that prefix ends in the
        // tokens' coordinate system. Memoized because adjacent annotations share an
        // endpoint, and the prefix scan is the expensive part of opening a chapter.
        let raw = Array(text)
        var normalizedCache: [Int: Int] = [:]
        func normalized(_ rawOffset: Int) -> Int {
            if let hit = normalizedCache[rawOffset] { return hit }
            let n = Normalize.nfkc(String(raw[0..<rawOffset])).count
            normalizedCache[rawOffset] = n
            return n
        }

        // Annotations keyed by where they begin in the tokens' coordinate system.
        var startingAt: [Int: (end: Int, reading: SourceReading)] = [:]
        for r in valid { startingAt[normalized(r.start)] = (normalized(r.end), r) }

        var out = tokens
        var offset = 0
        for (i, token) in tokens.enumerated() {
            let start = offset
            let end = offset + token.surface.count
            offset = end

            // Walk annotations forward from the token's start. They must land exactly on
            // its end — a run that overshoots belongs to a coarser span than this token.
            var position = start
            var parts: [SourceReading] = []
            while position < end, let hit = startingAt[position], hit.end <= end {
                parts.append(hit.reading)
                position = hit.end
            }
            guard position == end, !parts.isEmpty,
                  Normalize.nfkc(parts.map(\.surface).joined()) == token.surface else { continue }

            out[i] = Token(surface: token.surface,
                           reading: preferred(book: parts.map(\.reading).joined(),
                                              tokenizer: token.reading),
                           dictionaryForm: token.dictionaryForm)
        }
        return out
    }

    /// Which of the two readings to trust when both describe the same token.
    ///
    /// The book wins by default — that is the whole point of reading its ruby. But when
    /// the two agree apart from small kana they are the SAME reading of the same word,
    /// and then the tokenizer's spelling is authoritative: a book from a flattened
    /// source writes 饒舌 as じようぜつ where MeCab has じょうぜつ, and taking the book's
    /// there replaces a correct reading with a broken one.
    ///
    /// This also bounds `KanaRepair.restoreSmallKana`. Restoring is a judgement — しよう
    /// is しょう for 少 but しよう for 使用 — and on any word the tokenizer knows, this
    /// comparison silently corrects a wrong restoration, in either direction, because it
    /// compares in the flattened space where both spellings look the same.
    static func preferred(book: String, tokenizer: String?) -> String {
        guard let tokenizer, !tokenizer.isEmpty,
              KanaRepair.flattened(tokenizer) == KanaRepair.flattened(book) else { return book }
        return tokenizer
    }
}
