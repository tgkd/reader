import Foundation

public enum PlaybackStop: Equatable {
    case interrupted(time: Double)
    case completed
}

public enum ReadingProgressResolver {
    public static func resolve(_ stop: PlaybackStop,
                               duration: Double,
                               chapterIndex: Int) -> ReadingProgress? {
        guard duration > 0 else { return nil }
        let index = max(0, chapterIndex)
        switch stop {
        case .interrupted(let time):
            guard time > 0 else { return nil }
            return ReadingProgress(chapterIndex: index, time: min(time, duration),
                                   duration: duration)
        case .completed:
            return ReadingProgress(chapterIndex: index, time: duration, duration: duration)
        }
    }
}
