import Foundation
import ReaderCore

/// Serializes all MeCab access off the main actor. Two things must never run on
/// the UI thread: the one-time ~50 MB IPADic load (first tokenize of a session)
/// and per-chapter tokenization — both stalled the Library→Reader transition
/// when the tokenizer lived on the main actor. MeCab itself is not thread-safe,
/// so the actor is also the serialization point: every tokenize in the app goes
/// through here, preserving the one-MeCab-pass discipline.
actor TokenizerWorker {
    private var tokenizer: MeCabTokenizer?
    private var initAttempted = false

    /// Tokenize `text`, lazily creating the tokenizer on first use. Returns nil
    /// only if MeCab/IPADic failed to initialize (the "text engine unavailable"
    /// surface state) — a failed init is remembered, not retried per call.
    func tokenize(_ text: String) -> [Token]? {
        if !initAttempted {
            initAttempted = true
            tokenizer = try? MeCabTokenizer()
        }
        return tokenizer?.tokenize(text)
    }
}
