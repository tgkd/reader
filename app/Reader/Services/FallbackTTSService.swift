import Foundation
import ReaderCore

/// Tries `primary`, and on any failure tries `fallback` (whose error propagates
/// if it too fails). Used in DEBUG to wire the captured fixtures first (instant,
/// offline) with the Worker behind them — so the simulator stays usable while
/// the Worker is the production path. Release builds use the Worker alone.
final class FallbackTTSService: TTSService {
    private let primary: TTSService
    private let fallback: TTSService

    init(primary: TTSService, fallback: TTSService) {
        self.primary = primary
        self.fallback = fallback
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        do { return try await primary.synthesize(request) }
        catch { return try await fallback.synthesize(request) }
    }
}
