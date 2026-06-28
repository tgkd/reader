import Foundation
import ReaderCore

/// Sample shelf for base UI. The three fixture-backed documents actually play
/// offline (their chapter text matches a captured fixture exactly); the literary
/// titles without a fixture render the reader's "not yet generated" state — the
/// real cache-miss that Phase 6's Worker fills. Texts are the genuine openings
/// so the list reads true.
enum SeedLibrary {
    static let documents: [Document] = [
        doc("00000000-0000-0000-0000-0000000000a1",
            "吾輩は猫である", "夏目漱石", 0.42,
            "吾輩は猫である。名前はまだ無い。どこで生まれたか頓と見当がつかぬ。"),

        doc("00000000-0000-0000-0000-0000000000a2",
            "こころ", "夏目漱石", 0.0,
            "私はその人を常に先生と呼んでいた。"),

        doc("00000000-0000-0000-0000-0000000000a3",
            "銀河鉄道の夜", "宮沢賢治", 0.88,
            "ジョバンニは、まっ赤になってうなずきました。"),

        doc("00000000-0000-0000-0000-0000000000a4",
            "走れメロス", "太宰治", 1.0,
            "メロスは激怒した。"),

        doc("00000000-0000-0000-0000-0000000000b1",
            "数字と日付の練習", "サンプル", 0.0,
            "今日は2026年6月27日、東京の気温は25度でした。"),

        doc("00000000-0000-0000-0000-0000000000b2",
            "会話文の練習", "サンプル", 0.6,
            "「行こう」と彼は言った。「もう時間がない。」"),
    ]

    private static func doc(_ id: String, _ title: String, _ author: String,
                            _ fraction: Double, _ text: String) -> Document {
        Document(
            id: UUID(uuidString: id)!,
            title: title,
            author: author,
            chapters: [Chapter(text: text)],
            progress: ReadingProgress(fraction: fraction)
        )
    }
}
