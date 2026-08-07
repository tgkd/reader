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

        return PronunciationLexicon.build(chapters: document.chapters) { corroborations[$0] }
    }
}
