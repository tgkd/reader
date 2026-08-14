import Foundation
import CMeCab
import IPADic

public enum MeCabTokenizerError: Error {
    case engineUnavailable(String)
}

public final class MeCabTokenizer: JapaneseTokenizer {
    private let model: OpaquePointer
    private let tagger: OpaquePointer
    private let readingIndex: Int
    private let lemmaIndex: Int

    public init() throws {
        let dictionary = IPADic()
        let path = dictionary.url.path

        var argv = ["mecab", "-d", path].map { strdup($0) }
        defer { argv.forEach { free($0) } }

        guard let model = argv.withUnsafeMutableBufferPointer({
            mecab_model_new(Int32($0.count), $0.baseAddress)
        }) else {
            throw MeCabTokenizerError.engineUnavailable(
                "mecab_model_new failed for \(path): \(Self.lastError())")
        }
        guard let tagger = mecab_model_new_tagger(model) else {
            mecab_model_destroy(model)
            throw MeCabTokenizerError.engineUnavailable(
                "mecab_model_new_tagger failed: \(Self.lastError())")
        }

        self.model = model
        self.tagger = tagger
        self.readingIndex = dictionary.readingIndex
        self.lemmaIndex = dictionary.dictionaryFormIndex
    }

    deinit {
        mecab_destroy(tagger)
        mecab_model_destroy(model)
    }

    public func tokenize(_ text: String) -> [Token] {
        let normalized = Normalize.nfkc(text)
        guard !normalized.isEmpty else { return [] }

        let bytes = Array(normalized.utf8)
        let clusters = ClusterProjection(normalized: normalized, byteCount: bytes.count)

        var tokens: [Token] = []
        tokens.reserveCapacity(bytes.count / 4)
        var cursor = 0

        if let lattice = mecab_model_new_lattice(model) {
            defer { mecab_lattice_destroy(lattice) }
            clusters.parseText.withCString { sentence in
                mecab_lattice_set_sentence2(lattice, sentence, clusters.parseByteCount)
                guard mecab_parse_lattice(tagger, lattice) != 0,
                      let base = mecab_lattice_get_sentence(lattice) else { return }

                var node = mecab_lattice_get_bos_node(lattice)
                while let n = node {
                    defer { node = n.pointee.next }
                    guard let surface = n.pointee.surface, n.pointee.length > 0 else { continue }

                    let parsedLo = UnsafeRawPointer(surface) - UnsafeRawPointer(base)
                    let parsedHi = parsedLo + Int(n.pointee.length)
                    guard parsedLo >= 0, parsedHi <= clusters.parseByteCount else { continue }

                    let lo = clusters.project(parsedLo)
                    let hi = clusters.project(parsedHi)
                    let end = clusters.snapForward(hi)
                    guard end > cursor else {
                        Self.dropReadingOfLast(&tokens)
                        continue
                    }
                    let start = max(cursor, clusters.snapBackward(lo))
                    if start > cursor {
                        tokens.append(Token(surface: Self.slice(bytes, cursor, start),
                                            reading: nil, dictionaryForm: nil))
                    }

                    let widened = start != lo || end != hi
                    let text = Self.slice(bytes, start, end)
                    let reading = Self.field(n.pointee.feature, at: readingIndex) ?? text
                    let lemma = Self.field(n.pointee.feature, at: lemmaIndex) ?? text
                    tokens.append(Token(surface: text,
                                        reading: widened ? nil : Self.usableReading(reading),
                                        dictionaryForm: Self.usableLemma(lemma)))
                    cursor = end
                }
            }
        }

        if cursor < bytes.count {
            tokens.append(Token(surface: Self.slice(bytes, cursor, bytes.count),
                                reading: nil, dictionaryForm: nil))
        }
        return tokens
    }

    private static func dropReadingOfLast(_ tokens: inout [Token]) {
        guard let last = tokens.last, last.reading != nil else { return }
        tokens[tokens.count - 1] = Token(surface: last.surface, reading: nil,
                                         dictionaryForm: last.dictionaryForm)
    }

    private static func lastError() -> String {
        guard let message = mecab_strerror(nil) else { return "unknown error" }
        return String(cString: message)
    }

    private static func slice(_ bytes: [UInt8], _ lo: Int, _ hi: Int) -> String {
        String(decoding: bytes[lo..<hi], as: UTF8.self)
    }

    static func field(_ feature: UnsafePointer<CChar>?, at index: Int) -> String? {
        guard var p = feature else { return nil }
        var seen = 0
        while seen < index {
            guard p.pointee != 0 else { return nil }
            if p.pointee == 44 { seen += 1 }
            p += 1
        }
        var q = p
        while q.pointee != 0 && q.pointee != 44 { q += 1 }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: q - p), as: UTF8.self)
    }

    static func usableLemma(_ raw: String) -> String? {
        (raw.isEmpty || raw == "*") ? nil : raw
    }

    static func usableReading(_ raw: String) -> String? {
        guard !raw.isEmpty, raw != "*",
              !raw.unicodeScalars.contains(where: Furigana.isIdeograph) else { return nil }
        return hiragana(raw)
    }

    static func hiragana(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if (0x30A1...0x30F6).contains(scalar.value), let h = Unicode.Scalar(scalar.value - 0x60) {
                out.append(h)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
