import AVFoundation
import Foundation

final class ChapterAudioSource: NSObject, AVAssetResourceLoaderDelegate {
    private static let scheme = "yomi-chapter"

    private let lock = NSLock()
    private var data = Data()
    private var isComplete = false
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var estimatedLength: Int

    let url: URL

    var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return data.count
    }

    init(expectedBytes: Int) {
        self.estimatedLength = max(expectedBytes, 1)
        self.url = URL(string: "\(Self.scheme)://chapter.mp3")!
        super.init()
    }

    func makeAsset(queue: DispatchQueue) -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > estimatedLength { estimatedLength = data.count }
        let ready = drainLocked()
        lock.unlock()
        ready.forEach { $0() }
    }

    func finish() {
        lock.lock()
        isComplete = true
        estimatedLength = data.count
        let ready = drainLocked()
        lock.unlock()
        ready.forEach { $0() }
    }

    func abort() {
        lock.lock()
        let stranded = pending
        pending.removeAll()
        lock.unlock()
        stranded.forEach { $0.finishLoading(with: URLError(.cancelled)) }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource
                        loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        lock.lock()
        fill(loadingRequest)
        let satisfied = respondLocked(to: loadingRequest)
        if !satisfied { pending.append(loadingRequest) }
        lock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        pending.removeAll { $0 === loadingRequest }
        lock.unlock()
    }

    private func fill(_ request: AVAssetResourceLoadingRequest) {
        request.contentInformationRequest?.contentType = AVFileType.mp3.rawValue
        request.contentInformationRequest?.contentLength = Int64(estimatedLength)
        request.contentInformationRequest?.isByteRangeAccessSupported = true
    }

    /// How far a read at `offset` can be answered.
    ///
    /// Pulled out of the delegate callback so it can be tested: `AVAssetResourceLoadingRequest`
    /// cannot be constructed outside AVFoundation, and end-of-resource — the one case that has
    /// been wrong twice — was therefore the one case with no coverage.
    enum Read: Equatable {
        /// Hand over `count` bytes; `thenFinish` closes the request rather than leaving it queued.
        case send(count: Int, thenFinish: Bool)
        /// Nothing to send and nothing more coming: complete the request so the reader sees EOF.
        case finish
        /// Beyond what has arrived, but the resource is still growing. Queue it.
        case wait
    }

    static func read(offset: Int, requestedOffset: Int, requestedLength: Int,
                     available: Int, isComplete: Bool) -> Read {
        // Past the end of a sealed resource. The advertised length is a guess made before a single
        // byte existed and it runs long, so AVFoundation reads ahead into a tail that never
        // existed. Completing with no bytes is how the loader contract reports end-of-resource;
        // dropping the request silently, as this did, leaves the player waiting for it forever.
        guard offset <= available else { return isComplete ? .finish : .wait }
        let wanted = requestedLength - (offset - requestedOffset)
        let count = max(0, min(wanted, available - offset))
        return .send(count: count, thenFinish: count >= wanted || isComplete)
    }

    private func respondLocked(to request: AVAssetResourceLoadingRequest) -> Bool {
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let offset = Int(dataRequest.currentOffset)
        switch Self.read(offset: offset,
                         requestedOffset: Int(dataRequest.requestedOffset),
                         requestedLength: dataRequest.requestedLength,
                         available: data.count,
                         isComplete: isComplete) {
        case .wait:
            return false
        case .finish:
            // Never finishLoading(with:) — an error arrives as failedToPlayToEndTime, which costs
            // the listener the cached chapter they paid for.
            request.finishLoading()
            return true
        case .send(let count, let thenFinish):
            if count > 0 {
                dataRequest.respond(with: data.subdata(in: offset..<(offset + count)))
            }
            if thenFinish { request.finishLoading() }
            return thenFinish
        }
    }

    private func drainLocked() -> [() -> Void] {
        var completions: [() -> Void] = []
        pending.removeAll { request in
            let done = respondLocked(to: request)
            if done { completions.append { _ = request } }
            return done
        }
        return completions
    }
}
