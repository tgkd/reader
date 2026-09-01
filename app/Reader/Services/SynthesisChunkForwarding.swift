import Foundation
import ReaderCore

enum SynthesisChunkForwarding {
    typealias Sink = @Sendable (Data, Alignment) -> Void

    @TaskLocal static var sink: Sink?
}
