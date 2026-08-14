import XCTest
import CMeCab
import IPADic
@testable import ReaderCore

final class CMeCabSmokeTests: XCTestCase {
    func testVendoredEngineVersion() {
        XCTAssertEqual(String(cString: mecab_version()), "0.996",
                       "the vendored engine changed; re-check Sources/CMeCab against upstream")
    }

    func testTaggerOpensTheBundledDictionaryAndSegments() throws {
        var argv = ["mecab", "-d", IPADic().url.path].map { strdup($0) }
        defer { argv.forEach { free($0) } }

        let model = argv.withUnsafeMutableBufferPointer {
            mecab_model_new(Int32($0.count), $0.baseAddress)
        }
        let m = try XCTUnwrap(model, "mecab_model_new failed for \(IPADic().url.path)")
        defer { mecab_model_destroy(m) }

        let tagger = try XCTUnwrap(mecab_model_new_tagger(m))
        defer { mecab_destroy(tagger) }
        let lattice = try XCTUnwrap(mecab_model_new_lattice(m))
        defer { mecab_lattice_destroy(lattice) }

        let sentence = Normalize.nfkc("私は本を読みます")
        let utf8 = Array(sentence.utf8)
        var surfaces: [String] = []

        sentence.withCString { s in
            mecab_lattice_set_sentence(lattice, s)
            guard mecab_parse_lattice(tagger, lattice) != 0,
                  let base = mecab_lattice_get_sentence(lattice) else { return }
            var node = mecab_lattice_get_bos_node(lattice)
            while let n = node {
                defer { node = n.pointee.next }
                guard let sp = n.pointee.surface, n.pointee.length > 0 else { continue }
                let lo = UnsafeRawPointer(sp) - UnsafeRawPointer(base)
                let hi = lo + Int(n.pointee.length)
                surfaces.append(String(decoding: utf8[lo..<hi], as: UTF8.self))
            }
        }

        XCTAssertEqual(surfaces, ["私", "は", "本", "を", "読み", "ます"],
                       "byte offsets from node.surface must slice the sentence exactly")
    }
}
