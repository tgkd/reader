import Foundation

public enum NarrationAudio {
    public static let mp3BytesPerSecond = 16_000.0

    public static func seconds(bytes: Int) -> Double {
        Double(bytes) / mp3BytesPerSecond
    }
}
