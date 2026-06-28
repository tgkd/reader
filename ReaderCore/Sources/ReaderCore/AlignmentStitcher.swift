import Foundation

/// Reassembles the per-segment synthesis of a chunked chapter (see `Chunker`)
/// into ONE `SynthesizedAudio` spanning the whole chapter: the segment audios are
/// concatenated, and each segment's character timings are shifted by the total
/// spoken duration of all preceding segments so the timeline stays continuous and
/// monotonically non-decreasing. Because `Chunker` is lossless, the concatenated
/// `characters` reconstruct the full chapter text 1:1 — preserving the
/// `CharTokenMapper` invariant across the chunk boundaries.
///
/// The per-segment offset is that segment's own spoken length — the max end time
/// of its alignment — which tracks the concatenated mp3 closely enough for
/// read-along; the tiny per-boundary encoder gaps are imperceptible over the
/// handful of segments a chapter splits into. (If audible drift ever appears,
/// offset by the measured audio duration instead.)
public enum AlignmentStitcher {
    /// Stitch segments **in order**. Requires at least one segment; a single
    /// segment is returned unchanged (the common, no-chunking case).
    public static func stitch(_ segments: [SynthesizedAudio]) -> SynthesizedAudio {
        precondition(!segments.isEmpty, "stitch requires at least one segment")
        if segments.count == 1 { return segments[0] }

        var characters: [String] = []
        var startTimes: [Double] = []
        var endTimes: [Double] = []
        var audio = Data()
        var text = ""
        var offset = 0.0

        for seg in segments {
            let a = seg.alignment
            characters.append(contentsOf: a.characters)
            startTimes.append(contentsOf: a.startTimes.map { $0 + offset })
            endTimes.append(contentsOf: a.endTimes.map { $0 + offset })
            audio.append(seg.audio)
            text += seg.text
            // Advance the clock by this segment's spoken length so the next
            // segment's timings sit after it on a single continuous timeline.
            offset += a.endTimes.max() ?? 0
        }

        return SynthesizedAudio(
            audio: audio,
            alignment: Alignment(characters: characters, startTimes: startTimes, endTimes: endTimes),
            text: text
        )
    }
}
