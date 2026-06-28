import Foundation

/// Why playback stopped — the input that decides what reading progress to persist.
public enum PlaybackStop: Equatable {
    /// Paused, left the reader, or backgrounded mid-chapter: persist the live
    /// playhead. A zero playhead means "opened but never played" and must NOT be
    /// written, or it would clobber a real saved position with zeros.
    case interrupted(time: Double)
    /// Played to the natural end. Persist as complete (fraction → chapter end) even
    /// though `AVAudioPlayer` reports a reset (0) playhead at that instant — reading
    /// the player here is exactly the bug that left finished chapters stuck mid-bar
    /// instead of showing 読了.
    case completed
}

/// Pure decision for what `ReadingProgress` (if any) to write back when playback
/// stops. Kept UI-free and in `ReaderCore` so the writeback rules — which the
/// `AVAudioPlayer` completion quirk makes easy to get wrong — are `swift test`-able.
public enum ReadingProgressResolver {
    /// The progress to persist, or `nil` when nothing should be written.
    /// `duration` is the loaded chapter's length; `chapterIndex` / `chapterCount`
    /// give the book-level fraction the library progress bar reads.
    public static func resolve(_ stop: PlaybackStop,
                               duration: Double,
                               chapterIndex: Int,
                               chapterCount: Int) -> ReadingProgress? {
        guard duration > 0 else { return nil }
        let chapters = Double(max(1, chapterCount))
        let index = max(0, chapterIndex)
        switch stop {
        case .interrupted(let time):
            guard time > 0 else { return nil }
            let within = min(1, time / duration)
            return ReadingProgress(chapterIndex: index, time: time,
                                   fraction: (Double(index) + within) / chapters)
        case .completed:
            return ReadingProgress(chapterIndex: index, time: duration,
                                   fraction: (Double(index) + 1) / chapters)
        }
    }
}
