import XCTest
import ReaderCore
@testable import Reader

final class RubyCoverageProbe: XCTestCase {
    private struct SurfaceFacts {
        let surface: String
        let bookReadings: Set<String>
        let annotatedCount: Int
        let occurrences: Int
        let alignedOccurrences: Int
        let mecabReadings: Set<String>
    }

    private func hiragana(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map {
            (0x30A1...0x30F6).contains($0.value)
                ? Unicode.Scalar($0.value - 0x60)! : $0
        }))
    }

    private func folded(_ s: String) -> String {
        KanaRepair.flattened(hiragana(s))
    }

    private func isKanaCharacter(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy {
            (0x3041...0x3096).contains($0.value)
                || (0x30A1...0x30FA).contains($0.value)
                || $0.value == 0x30FC
                || $0.value == 0x309B || $0.value == 0x309C
        }
    }

    private func isKana(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(isKanaCharacter)
    }

    private func occurrences(of needle: [Character], in hay: [Character]) -> [Int] {
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        var hits: [Int] = []
        for i in 0...(hay.count - needle.count)
        where Array(hay[i..<(i + needle.count)]) == needle {
            hits.append(i)
        }
        return hits
    }

    func testRubyCoverageAcrossStarterBooks() async throws {
        let tokenizer = try MeCabTokenizer()

        var totalOcc = 0, totalAdmittedOcc = 0, totalRelaxedOcc = 0
        var totalAlignedOcc = 0, totalAdmittedAligned = 0, totalVouched = 0
        var totalFreeAligned = 0, totalRealLossAligned = 0
        var totalFree = 0, totalRealLoss = 0, totalInconsistent = 0, totalSurfaces = 0
        var gateTotals: [String: Int] = [:]
        var lossTotals: [String: Int] = [:]

        for book in StarterLibrary.books {
            guard let url = StarterLibrary.url(for: book) else { continue }
            let document = try await Importer.document(from: url)

            var tokensByIndex: [Int: [Token]] = [:]
            for (i, chapter) in document.chapters.enumerated()
            where !chapter.sourceReadings.isEmpty {
                tokensByIndex[i] = tokenizer.tokenize(chapter.text)
            }
            let lexicon = PronunciationLexicon.build(chapters: document.chapters,
                                                     tokens: tokensByIndex)

            var bookReadings: [String: Set<String>] = [:]
            var annotatedCount: [String: Int] = [:]
            for chapter in document.chapters {
                for r in chapter.sourceReadings.validated(against: chapter.text) {
                    let s = Normalize.nfkc(r.surface)
                    bookReadings[s, default: []].insert(Normalize.nfkc(r.reading))
                    annotatedCount[s, default: 0] += 1
                }
            }

            var occTotal: [String: Int] = [:]
            var occAligned: [String: Int] = [:]
            var mecabReadings: [String: Set<String>] = [:]

            for (i, chapter) in document.chapters.enumerated() {
                let text = Array(Normalize.nfkc(chapter.text))
                let tokens = tokensByIndex[i] ?? tokenizer.tokenize(chapter.text)
                var startOfToken: [Int: Int] = [:]
                var cursor = 0
                for (t, token) in tokens.enumerated() {
                    startOfToken[cursor] = t
                    cursor += token.surface.count
                }
                for surface in bookReadings.keys {
                    let needle = Array(surface)
                    for at in occurrences(of: needle, in: text) {
                        occTotal[surface, default: 0] += 1
                        guard let t = startOfToken[at], tokens[t].surface == surface else { continue }
                        occAligned[surface, default: 0] += 1
                        if let reading = tokens[t].reading {
                            mecabReadings[surface, default: []].insert(folded(reading))
                        }
                    }
                }
            }

            let facts = bookReadings.keys.map { s in
                SurfaceFacts(surface: s,
                             bookReadings: bookReadings[s] ?? [],
                             annotatedCount: annotatedCount[s] ?? 0,
                             occurrences: occTotal[s] ?? 0,
                             alignedOccurrences: occAligned[s] ?? 0,
                             mecabReadings: mecabReadings[s] ?? [])
            }

            let admitted = Set(lexicon.rules.map(\.surface))
            var gateOf: [String: String] = [:]
            var gateCounts: [String: Int] = [:]
            for c in lexicon.rejected {
                let key: String
                switch c.rejection {
                case .singleCharacterBase: key = "singleCharacterBase"
                case .ambiguousInBook: key = "ambiguousInBook"
                case .readingNotKana: key = "readingNotKana"
                case .readingMatchesSurface: key = "readingMatchesSurface"
                case .unannotatedOccurrence: key = "unannotatedOccurrence"
                case .insideLongerReading: key = "insideLongerReading"
                case .unconfirmedRepair: key = "unconfirmedRepair"
                case .none: key = "none"
                }
                gateOf[c.surface] = key
                gateCounts[key, default: 0] += 1
                gateTotals[key, default: 0] += 1
            }

            var occ = 0, admittedOcc = 0, relaxedOcc = 0
            var alignedOcc = 0, admittedAligned = 0, vouchedOcc = 0
            var freeAligned = 0, realLossAligned = 0
            var free = 0, realLoss = 0, inconsistent = 0
            var lossByGate: [String: Int] = [:]
            var relaxedGains: [(String, Int, String, String)] = []
            var inconsistentExamples: [(String, [String])] = []

            for f in facts {
                occ += f.occurrences
                alignedOcc += f.alignedOccurrences
                vouchedOcc += min(f.annotatedCount, f.alignedOccurrences)
                if admitted.contains(f.surface) {
                    admittedOcc += f.occurrences
                    admittedAligned += f.alignedOccurrences
                }
                if f.mecabReadings.count > 1 {
                    inconsistent += 1
                    if inconsistentExamples.count < 6 {
                        inconsistentExamples.append((f.surface, f.mecabReadings.sorted()))
                    }
                }
                guard let bookReading = f.bookReadings.first, f.bookReadings.count == 1 else {
                    continue
                }
                let agrees = f.mecabReadings.count == 1
                    && folded(bookReading) == f.mecabReadings.first!
                if !admitted.contains(f.surface) {
                    if agrees { free += f.occurrences } else { realLoss += f.occurrences }
                    if agrees {
                        freeAligned += f.alignedOccurrences
                    } else {
                        realLossAligned += f.alignedOccurrences
                        let why = gateOf[f.surface] ?? "noCandidate"
                        lossByGate[why, default: 0] += f.alignedOccurrences
                        lossTotals[why, default: 0] += f.alignedOccurrences
                    }
                }

                let sameTokenEverywhere = f.occurrences > 0
                    && f.alignedOccurrences == f.occurrences
                let relaxedOK = f.surface.count > 1
                    && isKana(bookReading)
                    && bookReading != f.surface
                    && sameTokenEverywhere
                    && f.mecabReadings.count <= 1
                if relaxedOK {
                    relaxedOcc += f.occurrences
                    if !admitted.contains(f.surface) {
                        relaxedGains.append((f.surface, f.occurrences, bookReading,
                                             f.mecabReadings.first ?? "-"))
                    }
                }
            }

            totalOcc += occ
            totalAlignedOcc += alignedOcc
            totalAdmittedAligned += admittedAligned
            totalVouched += vouchedOcc
            totalFreeAligned += freeAligned
            totalRealLossAligned += realLossAligned
            totalAdmittedOcc += admittedOcc
            totalRelaxedOcc += relaxedOcc
            totalFree += free
            totalRealLoss += realLoss
            totalInconsistent += inconsistent
            totalSurfaces += facts.count

            func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "-" : "\(100 * n / d)%" }

            print("COV ══ \(book.id)")
            print("COV   surfaces \(facts.count), occurrences \(occ), "
                  + "rules \(lexicon.rules.count)")
            print("COV   raw-substring occurrences \(occ), token-aligned \(alignedOcc), "
                  + "book-vouched \(vouchedOcc)")
            print("COV   covered now      \(admittedOcc)\t\(pct(admittedOcc, occ))")
            print("COV   covered ALIGNED  \(admittedAligned)\t\(pct(admittedAligned, alignedOcc))")
            print("COV   ALIGNED rejected: free \(freeAligned), real loss \(realLossAligned)")
            for (k, v) in lossByGate.sorted(by: { $0.value > $1.value }) {
                print("COV     loss-by-gate \(k) \(v)")
            }
            print("COV   covered relaxed  \(relaxedOcc)\t\(pct(relaxedOcc, occ))")
            print("COV   rejected: free (mecab already right) \(free), "
                  + "real loss \(realLoss)")
            print("COV   mecab self-inconsistent surfaces: \(inconsistent)/\(facts.count)")
            for (s, readings) in inconsistentExamples {
                print("COV     ~ \(s) → \(readings.joined(separator: " / "))")
            }
            for (s, n, book, mecab) in relaxedGains.sorted(by: { $0.1 > $1.1 }).prefix(8) {
                print("COV     + \(s) ×\(n)  book \(book)  mecab \(mecab)")
            }
            for (k, v) in gateCounts.sorted(by: { $0.value > $1.value }) {
                print("COV     gate \(k) \(v)")
            }
            let byOccurrence = lexicon.rules
                .map { ($0.surface, $0.reading, occTotal[$0.surface] ?? 0) }
                .sorted { $0.2 > $1.2 }
            for (s, r, n) in byOccurrence.prefix(6) {
                print("COV     rule \(s) → \(r) ×\(n)")
            }
            for c in lexicon.rejected where (occTotal[c.surface] ?? 0) >= 5 {
                print("COV     LOST \(c.surface) → \(c.reading) ×\(occTotal[c.surface] ?? 0)  "
                      + "\(c.rejection.map(String.init(describing:)) ?? "-")")
            }
        }

        print("COV ══ END BOOKS")
        print("COV ══════════ TOTAL ══════════")
        print("COV surfaces \(totalSurfaces), occurrences \(totalOcc)")
        print("COV covered now     \(totalAdmittedOcc)\t"
              + "\(totalOcc == 0 ? 0 : 100 * totalAdmittedOcc / totalOcc)%")
        print("COV covered relaxed \(totalRelaxedOcc)\t"
              + "\(totalOcc == 0 ? 0 : 100 * totalRelaxedOcc / totalOcc)%")
        print("COV rejected free \(totalFree), rejected real loss \(totalRealLoss)")
        print("COV ── token-aligned basis (substring artefacts removed) ──")
        print("COV aligned occurrences \(totalAlignedOcc), book-vouched \(totalVouched)")
        print("COV aligned covered \(totalAdmittedAligned)\t"
              + "\(totalAlignedOcc == 0 ? 0 : 100 * totalAdmittedAligned / totalAlignedOcc)%")
        print("COV aligned rejected free \(totalFreeAligned), "
              + "aligned real loss \(totalRealLossAligned)")
        print("COV ── which gate causes the real loss ──")
        for (k, v) in lossTotals.sorted(by: { $0.value > $1.value }) {
            print("COV loss-by-gate \(k) \(v)")
        }
        print("COV mecab self-inconsistent \(totalInconsistent)/\(totalSurfaces)")
        for (k, v) in gateTotals.sorted(by: { $0.value > $1.value }) {
            print("COV gate \(k) \(v)")
        }
    }
}

extension RubyCoverageProbe {
    private func kanaRun(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy {
            $0.unicodeScalars.allSatisfy {
                (0x3041...0x3096).contains($0.value)
                    || (0x30A1...0x30FA).contains($0.value)
                    || $0.value == 0x30FC
            }
        }
    }

    func testSingleCharacterPromotionHeadroom() async throws {
        let tokenizer = try MeCabTokenizer()
        var totalMulti = 0, totalSingle = 0, totalExtendable = 0, totalStuck = 0
        var totalExtendableOcc = 0

        for book in StarterLibrary.books {
            guard let url = StarterLibrary.url(for: book) else { continue }
            let document = try await Importer.document(from: url)
            let wholeBook = document.chapters.map { Normalize.nfkc($0.text) }.joined(separator: "\u{1}")

            var multi = 0, single = 0, extendable = 0, stuck = 0
            var candidates: [String: (reading: String, sites: Int)] = [:]

            for chapter in document.chapters where !chapter.sourceReadings.isEmpty {
                let tokens = tokenizer.tokenize(chapter.text)
                let readings = SourceReadingOverlay.bookReadings(chapter.sourceReadings,
                                                                 tokens: tokens,
                                                                 text: chapter.text)
                for (i, token) in tokens.enumerated() {
                    guard let reading = readings[i] else { continue }
                    if token.surface.count > 1 { multi += 1; continue }
                    single += 1

                    let leftToken = i > 0 && kanaRun(tokens[i - 1].surface) ? tokens[i - 1].surface : ""
                    let rightToken = i + 1 < tokens.count && kanaRun(tokens[i + 1].surface)
                        ? tokens[i + 1].surface : ""

                    var surface = "", composedReading = ""
                    if !leftToken.isEmpty, leftToken.count <= 3 {
                        surface = leftToken + token.surface
                        composedReading = leftToken + reading
                    } else if !rightToken.isEmpty, rightToken.count <= 3 {
                        surface = token.surface + rightToken
                        composedReading = reading + rightToken
                    }

                    if surface.count > 1 {
                        extendable += 1
                        let existing = candidates[surface]?.sites ?? 0
                        candidates[surface] = (composedReading, existing + 1)
                    } else {
                        stuck += 1
                    }
                }
            }

            var occ = 0
            var top: [(String, String, Int, Int)] = []
            for (surface, v) in candidates {
                let n = wholeBook.ranges(of: surface).count
                occ += n
                top.append((surface, v.reading, n, v.sites))
            }

            totalMulti += multi; totalSingle += single
            totalExtendable += extendable; totalStuck += stuck
            totalExtendableOcc += occ

            print("PROMO ══ \(book.id)")
            print("PROMO   token candidates: multi-char \(multi), single-char \(single)")
            print("PROMO   single-char extendable \(extendable), stuck \(stuck)")
            print("PROMO   distinct new surfaces \(candidates.count), occurrences \(occ)")
            for (s, r, n, sites) in top.sorted(by: { $0.2 > $1.2 }).prefix(8) {
                let vouched = n == sites ? "all annotated" : "\(n - sites) unannotated"
                print("PROMO     + \(s) → \(r) ×\(n)  (\(vouched))")
            }
        }

        print("PROMO ══════════ TOTAL ══════════")
        print("PROMO multi-char token candidates \(totalMulti)")
        print("PROMO single-char token candidates \(totalSingle)")
        print("PROMO   extendable \(totalExtendable), stuck \(totalStuck)")
        print("PROMO   occurrences reachable \(totalExtendableOcc)")
    }
}

extension RubyCoverageProbe {
    static func sentence(around range: Range<Int>, in text: [Character]) -> String {
        let stops: Set<Character> = ["。", "！", "？", "!", "?", "\n", "」"]
        var lo = range.lowerBound
        while lo > 0, !stops.contains(text[lo - 1]), range.lowerBound - lo < 60 { lo -= 1 }
        var hi = range.upperBound
        while hi < text.count, !stops.contains(text[hi]), hi - range.upperBound < 60 { hi += 1 }
        if hi < text.count { hi += 1 }
        return String(text[lo..<hi]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testDescribedSiteCoverage() async throws {
        let tokenizer = try MeCabTokenizer()
        var tSites = 0, tCovered = 0, tFree = 0, tLoss = 0
        var lossGate: [String: Int] = [:]
        var lossExamples: [String: Int] = [:]
        var lossCases: [String: [String: Any]] = [:]

        for book in StarterLibrary.books {
            guard let url = StarterLibrary.url(for: book) else { continue }
            let document = try await Importer.document(from: url)

            var tokensByIndex: [Int: [Token]] = [:]
            for (i, chapter) in document.chapters.enumerated()
            where !chapter.sourceReadings.isEmpty {
                tokensByIndex[i] = tokenizer.tokenize(chapter.text)
            }
            let lexicon = PronunciationLexicon.build(chapters: document.chapters,
                                                     tokens: tokensByIndex)
            let ruleSurfaces = lexicon.rules.map(\.surface)
            var gateOf: [String: String] = [:]
            for c in lexicon.rejected {
                gateOf[c.surface] = String(describing: c.rejection ?? .singleCharacterBase)
            }

            var sites = 0, covered = 0, free = 0, loss = 0

            for (i, chapter) in document.chapters.enumerated()
            where !chapter.sourceReadings.isEmpty {
                let text = Array(Normalize.nfkc(chapter.text))
                let tokens = tokensByIndex[i] ?? []
                XCTAssertEqual(tokens.map(\.surface).joined(), String(text),
                               "\(book.id): token surfaces must reconstruct the chapter text, "
                                   + "or every offset below is drifting")
                let described = SourceReadingOverlay.bookReadings(chapter.sourceReadings,
                                                                  tokens: tokens,
                                                                  text: chapter.text)
                var isCovered = [Bool](repeating: false, count: text.count)
                for surface in ruleSurfaces {
                    let needle = Array(surface)
                    for at in occurrences(of: needle, in: text) {
                        for k in at..<(at + needle.count) { isCovered[k] = true }
                    }
                }

                var offset = 0
                for (t, token) in tokens.enumerated() {
                    let start = offset
                    offset += token.surface.count
                    guard let bookReading = described[t] else { continue }
                    sites += 1
                    let mecab = token.reading.map { folded($0) } ?? ""
                    if folded(bookReading) == mecab { free += 1; continue }
                    if (start..<offset).allSatisfy({ isCovered[$0] }) {
                        covered += 1
                    } else {
                        loss += 1
                        let why = token.surface.count == 1
                            ? "singleCharacterToken"
                            : (gateOf[token.surface] ?? "noCandidate")
                        lossGate[why, default: 0] += 1
                        let key = "\(token.surface)→\(bookReading)"
                        lossExamples[key, default: 0] += 1
                        if var existing = lossCases[key] {
                            existing["count"] = (existing["count"] as? Int ?? 0) + 1
                            lossCases[key] = existing
                        } else {
                            lossCases[key] = [
                                "book": book.id,
                                "surface": token.surface,
                                "bookReading": bookReading,
                                "mecabReading": token.reading ?? "",
                                "sentence": Self.sentence(around: start..<offset, in: text),
                                "cause": why,
                                "count": 1,
                            ]
                        }
                    }
                }
            }

            tSites += sites; tCovered += covered; tFree += free; tLoss += loss
            let pct = sites == 0 ? 0 : 100 * loss / sites
            let disagree = sites - free
            let share = disagree == 0 ? 0 : 100 * covered / disagree
            print("SITE \(book.id)\tdescribed \(sites)\tmecab-disagrees \(disagree)\t"
                  + "covered \(covered) (\(share)% of those)\tuncovered \(loss) (\(pct)%)")
        }

        print("SITE ══════════ TOTAL ══════════")
        print("SITE described sites \(tSites)")
        print("SITE   mecab DISAGREES at \(tSites - tFree) of them "
              + "— the only sites publisher ruby can improve")
        print("SITE   of those, rules cover \(tCovered) "
              + "(\(tSites - tFree == 0 ? 0 : 100 * tCovered / (tSites - tFree))%)")
        print("SITE   covered by a rule      \(tCovered)")
        print("SITE   free (mecab agrees)    \(tFree)")
        print("SITE   NOT DEMONSTRABLY COVERED \(tLoss)  "
              + "(\(tSites == 0 ? 0 : 100 * tLoss / tSites)%)")
        for (k, v) in lossGate.sorted(by: { $0.value > $1.value }) {
            print("SITE loss-by-cause \(k) \(v)")
        }
        for (k, v) in lossExamples.sorted(by: { $0.value > $1.value }).prefix(20) {
            print("SITE   worst \(k) ×\(v)")
        }
        let ordered = lossCases.values.sorted {
            ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0)
        }
        if let data = try? JSONSerialization.data(withJSONObject: ordered),
           let json = String(data: data, encoding: .utf8) {
            print("LOSSJSON \(json)")
        }
    }
}


extension RubyCoverageProbe {
    private struct Candidate {
        let surface: String
        let reading: String
        let occurrences: Int
        let vouchedEverywhere: Bool
    }

    private struct BookIndex {
        let texts: [[Character]]
        let tokens: [[Token]]
        let starts: [[Int]]
        let described: [[String?]]
    }

    private func index(_ document: Document, _ tokenizer: MeCabTokenizer) -> BookIndex {
        var texts: [[Character]] = [], toks: [[Token]] = []
        var starts: [[Int]] = [], described: [[String?]] = []
        for chapter in document.chapters {
            let t = tokenizer.tokenize(chapter.text)
            var s: [Int] = [], cursor = 0
            for x in t { s.append(cursor); cursor += x.surface.count }
            texts.append(Array(Normalize.nfkc(chapter.text)))
            toks.append(t)
            starts.append(s)
            described.append(chapter.sourceReadings.isEmpty
                ? [String?](repeating: nil, count: t.count)
                : SourceReadingOverlay.bookReadings(chapter.sourceReadings,
                                                    tokens: t, text: chapter.text))
        }
        return BookIndex(texts: texts, tokens: toks, starts: starts, described: described)
    }

    private func vouched(_ b: BookIndex, _ c: Int, _ lo: Int, _ hi: Int) -> (String, Bool)? {
        var out = "", annotated = false
        for t in lo...hi {
            if let book = b.described[c][t] { out += book; annotated = true }
            else if isKana(b.tokens[c][t].surface) { out += b.tokens[c][t].surface }
            else { return nil }
        }
        return (out, annotated)
    }

    private func window(_ b: BookIndex, _ c: Int, at offset: Int, length: Int) -> (Int, Int)? {
        guard let lo = b.starts[c].firstIndex(of: offset) else { return nil }
        var hi = lo, span = 0
        while hi < b.tokens[c].count {
            span += b.tokens[c][hi].surface.count
            if span == length { return (lo, hi) }
            if span > length { return nil }
            hi += 1
        }
        return nil
    }

    private func audit(_ b: BookIndex, surface: String, reading: String)
        -> (ok: Bool, occurrences: Int, allVouched: Bool) {
        let needle = Array(surface)
        var count = 0, allVouched = true
        for c in b.texts.indices {
            for at in occurrences(of: needle, in: b.texts[c]) {
                count += 1
                guard let (lo, hi) = window(b, c, at: at, length: needle.count),
                      let (there, annotated) = vouched(b, c, lo, hi) else {
                    return (false, count, false)
                }
                if annotated {
                    if folded(there) != folded(reading) { return (false, count, false) }
                } else {
                    allVouched = false
                }
            }
        }
        return (count > 0, count, allVouched)
    }

    func testContextualBaseHeadroom() async throws {
        let tokenizer = try MeCabTokenizer()
        var tLoss = 0, tStrict = 0, tRelaxed = 0, tNone = 0
        var strictExamples: [String] = [], relaxedExamples: [String] = []
        var overlaps: [String] = []
        var bases: [String: [String: Any]] = [:]

        for book in StarterLibrary.books {
            guard let url = StarterLibrary.url(for: book) else { continue }
            let document = try await Importer.document(from: url)
            let b = index(document, tokenizer)
            let lexicon = PronunciationLexicon.build(
                chapters: document.chapters,
                tokens: Dictionary(uniqueKeysWithValues: document.chapters.indices
                    .filter { !document.chapters[$0].sourceReadings.isEmpty }
                    .map { ($0, b.tokens[$0]) }))

            var loss = 0, strict = 0, relaxed = 0, none = 0
            var chosen: [String] = []

            for c in document.chapters.indices where !document.chapters[c].sourceReadings.isEmpty {
                var covered = [Bool](repeating: false, count: b.texts[c].count)
                for surface in lexicon.rules.map(\.surface) {
                    let needle = Array(surface)
                    for at in occurrences(of: needle, in: b.texts[c]) {
                        for k in at..<(at + needle.count) { covered[k] = true }
                    }
                }

                for (t, token) in b.tokens[c].enumerated() {
                    guard let bookReading = b.described[c][t], token.surface.count == 1 else { continue }
                    if folded(bookReading) == folded(token.reading ?? "") { continue }
                    let start = b.starts[c][t]
                    if (start..<(start + 1)).allSatisfy({ covered[$0] }) { continue }
                    loss += 1

                    var pool: [Candidate] = []
                    for lo in stride(from: t, through: max(0, t - 4), by: -1) {
                        for hi in t..<min(b.tokens[c].count, t + 5) {
                            guard hi >= t, lo <= t else { continue }
                            let surface = b.tokens[c][lo...hi].map(\.surface).joined()
                            guard surface.count > 1, surface.count <= 8,
                                  !surface.contains(where: { $0.isWhitespace || $0.isPunctuation }),
                                  let (reading, annotated) = vouched(b, c, lo, hi),
                                  annotated, isKana(reading), folded(reading) != folded(surface)
                            else { continue }
                            let a = audit(b, surface: surface, reading: reading)
                            guard a.ok else { continue }
                            pool.append(Candidate(surface: surface, reading: reading,
                                                  occurrences: a.occurrences,
                                                  vouchedEverywhere: a.allVouched))
                        }
                    }
                    let ranked = pool.sorted {
                        ($0.surface.count, $0.occurrences) < ($1.surface.count, $1.occurrences)
                    }
                    if let hit = ranked.first(where: \.vouchedEverywhere) {
                        strict += 1
                        chosen.append(hit.surface)
                        let key = "\(token.surface)→\(bookReading)"
                        if bases[key] == nil {
                            bases[key] = [
                                "book": book.id,
                                "surface": token.surface,
                                "bookReading": bookReading,
                                "base": hit.surface,
                                "baseReading": hit.reading,
                                "baseOccurrences": hit.occurrences,
                            ]
                        }
                        if strictExamples.count < 14 {
                            strictExamples.append("\(token.surface)→\(bookReading)"
                                + "\t⇒ \(hit.surface)→\(hit.reading) ×\(hit.occurrences)")
                        }
                    } else if let hit = ranked.first {
                        relaxed += 1
                        if relaxedExamples.count < 10 {
                            relaxedExamples.append("\(token.surface)→\(bookReading)"
                                + "\t⇒ \(hit.surface)→\(hit.reading) ×\(hit.occurrences) (не все заверены)")
                        }
                    } else {
                        none += 1
                    }
                }
            }

            let all = Set(chosen).union(lexicon.rules.map(\.surface))
            for a in all {
                for x in all where a != x && (a.contains(x) || x.contains(a)) {
                    let pair = [a, x].sorted().joined(separator: " ⊂ ")
                    if !overlaps.contains(pair) && overlaps.count < 12 { overlaps.append(pair) }
                }
            }

            tLoss += loss; tStrict += strict; tRelaxed += relaxed; tNone += none
            print("CTX \(book.id)\tlosses \(loss)\tstrict \(strict)\trelaxed \(relaxed)\tnone \(none)")
        }

        print("CTX ══════════ TOTAL ══════════")
        print("CTX single-character audible losses \(tLoss)")
        print("CTX   fully vouched contextual base   \(tStrict)")
        print("CTX   base exists, not all vouched    \(tRelaxed)")
        print("CTX   no candidate at all             \(tNone)")
        print("CTX ── fully vouched examples ──")
        for e in strictExamples { print("CTX   \(e)") }
        print("CTX ── would need the occurrence gate relaxed ──")
        for e in relaxedExamples { print("CTX   \(e)") }
        print("CTX ── overlapping rule pairs (precedence unknown at ElevenLabs) ──")
        for e in overlaps { print("CTX   \(e)") }
        if let data = try? JSONSerialization.data(withJSONObject: Array(bases.values)),
           let json = String(data: data, encoding: .utf8) {
            print("CTXJSON \(json)")
        }
    }
}
