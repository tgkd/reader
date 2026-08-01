import AVFoundation
import Foundation

/// Feeds `AVPlayer` an MP3 that may still be arriving.
///
/// `AVAudioPlayer(data:)` needs the whole file up front, which is why narration
/// used to be inaudible until synthesis finished — ~200 s for a chapter, even
/// though ElevenLabs starts emitting audio at ~1.7 s. `AVPlayer` will play a
/// growing asset, but only through a custom URL scheme it cannot fetch itself,
/// so this serves the bytes via `AVAssetResourceLoaderDelegate`.
///
/// Cached chapters use the same path: append everything, `finish()`, play. One
/// code path rather than a streaming player and a file player with two sets of
/// completion and interruption behaviour to keep in sync.
///
/// Thread-safety: `AVAssetResourceLoader` calls in on its own queue while the
/// synthesis stream appends from another, so all state is behind one lock.
final class ChapterAudioSource: NSObject, AVAssetResourceLoaderDelegate {
    /// Only the scheme matters — it must be one `AVURLAsset` won't try to load
    /// itself, which is what routes every request through this delegate.
    private static let scheme = "yomi-chapter"

    private let lock = NSLock()
    private var data = Data()
    private var isComplete = false
    /// Requests parked because the bytes they want haven't arrived yet.
    private var pending: [AVAssetResourceLoadingRequest] = []
    /// Total byte count, known exactly once complete and estimated before that.
    /// `AVPlayer` needs SOME length to start, and a length it later overruns is
    /// better than one it stops short at.
    private var estimatedLength: Int

    let url: URL

    /// Bytes appended so far — the audio that genuinely exists to play. The
    /// alignment stream runs AHEAD of the audio it describes (measured 1.4–3.1 s on
    /// `eleven_v3`: whole chunks arrive carrying audio and no alignment, and vice
    /// versa), so the reader cannot use the alignment frontier to decide how much
    /// narration it holds.
    var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return data.count
    }

    /// `expectedBytes` should over-estimate: `AVPlayer` treats the advertised
    /// length as the end of the asset, so guessing short truncates playback,
    /// while guessing long is corrected by `finish()` before it is reached.
    init(expectedBytes: Int) {
        self.estimatedLength = max(expectedBytes, 1)
        self.url = URL(string: "\(Self.scheme)://chapter.mp3")!
        super.init()
    }

    /// An asset wired to this source. Kept here so the delegate queue and the
    /// asset are created together and can't be mismatched.
    func makeAsset(queue: DispatchQueue) -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    // MARK: - Feeding

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > estimatedLength { estimatedLength = data.count }
        let ready = drainLocked()
        lock.unlock()
        ready.forEach { $0() }
    }

    /// No more audio is coming: the advertised length becomes exact, and any
    /// request still waiting for bytes past the end is answered rather than left
    /// hanging — an unanswered request stalls `AVPlayer` silently.
    func finish() {
        lock.lock()
        isComplete = true
        estimatedLength = data.count
        let ready = drainLocked()
        lock.unlock()
        ready.forEach { $0() }
    }

    /// Synthesis failed or was cancelled — fail the parked requests so `AVPlayer`
    /// reports an error instead of waiting forever.
    func abort() {
        lock.lock()
        let stranded = pending
        pending.removeAll()
        lock.unlock()
        stranded.forEach { $0.finishLoading(with: URLError(.cancelled)) }
    }

    // MARK: - AVAssetResourceLoaderDelegate

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

    // MARK: - Internals

    /// Advertise what this is. Byte-range access must be supported or `AVPlayer`
    /// refuses to start until the whole asset is present — the exact behaviour
    /// being avoided here.
    private func fill(_ request: AVAssetResourceLoadingRequest) {
        request.contentInformationRequest?.contentType = AVFileType.mp3.rawValue
        request.contentInformationRequest?.contentLength = Int64(estimatedLength)
        request.contentInformationRequest?.isByteRangeAccessSupported = true
    }

    /// Answer as much of the request as the buffer currently allows. Returns
    /// whether the request is finished and can be dropped.
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
        // Done when the request is satisfied, or when nothing more is coming and
        // the buffer is exhausted (a short final read rather than a stall).
        if count >= wanted || isComplete {
            request.finishLoading()
            return true
        }
        return false
    }

    /// Returns closures to run OUTSIDE the lock: `finishLoading` can re-enter the
    /// delegate, and re-entering while holding the lock deadlocks playback.
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
