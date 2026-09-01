import Foundation

public enum AlignmentStitcher {
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
            offset += seg.stitchAdvance
        }

        return SynthesizedAudio(
            audio: audio,
            alignment: Alignment(characters: characters, startTimes: startTimes, endTimes: endTimes),
            text: text
        )
    }
}
