import Foundation

struct ClusterProjection {
    let parseText: String
    let parseByteCount: Int

    private let map: [Int32]
    private let boundary: [Bool]

    init(normalized: String, byteCount: Int) {
        var hasSelector = false
        var scalarCount = 0
        for scalar in normalized.unicodeScalars {
            scalarCount += 1
            if Self.isVariationSelector(scalar) { hasSelector = true }
        }

        if hasSelector {
            var stripped = String.UnicodeScalarView()
            var map: [Int32] = []
            map.reserveCapacity(byteCount + 1)
            var offset = 0
            for scalar in normalized.unicodeScalars {
                let width = Self.width(scalar)
                if !Self.isVariationSelector(scalar) {
                    stripped.append(scalar)
                    for k in 0..<width { map.append(Int32(offset + k)) }
                }
                offset += width
            }
            map.append(Int32(byteCount))
            let text = String(stripped)
            self.parseText = text
            self.parseByteCount = map.count - 1
            self.map = map
        } else {
            self.parseText = normalized
            self.parseByteCount = byteCount
            self.map = []
        }

        if scalarCount == normalized.count {
            self.boundary = []
        } else {
            var boundary = [Bool](repeating: false, count: byteCount + 1)
            var offset = 0
            for character in normalized {
                boundary[offset] = true
                for scalar in character.unicodeScalars { offset += Self.width(scalar) }
            }
            boundary[byteCount] = true
            self.boundary = boundary
        }
    }

    func project(_ offset: Int) -> Int {
        map.isEmpty ? offset : Int(map[offset])
    }

    func snapForward(_ offset: Int) -> Int {
        guard !boundary.isEmpty else { return offset }
        var i = offset
        while !boundary[i] { i += 1 }
        return i
    }

    func snapBackward(_ offset: Int) -> Int {
        guard !boundary.isEmpty else { return offset }
        var i = offset
        while !boundary[i] { i -= 1 }
        return i
    }

    static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        VariationSelector.isSelector(scalar)
    }

    private static func width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x10000: return 3
        default: return 4
        }
    }
}
