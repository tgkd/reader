import Foundation

public protocol JapaneseTokenizer {
    func tokenize(_ text: String) -> [Token]
}
