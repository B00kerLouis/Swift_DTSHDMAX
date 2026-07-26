import Foundation

public struct XLLDecodedChannelSetSummary: Sendable, Equatable, Codable {
    public let channelSetIndex: Int
    public let channelCount: Int
    public let speakerMask: UInt64
    public let residualChannelMasks: [UInt64]
    public let residualChannelMaskFirstFrameIndices: [String: Int]
    public let storageBitDepths: [Int]
    public let maximumAbsoluteSample: Int64
    public let maximumAbsoluteSampleFrameIndex: Int
    public let samplesOutsideSigned24Bit: Int
}

public struct XLLDecodeVerificationReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let streamSHA256: String
    public let accessUnitCount: Int
    public let xllFrameCount: Int
    public let crossAccessUnitFrameCount: Int
    public let decodedSampleCountPerChannel: Int
    public let hybridRiceParameterCount: Int
    public let hybridIsolatedSampleCount: Int
    public let channelSets: [XLLDecodedChannelSetSummary]
    public let allFramesDecoded: Bool
}

public enum XLLDecodeVerifier {
    public static func verify(inputURL: URL) throws -> XLLDecodeVerificationReport {
        let input = inputURL.standardizedFileURL
        let stream = try XLLPBRStreamReader.read(inputURL: input)
        guard !stream.frames.isEmpty else { throw DTSError.malformed("DTS stream contains no complete XLL frames") }
        var expectedConfigurations: [(channelCount: Int, speakerMask: UInt64)]?
        var observedResidualMasks: [Set<UInt64>] = []
        var residualMaskFirstFrames: [[UInt64: Int]] = []
        var observedStorageBitDepths: [Set<Int>] = []
        var maximumAbsoluteSamples: [Int64] = []
        var maximumAbsoluteSampleFrameIndices: [Int] = []
        var samplesOutsideSigned24Bit: [Int] = []
        var totalSamples = 0
        var hybridRiceParameterCount = 0
        var hybridIsolatedSampleCount = 0
        for (frameIndex, frame) in stream.frames.enumerated() {
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            let configurations = decoded.channelSets.map {
                ($0.planes.count, $0.speakerMask)
            }
            if let expectedConfigurations {
                guard expectedConfigurations.elementsEqual(configurations, by: {
                    $0.channelCount == $1.0 && $0.speakerMask == $1.1
                }) else {
                    throw DTSError.malformed("XLL channel-set configuration changes at frame \(frameIndex)")
                }
            } else {
                expectedConfigurations = configurations
                maximumAbsoluteSamples = Array(repeating: 0, count: configurations.count)
                maximumAbsoluteSampleFrameIndices = Array(repeating: 0, count: configurations.count)
                samplesOutsideSigned24Bit = Array(repeating: 0, count: configurations.count)
                observedResidualMasks = Array(repeating: [], count: configurations.count)
                residualMaskFirstFrames = Array(repeating: [:], count: configurations.count)
                observedStorageBitDepths = Array(repeating: [], count: configurations.count)
            }
            for (index, channelSet) in decoded.channelSets.enumerated() {
                observedResidualMasks[index].insert(channelSet.residualChannelMask)
                if residualMaskFirstFrames[index][channelSet.residualChannelMask] == nil {
                    residualMaskFirstFrames[index][channelSet.residualChannelMask] = frameIndex
                }
                observedStorageBitDepths[index].insert(channelSet.storageBitDepth)
                let samples = channelSet.planes.lazy.flatMap { $0 }
                let maximum = samples.reduce(Int64(0)) {
                    max($0, abs(Int64($1)))
                }
                if maximum > maximumAbsoluteSamples[index] {
                    maximumAbsoluteSamples[index] = maximum
                    maximumAbsoluteSampleFrameIndices[index] = frameIndex
                }
                samplesOutsideSigned24Bit[index] += samples.reduce(0) {
                    let value = Int64($1)
                    return $0 + (value < -8_388_608 || value > 8_388_607 ? 1 : 0)
                }
            }
            totalSamples += decoded.sampleCount
            hybridRiceParameterCount += decoded.hybridRiceParameterCount
            hybridIsolatedSampleCount += decoded.hybridIsolatedSampleCount
        }
        let configurations = expectedConfigurations ?? []
        return XLLDecodeVerificationReport(
            inputPath: input.path,
            streamSHA256: try SHA256Hasher.hash(fileAt: input),
            accessUnitCount: stream.accessUnitCount,
            xllFrameCount: stream.frames.count,
            crossAccessUnitFrameCount: stream.frames.filter { $0.startAccessUnit != $0.endAccessUnit }.count,
            decodedSampleCountPerChannel: totalSamples,
            hybridRiceParameterCount: hybridRiceParameterCount,
            hybridIsolatedSampleCount: hybridIsolatedSampleCount,
            channelSets: configurations.enumerated().map { index, configuration in
                XLLDecodedChannelSetSummary(
                    channelSetIndex: index,
                    channelCount: configuration.channelCount,
                    speakerMask: configuration.speakerMask,
                    residualChannelMasks: observedResidualMasks[index].sorted(),
                    residualChannelMaskFirstFrameIndices: Dictionary(
                        uniqueKeysWithValues: residualMaskFirstFrames[index].map {
                            (String($0.key), $0.value)
                        }
                    ),
                    storageBitDepths: observedStorageBitDepths[index].sorted(),
                    maximumAbsoluteSample: maximumAbsoluteSamples[index],
                    maximumAbsoluteSampleFrameIndex: maximumAbsoluteSampleFrameIndices[index],
                    samplesOutsideSigned24Bit: samplesOutsideSigned24Bit[index]
                )
            },
            allFramesDecoded: totalSamples > 0
        )
    }
}
