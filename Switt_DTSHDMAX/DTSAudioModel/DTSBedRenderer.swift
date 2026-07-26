import Foundation

/// Deterministic integer bed rendering using DTS speaker semantics.
public enum DTSBedRenderer {
    /// Folds WAVE 7.1 (`L R C LFE Lsr Rsr Lss Rss`) to WAVE 5.1(side)
    /// (`L R C LFE Ls Rs`). Rear and side surround feeds are summed at
    /// -3.0103 dB each, matching the DTS 7.1-to-5.1 topology described by
    /// ETSI TS 102 114; 24-bit overflow is saturated.
    public static func sevenOneToFiveOne(_ input: PCMBuffer) throws -> PCMBuffer {
        guard input.format.layout == .sevenOne else {
            throw DTSError.invalidArgument("7.1-to-5.1 rendering requires a WAVE 7.1 input")
        }
        let outputFormat = try PCMFormat(
            sampleRate: input.format.sampleRate,
            bitDepth: input.format.bitDepth,
            layout: .fiveOneSide
        )
        var leftSurround: [Int32] = []
        var rightSurround: [Int32] = []
        leftSurround.reserveCapacity(input.sampleCount)
        rightSurround.reserveCapacity(input.sampleCount)
        for sample in 0..<input.sampleCount {
            leftSurround.append(equalPowerSum(input.planes[4][sample], input.planes[6][sample]))
            rightSurround.append(equalPowerSum(input.planes[5][sample], input.planes[7][sample]))
        }
        return try PCMBuffer(
            format: outputFormat,
            planes: [
                input.planes[0], input.planes[1], input.planes[2], input.planes[3],
                leftSurround, rightSurround
            ]
        )
    }

    static func equalPowerSum(_ first: Int32, _ second: Int32) -> Int32 {
        // round(2^30 / sqrt(2)); integer math makes the renderer reproducible.
        let coefficient: Int64 = 759_250_125
        let scale: Int64 = 1 << 30
        let halfScale = scale >> 1
        let product = (Int64(first) + Int64(second)) * coefficient
        let rounded = product >= 0
            ? (product + halfScale) / scale
            : (product - halfScale) / scale
        return Int32(clamping: min(Int64(8_388_607), max(Int64(-8_388_608), rounded)))
    }
}
