import Foundation

public struct PCMComparison: Sendable, Equatable, Codable {
    public let samplesCompared: Int
    public let differentSamples: Int
    public let firstMismatchFrame: Int?
    public let firstMismatchChannel: Int?
    public let maximumAbsoluteDifference: Int64
    public let perChannelMismatchCount: [Int]

    public var isBitExact: Bool { differentSamples == 0 }
}

public enum PCMComparator {
    public static func compare(_ expected: PCMBuffer, _ actual: PCMBuffer) throws -> PCMComparison {
        guard expected.format == actual.format else {
            throw DTSError.invalidArgument("PCM formats differ: \(expected.format) vs \(actual.format)")
        }
        guard expected.sampleCount == actual.sampleCount else {
            throw DTSError.invalidArgument(
                "PCM sample counts differ: \(expected.sampleCount) vs \(actual.sampleCount)"
            )
        }

        var mismatchCount = 0
        var firstFrame: Int?
        var firstChannel: Int?
        var maximumDifference: Int64 = 0
        var perChannel = Array(repeating: 0, count: expected.format.layout.channelCount)
        for frame in 0..<expected.sampleCount {
            for channel in 0..<expected.format.layout.channelCount {
                let difference = abs(
                    Int64(expected.planes[channel][frame]) - Int64(actual.planes[channel][frame])
                )
                if difference != 0 {
                    mismatchCount += 1
                    perChannel[channel] += 1
                    if firstFrame == nil {
                        firstFrame = frame
                        firstChannel = channel
                    }
                    maximumDifference = max(maximumDifference, difference)
                }
            }
        }
        return PCMComparison(
            samplesCompared: expected.sampleCount * expected.format.layout.channelCount,
            differentSamples: mismatchCount,
            firstMismatchFrame: firstFrame,
            firstMismatchChannel: firstChannel,
            maximumAbsoluteDifference: maximumDifference,
            perChannelMismatchCount: perChannel
        )
    }

    public static func compareWithZeroPadding(
        expected: PCMBuffer,
        paddedActual: PCMBuffer
    ) throws -> PCMPaddedComparison {
        guard expected.format == paddedActual.format else {
            throw DTSError.invalidArgument("PCM formats differ: \(expected.format) vs \(paddedActual.format)")
        }
        guard paddedActual.sampleCount >= expected.sampleCount else {
            throw DTSError.invalidArgument("actual PCM is shorter than expected PCM")
        }
        let prefix = try PCMBuffer(
            format: paddedActual.format,
            planes: paddedActual.planes.map { Array($0.prefix(expected.sampleCount)) }
        )
        let comparison = try compare(expected, prefix)
        var nonZeroPaddingSamples = 0
        if paddedActual.sampleCount > expected.sampleCount {
            for plane in paddedActual.planes {
                nonZeroPaddingSamples += plane[expected.sampleCount...].lazy.filter { $0 != 0 }.count
            }
        }
        return PCMPaddedComparison(
            prefix: comparison,
            paddingFrames: paddedActual.sampleCount - expected.sampleCount,
            nonZeroPaddingSamples: nonZeroPaddingSamples
        )
    }
}

public struct PCMPaddedComparison: Sendable, Equatable, Codable {
    public let prefix: PCMComparison
    public let paddingFrames: Int
    public let nonZeroPaddingSamples: Int

    public var isBitExact: Bool { prefix.isBitExact && nonZeroPaddingSamples == 0 }
}
