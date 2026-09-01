import Foundation
import MediaPlayer
import UIKit

@MainActor
final class NowPlayingController {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onNextChapter: (() -> Void)?
    var onPreviousChapter: (() -> Void)?
    var onPlaybackRate: ((Double) -> Void)?
    var supportedPlaybackRates: [Double] = []

    private var tokens: [(MPRemoteCommand, Any)] = []

    private static let artwork: MPMediaItemArtwork? = {
        guard let icon = UIImage(named: "NowPlayingArtwork") else { return nil }
        return MPMediaItemArtwork(boundsSize: icon.size) { size in
            UIGraphicsImageRenderer(size: size).image { _ in
                icon.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }()

    func activate() {
        guard tokens.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        add(center.playCommand) { $0.onPlay?() }
        add(center.pauseCommand) { $0.onPause?() }
        add(center.togglePlayPauseCommand) { $0.onTogglePlayPause?() }
        add(center.nextTrackCommand) { $0.onNextChapter?() }
        add(center.previousTrackCommand) { $0.onPreviousChapter?() }
        let seekToken = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.onSeek?(t) }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        tokens.append((center.changePlaybackPositionCommand, seekToken))

        let rates = supportedPlaybackRates
        guard !rates.isEmpty else { return }
        center.changePlaybackRateCommand.supportedPlaybackRates = rates.map { NSNumber(value: $0) }
        let rateToken = center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = Double(e.playbackRate)
            guard rates.contains(rate) else { return .commandFailed }
            Task { @MainActor in self?.onPlaybackRate?(rate) }
            return .success
        }
        center.changePlaybackRateCommand.isEnabled = true
        tokens.append((center.changePlaybackRateCommand, rateToken))
    }

    func deactivate() {
        for (command, token) in tokens { command.removeTarget(token) }
        tokens.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func setMetadata(bookTitle: String, chapterTitle: String,
                     chapterIndex: Int, chapterCount: Int, duration: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = chapterTitle
        info[MPMediaItemPropertyArtist] = bookTitle
        info[MPMediaItemPropertyAlbumTrackNumber] = chapterIndex + 1
        info[MPMediaItemPropertyAlbumTrackCount] = chapterCount
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPMediaItemPropertyArtwork] = Self.artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func setPlayback(elapsed: Double, rate: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func setChapterBounds(hasPrevious: Bool, hasNext: Bool) {
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = hasPrevious
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = hasNext
    }

    private func add(_ command: MPRemoteCommand,
                     handler: @escaping @MainActor (NowPlayingController) -> Void) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                handler(self)
            }
            return .success
        }
        tokens.append((command, token))
    }
}
