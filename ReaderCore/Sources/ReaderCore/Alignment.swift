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
