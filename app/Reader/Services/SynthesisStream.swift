import Foundation
import ReaderCore

final class SynthesisStream: @unchecked Sendable {
    typealias Sink = (Data, Alignment) -> Void

    private let lock = NSLock()
    private var sinks: [String: Sink] = [:]

    func subscribe(_ key: ContentKey, _ sink: @escaping Sink) {
        lock.lock(); sinks[key.value] = sink; lock.unlock()
    }

    func unsubscribe(_ key: ContentKey) {
        lock.lock(); sinks[key.value] = nil; lock.unlock()
    }

    func publish(_ key: ContentKey, audio: Data, alignment: Alignment) {
        lock.lock()
        let sink = sinks[key.value]
        lock.unlock()
        guard let sink else { return }
        DispatchQueue.main.async { sink(audio, alignment) }
    }
}
