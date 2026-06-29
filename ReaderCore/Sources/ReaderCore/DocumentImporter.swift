import Foundation

/// Turns a source file (EPUB / PDF / .txt) into ordered plain-text chapters the
/// reader pipeline consumes (normalize → tokenize → TTS → cache). Only the
/// protocol is defined now; the format implementations are Phase 7. Two
/// invariants are recorded here so they aren't lost before then:
///
///   • EPUB reading order ALWAYS comes from the `<spine>`, never the
///     `<manifest>` (the manifest is an unordered id→href map).
///   • `.txt` Japanese files are commonly Shift-JIS / Windows-31J (CP932) or
///     UTF-8 (occasionally EUC-JP). Sniff UTF-8 → `.shiftJIS` → `.japaneseEUC`
///     and reject a decode that produced replacement characters (mojibake).
///
/// NFKC normalization is NOT applied here — it happens once downstream, at the
/// tokenize/TTS boundary, so every ingestion path shares the same normalization.
public protocol DocumentImporter {
    func chapters() async throws -> [Chapter]
}
