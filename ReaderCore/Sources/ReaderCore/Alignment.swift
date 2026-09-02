import Foundation

public struct Alignment: Codable, Equatable {
    public let characters: [String]
    public let startTimes: [Double]
    public let endTimes: [Double]

    enum CodingKeys: String, CodingKey {
        case characters
        case startTimes = "character_start_times_seconds"
        case endTimes = "character_end_times_seconds"
    }

    public init(characters: [String], startTimes: [Double], endTimes: [Double]) {
        self.characters = characters
        self.startTimes = startTimes
        self.endTimes = endTimes
    }

    public var untimedTrailingCharacters: Int {
        guard characters.count == endTimes.count, !endTimes.isEmpty else { return 0 }
        var k = endTimes.count
        while k > 0, endTimes[k - 1] <= (k >= 2 ? endTimes[k - 2] : 0) + 1e-9 { k -= 1 }
        return endTimes.count - k
    }

    public var untimedTrailingSpeech: Int {
        let n = untimedTrailingCharacters
        guard n > 0 else { return 0 }
        return characters.suffix(n).filter(Furigana.hasWordCharacter).count
    }

    public static let collapsedRunMinLength = 8
    public static let collapsedCharacterMaxSeconds = 0.02
    public static let collapseRepairMinSeconds = 0.3

    public var collapsedSpeechRuns: [Range<Int>] {
        guard characters.count == startTimes.count, characters.count == endTimes.count else { return [] }
        let stop = characters.count - untimedTrailingCharacters
        var runs: [Range<Int>] = []
        var i = 0
        while i < stop {
            guard isCollapsedSpeech(i) else { i += 1; continue }
            var j = i
            while j < stop, isCollapsedSpeech(j) { j += 1 }
            if j - i >= Self.collapsedRunMinLength { runs.append(i..<j) }
            i = j
        }
        return runs
    }

    private func isCollapsedSpeech(_ i: Int) -> Bool {
        Furigana.hasWordCharacter(characters[i])
            && endTimes[i] - startTimes[i] <= Self.collapsedCharacterMaxSeconds
    }

    public func repairingCollapsedRuns(audioSeconds: Double) -> Alignment {
        guard let last = endTimes.last else { return self }
        let delta = audioSeconds - last
        guard delta >= Self.collapseRepairMinSeconds else { return self }
        let runs = collapsedSpeechRuns
        guard !runs.isEmpty else { return self }

        var starts = startTimes
        var ends = endTimes
        let total = Double(runs.reduce(0) { $0 + $1.count })
        var shift = 0.0
        for run in runs {
            let add = delta * Double(run.count) / total
            let per = add / Double(run.count)
            for (n, k) in run.enumerated() {
                starts[k] = startTimes[k] + shift + per * Double(n)
                ends[k] = startTimes[k] + shift + per * Double(n + 1)
            }
            shift += add
            for k in run.upperBound..<characters.count {
                starts[k] = startTimes[k] + shift
                ends[k] = endTimes[k] + shift
            }
        }
        return Alignment(characters: characters, startTimes: starts, endTimes: ends)
    }

    public struct PauseAttribution: Equatable {
        public let onSpeech: Int
        public let onPunctuation: Int
    }

    public func pauseAttribution(minSeconds: Double = 0.8) -> PauseAttribution {
        guard characters.count == startTimes.count, characters.count == endTimes.count else {
            return PauseAttribution(onSpeech: 0, onPunctuation: 0)
        }
        var speech = 0
        var punctuation = 0
        for i in characters.indices where endTimes[i] - startTimes[i] >= minSeconds {
            if Furigana.hasWordCharacter(characters[i]) { speech += 1 } else { punctuation += 1 }
        }
        return PauseAttribution(onSpeech: speech, onPunctuation: punctuation)
    }

    public func describes(_ text: String, audioSeconds: Double, tolerance: Double = 1.0) -> Bool {
        guard !characters.isEmpty,
              startTimes.count == characters.count,
              endTimes.count == characters.count,
              characters.allSatisfy({ $0.count == 1 }),
              characters.joined() == text,
              untimedTrailingSpeech == 0 else { return false }
        for i in characters.indices {
            guard startTimes[i].isFinite, endTimes[i].isFinite,
                  endTimes[i] >= startTimes[i],
                  i == 0 || startTimes[i] >= startTimes[i - 1] else { return false }
        }
        return abs(audioSeconds - (endTimes.last ?? 0)) <= tolerance
    }

    public func silences(minimumSeconds: Double) -> [ClosedRange<Double>] {
        guard characters.count == startTimes.count, characters.count == endTimes.count else { return [] }
        var out: [ClosedRange<Double>] = []
        var open: (start: Double, end: Double)?
        func extend(_ a: Double, _ b: Double) {
            guard b > a else { return }
            if let o = open, a <= o.end + 1e-9 {
                open = (o.start, max(o.end, b))
                return
            }
            if let o = open, o.end - o.start >= minimumSeconds { out.append(o.start...o.end) }
            open = (a, b)
        }
        for i in characters.indices {
            if i > 0 { extend(endTimes[i - 1], startTimes[i]) }
            if !Furigana.hasWordCharacter(characters[i]) { extend(startTimes[i], endTimes[i]) }
        }
        if let o = open, o.end - o.start >= minimumSeconds { out.append(o.start...o.end) }
        return out
    }

    public func nextSilence(after t: Double, minimumSeconds: Double) -> ClosedRange<Double>? {
        silences(minimumSeconds: minimumSeconds).first { $0.upperBound > t }
    }

    public func shifted(by seconds: Double) -> Alignment {
        guard seconds != 0 else { return self }
        return Alignment(characters: characters,
                         startTimes: startTimes.map { $0 + seconds },
                         endTimes: endTimes.map { $0 + seconds })
    }

    func startTime(at i: Int) -> Double {
        guard !startTimes.isEmpty else { return 0 }
        return startTimes[min(max(i, 0), startTimes.count - 1)]
    }

    func endTime(at i: Int) -> Double {
        guard !endTimes.isEmpty else { return 0 }
        return endTimes[min(max(i, 0), endTimes.count - 1)]
    }
}

public struct AlignmentTrailer: Decodable {
    public let forcedAlignment: Alignment
    public let loss: Double?

    enum CodingKeys: String, CodingKey {
        case forcedAlignment = "forced_alignment"
        case loss = "forced_alignment_loss"
    }

    public init(forcedAlignment: Alignment, loss: Double?) {
        self.forcedAlignment = forcedAlignment
        self.loss = loss
    }
}

public struct TimestampedAudio: Decodable {
    public let audioBase64: String
    public let alignment: Alignment?
    public let normalizedAlignment: Alignment?

    enum CodingKeys: String, CodingKey {
        case audioBase64 = "audio_base64"
        case alignment
        case normalizedAlignment = "normalized_alignment"
    }
}
