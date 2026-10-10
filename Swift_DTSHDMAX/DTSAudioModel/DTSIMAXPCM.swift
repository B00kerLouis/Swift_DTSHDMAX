import Foundation

/// Fixed IMAX channel order: L R C LFE Lss Rss Lsr Rsr TFL TFR TBL TBR TFC.
/// This is the thirteen-plane render contract; the public compatibility bed
/// remains 7.1 and carries the metadata-declared contributions of the tops.
public struct DTSIMAXPCMBuffer: Sendable, Equatable {
    public static let sampleRate = 48_000
    public static let bitDepth = 24
    public static let channelNames = ["L","R","C","LFE","Lss","Rss","Lsr","Rsr","TFL","TFR","TBL","TBR","TFC"]
    public let planes: [[Int32]]
    public var sampleCount: Int { planes.first?.count ?? 0 }

    public init(planes: [[Int32]]) throws {
        guard planes.count == 13, let count = planes.first?.count,
              planes.allSatisfy({ $0.count == count && $0.allSatisfy { (-8_388_608...8_388_607).contains(Int($0)) } }) else {
            throw DTSError.invalidArgument("IMAX requires thirteen equal-length signed-24 PCM planes")
        }
        self.planes = planes
    }
}

enum DTSIMAXCompatibilityBedRenderer {
    static func tfcFold(_ value: Int64, gain: Int64) -> Int64 { (value * gain + 16_384) >> 15 }

    static func sample(_ planes: [[Int32]], _ index: Int) -> [Int64] {
        let c = Int64(planes[12][index])
        return [
            Int64(planes[0][index]) + Int64(planes[8][index]) + tfcFold(c, gain: 13_818),
            Int64(planes[1][index]) + Int64(planes[9][index]) + tfcFold(c, gain: 13_818),
            Int64(planes[2][index]) + tfcFold(c, gain: 27_571),
            Int64(planes[3][index]),
            Int64(planes[6][index]) + Int64(planes[10][index]),
            Int64(planes[7][index]) + Int64(planes[11][index]),
            Int64(planes[4][index]), Int64(planes[5][index])
        ]
    }

    static func render(_ source: DTSIMAXPCMBuffer) throws -> PCMBuffer {
        var planes = Array(repeating: [Int32](repeating: 0, count: source.sampleCount), count: 8)
        for index in 0..<source.sampleCount {
            let values = sample(source.planes, index)
            for channel in 0..<8 {
                guard (-8_388_608...8_388_607).contains(values[channel]) else {
                    throw DTSError.malformed("IMAX compatibility fold exceeds signed-24 range at sample \(index)")
                }
                planes[channel][index] = Int32(values[channel])
            }
        }
        return try PCMBuffer(format: PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .sevenOne), planes: planes)
    }

    static func constraintExtremes(_ planes: [[Int32]], _ sample: Int) -> DTS714RenderGuard.ConstraintExtremes {
        var result = DTS714RenderGuard.ConstraintExtremes()
        for plane in planes {
            result.planeMinimum = min(result.planeMinimum, Int64(plane[sample]))
            result.planeMaximum = max(result.planeMaximum, Int64(plane[sample]))
        }
        let bed = self.sample(planes, sample)
        for value in bed {
            result.foldMinimum = min(result.foldMinimum, value)
            result.foldMaximum = max(result.foldMaximum, value)
        }
        // The 6+2 Core-residual recovery sees C/LFE, folded L/R, and each
        // side+rear sum. TFC contributes to all three front constraints.
        for value in [bed[0],bed[1],bed[2],bed[3],bed[4]+bed[6],bed[5]+bed[7]] {
            result.recoveryMinimum = min(result.recoveryMinimum, value)
            result.recoveryMaximum = max(result.recoveryMaximum, value)
        }
        return result
    }
}
