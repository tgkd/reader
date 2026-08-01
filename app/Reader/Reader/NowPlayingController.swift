import Foundation
import MediaPlayer
import UIKit

/// Publishes playback to the system Now Playing surface (lock screen / Control
/// Center) and routes remote commands back into the reader. Owned by
/// `ReaderModel`; its lifecycle mirrors the audio session exactly — activated on
/// first real playback, deactivated with `stop()` and natural finish, so leaving
/// the reader also clears the lock-screen widget.
///
/// Next/previous track map to chapter skips. A skip to a chapter without local
/// audio ends the session rather than synthesizing: speech generation is a paid,
/// explicit in-app Play action and must never be triggered from the lock screen.
@MainActor
final class NowPlayingController {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onNextChapter: (() -> Void)?
    var onPreviousChapter: (() -> Void)?

    /// Registered command targets, removed on deactivate.
    private var tokens: [(MPRemoteCommand, Any)] = []

    /// Books have no cover art, so the app icon stands in as the artwork slot's
    /// image. Built from a dedicated 512 pt asset rather than the bundle's
    /// `AppIcon60x60@2x.png` (120 px), which is soft in the expanded player.
    /// Made once — the handler redraws per requested size, and the system asks
    /// for several as the widget expands.
    private static let artwork: MPMediaItemArtwork? = {
        guard let icon = UIImage(named: "NowPlayingArtwork") else { return nil }
        return MPMediaItemArtwork(boundsSize: icon.size) { size in
            UIGraphicsImageRenderer(size: size).image { _ in
                icon.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }()

    /// Register the remote commands (once per activation). ±15s skips are
    /// disabled so the lock screen shows track-style chapter arrows instead.
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
    }

    /// Remove the command targets and clear the widget.
    func deactivate() {
        for (command, token) in tokens { command.removeTarget(token) }
        tokens.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Chapter title as the headline, book title on the "artist" line, chapter
    /// position as the track number — the natural Apple Music mapping.
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

    /// Written at transitions only (play / pause / seek / speed change) — never
    /// per frame. The system extrapolates the playhead from elapsed + rate.
    func setPlayback(elapsed: Double, rate: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Enable/disable the chapter arrows at book boundaries.
    func setChapterBounds(hasPrevious: Bool, hasNext: Bool) {
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = hasPrevious
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = hasNext
    }

    /// Register `handler` for `command`, hopping to the main actor first —
    /// remote commands don't guarantee main-thread delivery.
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
