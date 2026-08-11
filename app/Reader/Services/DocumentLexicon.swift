import Foundation
import ReaderCore

enum DocumentLexicon {
    static func build(for document: Document, using worker: TokenizerWorker) async -> Lexicon {
        let repaired = Set(document.chapters
            .filter(\.isFlattenedSource)
            .flatMap(\.sourceReadings)
            .filter(\.wasRepaired)
            .map { Normalize.nfkc($0.surface) })

        let corroborations = repaired.isEmpty
            ? [:]
            : await worker.readings(of: Array(repaired))

        // Ruby is finer than the segmentation: a reading printed over 響 says nothing until it is
        // read against the token 響け. Every chapter carrying ruby is tokenized, not just the one
        // being read — the occurrence gates judge a surface over the whole book, so a rule that
        // depended on which chapters happened to be tokenized would depend on reading order.
        var tokens: [Int: [Token]] = [:]
        for (i, chapter) in document.chapters.enumerated() where !chapter.sourceReadings.isEmpty {
            if let chapterTokens = await worker.tokenize(chapter.text) { tokens[i] = chapterTokens }
        }

        return PronunciationLexicon.build(chapters: document.chapters,
                                          tokens: tokens) { corroborations[$0] }
    }
}
