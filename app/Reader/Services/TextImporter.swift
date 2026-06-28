import Foundation
import ReaderCore

/// Imports a plain-text file as a single chapter. The encoding is sniffed
/// (UTF-8 → Shift-JIS → EUC-JP) by `JapaneseTextDecoder`; the chunker splits the
/// text for synthesis later, so the whole file is one chapter here.
struct TextImporter: DocumentImporter {
    let url: URL

    func chapters() throws -> [Chapter] {
        let data = try Data(contentsOf: url)
        guard let text = JapaneseTextDecoder.decode(data),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.unreadable
        }
        return [Chapter(title: nil, text: text)]
    }
}
