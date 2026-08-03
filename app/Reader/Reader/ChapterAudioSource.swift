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

    func finish(reconcilingWith complete: Data) {
        lock.lock()
        if complete.count > data.count {
            data.append(complete.subdata(in: data.count..<complete.count))
        }
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

    private func respondLocked(to request: AVAssetResourceLoadingRequest) -> Bool {
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let offset = Int(dataRequest.currentOffset)
        guard offset <= data.count else { return isComplete }

        let wanted = dataRequest.requestedLength - (offset - Int(dataRequest.requestedOffset))
        let available = data.count - offset
        let count = min(wanted, available)
        if count > 0 {
            dataRequest.respond(with: data.subdata(in: offset..<(offset + count)))
        }
        if count >= wanted || isComplete {
            request.finishLoading()
            return true
        }
        return false
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
