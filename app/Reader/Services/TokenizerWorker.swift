import Foundation
import ReaderCore

actor TokenizerWorker {
    private var tokenizer: MeCabTokenizer?
    private var initAttempted = false

    func tokenize(_ text: String) -> [Token]? {
        if !initAttempted {
            initAttempted = true
            tokenizer = try? MeCabTokenizer()
        }
        return tokenizer?.tokenize(text)
    }
}
