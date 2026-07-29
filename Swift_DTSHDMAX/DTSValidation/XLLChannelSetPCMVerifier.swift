import Foundation

public struct XLLChannelPCMComparison: Sendable, Equatable, Codable {
    public let channel: Int
    public let expectedSampleCount: Int
    public let decodedSampleCount: Int
    public let mismatchCount: Int
    public let firstMismatchSample: Int?
    public let expectedAtFirstMismatch: Int32?
    public let actualAtFirstMismatch: Int32?
    public let nonzeroTailSampleCount: Int

    public var isBitExactWithZeroPadding: Bool {
        expectedSampleCount <= decodedSampleCount
            && mismatchCount == 0
            && nonzeroTailSampleCount == 0
    }
}

public struct XLLChannelSetPCMVerificationReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let streamSHA256: String
    public let accessUnitCount: Int
    public let xllFrameCount: Int
    public let channelSetIndex: Int
    public let speakerMask: UInt64
    public let residualChannelMask: UInt64
    public let frameSampleCount: Int
    public let initialDecodingDelayFrames: Int
    public let initialDecodingDelaySamples: Int
    public let coreCompatiblePrimingSampleCount: Int
    public let totalLeadingTrimSampleCount: Int
    public let comparisons: [XLLChannelPCMComparison]
    public let isBitExactWithZeroPadding: Bool
}

public enum XLLChannelSetPCMVerifier {
    public static func verify(
        inputURL: URL,
        channelSetIndex: Int,
        expectedChannelURLs: [URL]
    ) throws -> XLLChannelSetPCMVerificationReport {
        guard channelSetIndex >= 0, !expectedChannelURLs.isEmpty else {
            throw DTSError.invalidArgument("XLL channel-set verification requires an index and expected channels")
        }
        let input = inputURL.standardizedFileURL
        let stream = try XLLPBRStreamReader.read(inputURL: input)
        guard !stream.frames.isEmpty else { throw DTSError.malformed("DTS stream contains no complete XLL frames") }
        var decodedPlanes = Array(repeating: [Int32](), count: expectedChannelURLs.count)
        var speakerMask: UInt64?
        var residualMask: UInt64?
        var frameSampleCount: Int?
        for (frameIndex, frame) in stream.frames.enumerated() {
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            guard channelSetIndex < decoded.channelSets.count else {
                throw DTSError.malformed("XLL frame \(frameIndex) has no channel set \(channelSetIndex)")
            }
            let channelSet = decoded.channelSets[channelSetIndex]
            guard channelSet.planes.count == expectedChannelURLs.count else {
                throw DTSError.invalidArgument(
                    "XLL channel set \(channelSetIndex) has \(channelSet.planes.count) channels, expected \(expectedChannelURLs.count) paths"
                )
            }
            guard speakerMask == nil || speakerMask == channelSet.speakerMask,
                  residualMask == nil || residualMask == channelSet.residualChannelMask,
                  frameSampleCount == nil || frameSampleCount == decoded.sampleCount else {
                throw DTSError.malformed("XLL channel-set configuration changes at frame \(frameIndex)")
            }
            speakerMask = channelSet.speakerMask
            residualMask = channelSet.residualChannelMask
            frameSampleCount = decoded.sampleCount
            for channel in decodedPlanes.indices {
                decodedPlanes[channel].append(contentsOf: channelSet.planes[channel])
            }
        }
        let expectedPlanes = try expectedChannelURLs.map(WaveFile.readMono24)
        let delaySamples = stream.initialDecodingDelayFrames * (frameSampleCount ?? 0)
        let leadingTrim = stream.coreCompatiblePrimingSampleCount + delaySamples
        guard decodedPlanes.allSatisfy({ $0.count >= leadingTrim }) else {
            throw DTSError.truncated(field: "XLL initial decoding delay", bitOffset: 0)
        }
        let timeAlignedPlanes = decodedPlanes.map { Array($0.dropFirst(leadingTrim)) }
        let comparisons = try zip(expectedPlanes, timeAlignedPlanes).enumerated().map {
            channel, pair in
            try compare(channel: channel, expected: pair.0, decoded: pair.1)
        }
        return XLLChannelSetPCMVerificationReport(
            inputPath: input.path,
            streamSHA256: try SHA256Hasher.hash(fileAt: input),
            accessUnitCount: stream.accessUnitCount,
            xllFrameCount: stream.frames.count,
            channelSetIndex: channelSetIndex,
            speakerMask: speakerMask ?? 0,
            residualChannelMask: residualMask ?? 0,
            frameSampleCount: frameSampleCount ?? 0,
            initialDecodingDelayFrames: stream.initialDecodingDelayFrames,
            initialDecodingDelaySamples: delaySamples,
            coreCompatiblePrimingSampleCount: stream.coreCompatiblePrimingSampleCount,
            totalLeadingTrimSampleCount: leadingTrim,
            comparisons: comparisons,
            isBitExactWithZeroPadding: comparisons.allSatisfy(\.isBitExactWithZeroPadding)
        )
    }

    private static func compare(
        channel: Int,
        expected: [Int32],
        decoded: [Int32]
    ) throws -> XLLChannelPCMComparison {
        guard expected.count <= decoded.count else {
            throw DTSError.truncated(field: "decoded XLL PCM channel \(channel)", bitOffset: decoded.count * 24)
        }
        var mismatchCount = 0
        var firstMismatchSample: Int?
        for sample in expected.indices where expected[sample] != decoded[sample] {
            mismatchCount += 1
            if firstMismatchSample == nil { firstMismatchSample = sample }
        }
        let nonzeroTail = decoded[expected.count...].lazy.filter { $0 != 0 }.count
        return XLLChannelPCMComparison(
            channel: channel,
            expectedSampleCount: expected.count,
            decodedSampleCount: decoded.count,
            mismatchCount: mismatchCount,
            firstMismatchSample: firstMismatchSample,
            expectedAtFirstMismatch: firstMismatchSample.map { expected[$0] },
            actualAtFirstMismatch: firstMismatchSample.map { decoded[$0] },
            nonzeroTailSampleCount: nonzeroTail
        )
    }
}
