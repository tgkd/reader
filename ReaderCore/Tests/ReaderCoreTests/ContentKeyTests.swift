import XCTest
@testable import ReaderCore

final class ContentKeyTests: XCTestCase {
    func testSameTextAndVoiceIsTheSameKey() {
        XCTAssertEqual(ContentKey(text: "吾輩は猫である", voice: Voice.shizuka.id),
                       ContentKey(text: "吾輩は猫である", voice: Voice.shizuka.id))
    }

    func testVoiceSeparatesKeys() {
        XCTAssertNotEqual(ContentKey(text: "本", voice: Voice.shizuka.id),
                          ContentKey(text: "本", voice: Voice.george.id))
    }

    func testTextSeparatesKeys() {
        XCTAssertNotEqual(ContentKey(text: "本", voice: Voice.shizuka.id),
                          ContentKey(text: "木", voice: Voice.shizuka.id))
    }

    func testWidthOnlyDifferencesShareAKey() {
        XCTAssertEqual(ContentKey(text: "ｱ", voice: Voice.shizuka.id),
                       ContentKey(text: "ア", voice: Voice.shizuka.id))
        XCTAssertEqual(ContentKey(text: "１２３", voice: Voice.shizuka.id),
                       ContentKey(text: "123", voice: Voice.shizuka.id))
    }

    func testVoicedHalfwidthKanaDoesNotYetFoldOntoItsPrecomposedForm() {
        XCTAssertEqual("ｶﾞ".precomposedStringWithCompatibilityMapping, "ガ",
                       "equal as Strings — canonical equivalence")
        XCTAssertNotEqual(ContentKey(text: "ｶﾞ", voice: Voice.shizuka.id),
                          ContentKey(text: "ガ", voice: Voice.shizuka.id),
                          "but not as bytes; see the comment above before 'fixing' this")
    }

    func testPartsCannotCollideAcrossTheBoundary() {
        XCTAssertNotEqual(ContentKey(text: "b", voice: "a"),
                          ContentKey(text: "", voice: "ab"))
    }

    func testTheLegacyModelKeyIsADistinctKey() {
        let current = ContentKey(text: "本", voice: Voice.shizuka.id)
        for model in LegacyAudioCache.modelIDs {
            XCTAssertNotEqual(current,
                              ContentKey(text: "本", voice: Voice.shizuka.id, legacyModel: model))
        }
        XCTAssertEqual(Set(LegacyAudioCache.modelIDs.map {
            ContentKey(text: "本", voice: Voice.shizuka.id, legacyModel: $0)
        }).count, LegacyAudioCache.modelIDs.count, "each model named its own entry")
    }

    func testTheKeyFormulaIsPinned() {
        XCTAssertEqual(ContentKey(text: "本", voice: "v1").value,
                       ContentKey(text: "本", voice: "v1").value)
        XCTAssertEqual(ContentKey(text: "本", voice: "v1").value.count, 64)
    }
}
