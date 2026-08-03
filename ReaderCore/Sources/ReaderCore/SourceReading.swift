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

    /// Replace `reading` on every token an annotation covers EXACTLY.
    ///
    /// Deliberately exact-match only. An annotation that spans several tokens
    /// (`緑輝` is one ruby base but two MeCab tokens) is left alone here: putting its
    /// reading on the first token would render サファイア over 緑 and leave 輝 bare,
    /// and spreading one interval across several tokens gives them all the same
    /// start — which `SpanTimeline.index(at:)`, a rightmost search, resolves to the
    /// last of them, so the earlier ones would never highlight. Rendering a ruby base
    /// that spans tokens needs the renderer to take ranges rather than tokens; until
    /// then those annotations are carried but not applied.
    ///
    /// `dictionaryForm` is untouched: the lemma stays MeCab's, so tap-to-define keeps
    /// looking up 黄前 rather than おうまえ.
    public static func apply(_ readings: [SourceReading],
                             to tokens: [Token],
                             text: String) -> [Token] {
        let valid = readings.validated(against: text)
        guard !valid.isEmpty else { return tokens }

        // Raw offset → normalized offset. NFKC is applied to the whole string
        // downstream, so a prefix's normalized length is where that prefix ends in
        // the tokens' coordinate system.
        let raw = Array(text)
        var normalizedStart: [Int: Int] = [:]
        for r in valid {
            normalizedStart[r.start] = Normalize.nfkc(String(raw[0..<r.start])).count
        }

        // Token index by normalized start offset.
        var offset = 0
        var startOfToken: [Int: Int] = [:]
        for (i, t) in tokens.enumerated() {
            startOfToken[offset] = i
            offset += t.surface.count
        }

        var out = tokens
        for r in valid {
            guard let nStart = normalizedStart[r.start],
                  let ti = startOfToken[nStart],
                  out[ti].surface == Normalize.nfkc(r.surface) else { continue }
            out[ti] = Token(surface: out[ti].surface,
                            reading: r.reading,
                            dictionaryForm: out[ti].dictionaryForm)
        }
        return out
    }
}
