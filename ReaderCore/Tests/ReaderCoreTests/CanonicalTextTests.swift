import XCTest
@testable import ReaderCore

final class CanonicalTextTests: XCTestCase {
    private let voicedHalfwidth = "ﾊﾞｽに乗った。"

    func testNormalizingTwiceIsNotTheSameBytesAsNormalizingOnce() {
        let once = Normalize.nfkc(voicedHalfwidth)
        let twice = Normalize.nfkc(once)
        XCTAssertEqual(once, twice, "equal as Strings — canonical equivalence")
        XCTAssertNotEqual(Array(once.utf8), Array(twice.utf8),
                          "but not as bytes: this is why the text may be normalized exactly once")
    }

    func testARequestNormalizesItsTextExactlyOnce() {
        let request = SynthesisRequest(text: voicedHalfwidth, voice: .shizuka)
        XCTAssertEqual(Array(request.text.value.utf8),
                       Array(Normalize.nfkc(voicedHalfwidth).utf8))
    }

    func testAlreadyCanonicalTextIsCarriedThroughUnchanged() {
        let once = Normalize.nfkc(voicedHalfwidth)
        XCTAssertEqual(Array(CanonicalText(alreadyCanonical: once).value.utf8),
                       Array(once.utf8))
    }

    func testARequestBuiltFromRawTextKeepsTheRawStringKey() {
        XCTAssertEqual(SynthesisRequest(text: voicedHalfwidth, voice: .shizuka).cacheKey,
                       ContentKey(text: voicedHalfwidth, voice: Voice.shizuka.id))
        XCTAssertEqual(SynthesisRequest(text: voicedHalfwidth, voice: .shizuka).legacyCacheKeys,
                       LegacyAudioCache.modelIDs.map {
                           ContentKey(text: voicedHalfwidth, voice: Voice.shizuka.id,
                                      legacyModel: $0)
                       })
    }

    func testASegmentKeyedAsCanonicalIsNotTheDoubleNormalizedOne() {
        let segment = Normalize.nfkc(voicedHalfwidth)
        XCTAssertNotEqual(
            SynthesisRequest(canonical: CanonicalText(alreadyCanonical: segment),
                             voice: .shizuka).cacheKey,
            SynthesisRequest(text: segment, voice: .shizuka).cacheKey,
            "feeding an already-canonical segment back through the raw initializer normalizes twice")
    }

    func testSplittingCanonicalTextIsLosslessAtTheByteLevel() {
        let whole = SynthesisRequest(text: voicedHalfwidth + "ﾊﾟﾝを買った。", voice: .shizuka)
        let segments = Chunker.split(whole.text.value, maxChars: 8)
        XCTAssertGreaterThan(segments.count, 1, "text must split into multiple segments")
        XCTAssertEqual(Array(segments.joined().utf8), Array(whole.text.value.utf8),
                       "the split must stay lossless as bytes, not just as Strings")
    }
}
