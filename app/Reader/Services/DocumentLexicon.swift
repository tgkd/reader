import Foundation
import ReaderCore

enum DocumentLexicon {
    struct ChapterTokens {
        let normalizedText: String
        let tokens: [Token]
    }

    struct Built {
        let lexicon: Lexicon
        let rawTokensByChapterID: [Chapter.ID: ChapterTokens]
    }

    static func build(for document: Document, using worker: TokenizerWorker,
                      seeded: [Chapter.ID: ChapterTokens] = [:]) async -> Built {
        await build(for: document, seeded: seeded,
                    readings: { await worker.readings(of: $0) },
                    tokenize: { await worker.tokenize($0) })
    }

    static func build(for document: Document,
                      seeded: [Chapter.ID: ChapterTokens] = [:],
                      readings corroborations: ([String]) async -> [String: String],
                      tokenize: (String) async -> [Token]?) async -> Built {
        let repaired = Set(document.chapters
            .filter(\.isFlattenedSource)
            .flatMap(\.sourceReadings)
            .filter(\.wasRepaired)
            .map { Normalize.nfkc($0.surface) })

        let corroborated = repaired.isEmpty
            ? [:]
            : await corroborations(Array(repaired))

        // Ruby is finer than the segmentation: a reading printed over 響 says nothing until it is
        // read against the token 響け. Every chapter carrying ruby is tokenized, not just the one
        // being read — the occurrence gates judge a surface over the whole book, so a rule that
        // depended on which chapters happened to be tokenized would depend on reading order.
        var tokens: [Int: [Token]] = [:]
        var retained: [Chapter.ID: ChapterTokens] = [:]
        for (i, chapter) in document.chapters.enumerated() where !chapter.sourceReadings.isEmpty {
            let normalized = Normalize.nfkc(chapter.text)
            if let seed = seeded[chapter.id], seed.normalizedText == normalized {
                tokens[i] = seed.tokens
                retained[chapter.id] = seed
                continue
            }
            if let chapterTokens = await tokenize(chapter.text) {
                tokens[i] = chapterTokens
                retained[chapter.id] = ChapterTokens(normalizedText: normalized,
                                                     tokens: chapterTokens)
            }
        }

        return Built(
            lexicon: PronunciationLexicon.build(chapters: document.chapters,
                                                tokens: tokens) { corroborated[$0] },
            rawTokensByChapterID: retained)
    }
}
