import Foundation

public enum PlaybackStop: Equatable {
    case interrupted(time: Double)
    case completed
}

public enum ReadingProgressResolver {
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
