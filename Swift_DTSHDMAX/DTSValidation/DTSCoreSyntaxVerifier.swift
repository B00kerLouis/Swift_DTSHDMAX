import Foundation

public struct DTSCoreSyntaxVerificationReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let inputSHA256: String
    public let frameCount: Int
    public let totalCoreByteCount: Int
    public let totalSampleCount: Int
    public let frameByteCounts: [Int]
    public let pcmBlockCounts: [Int]
    public let audioModes: [Int]
    public let sampleRates: [Int]
    public let bitrates: [Int]
    public let primaryChannelCounts: [Int]
    public let subframeCounts: [Int]
    public let primaryAudioHeaderEndBitOffsets: [Int]
    public let primaryAudioDataEndBitOffsets: [Int]
    public let bitAllocationIndices: [Int]
    public let bitAllocationHistogram: [Int: Int]
    public let bitAllocationCountsByChannel: [[Int]]
    public let predictionEnabledBandCount: Int
    public let nonzeroTransitionBandCount: Int
    public let highFrequencyVQStartSubbands: [Int]
    public let highFrequencyVQIndices: [Int]
    public let synchronizedSubSubframeCount: Int
    public let firstFrame: DTSCoreFrameSyntax
    public let allFramesParsed: Bool
}

public enum DTSCoreSyntaxVerifier {
    public static func verify(inputURL: URL) throws -> DTSCoreSyntaxVerificationReport {
        let input = inputURL.standardizedFileURL
        let accessUnits = try DTSStreamInspector().inspect(url: input, maximumAccessUnits: Int.max)
        guard !accessUnits.isEmpty, accessUnits.allSatisfy({ $0.coreByteCount != nil }) else {
            throw DTSError.unsupported("Core syntax verification requires Core in every access unit")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: input) }
        catch { throw DTSError.io("cannot open \(input.path): \(error.localizedDescription)") }
        defer { try? handle.close() }

        var firstFrame: DTSCoreFrameSyntax?
        var frameByteCounts = Set<Int>()
        var pcmBlockCounts = Set<Int>()
        var audioModes = Set<Int>()
        var sampleRates = Set<Int>()
        var bitrates = Set<Int>()
        var primaryChannelCounts = Set<Int>()
        var subframeCounts = Set<Int>()
        var headerEndOffsets = Set<Int>()
        var audioEndOffsets = Set<Int>()
        var bitAllocationIndices = Set<Int>()
        var bitAllocationHistogram: [Int: Int] = [:]
        var bitAllocationCountsByChannel = Array(
            repeating: Array(repeating: 0, count: 27),
            count: 5
        )
        var highFrequencyVQStartSubbands = Set<Int>()
        var highFrequencyVQIndices = Set<Int>()
        var predictionEnabledBandCount = 0
        var nonzeroTransitionBandCount = 0
        var synchronizedSubSubframeCount = 0
        var totalCoreByteCount = 0
        var totalSampleCount = 0

        for accessUnit in accessUnits {
            let coreByteCount = accessUnit.coreByteCount!
            do { try handle.seek(toOffset: accessUnit.byteOffset) }
            catch { throw DTSError.io("cannot seek Core frame: \(error.localizedDescription)") }
            let frame: Data
            do { frame = try handle.read(upToCount: coreByteCount) ?? Data() }
            catch { throw DTSError.io("cannot read Core frame: \(error.localizedDescription)") }
            guard frame.count == coreByteCount else {
                throw DTSError.truncated(field: "DTS Core frame", bitOffset: Int(accessUnit.byteOffset) * 8)
            }
            let syntax = try DTSCoreSyntaxParser.parse(frame: frame)
            if firstFrame == nil { firstFrame = syntax }
            frameByteCounts.insert(syntax.bitstreamHeader.frameByteCount)
            pcmBlockCounts.insert(syntax.bitstreamHeader.pcmBlockCount)
            audioModes.insert(syntax.bitstreamHeader.audioMode)
            sampleRates.insert(syntax.bitstreamHeader.sampleRate)
            bitrates.insert(syntax.bitstreamHeader.bitrate)
            primaryChannelCounts.insert(syntax.primaryAudioHeader.primaryChannelCount)
            subframeCounts.insert(syntax.primaryAudioHeader.subframeCount)
            headerEndOffsets.insert(syntax.primaryAudioHeader.endBitOffset)
            audioEndOffsets.insert(syntax.primaryAudioDataEndBitOffset)
            highFrequencyVQStartSubbands.formUnion(
                syntax.primaryAudioHeader.highFrequencyVQStartSubbands
            )
            if syntax.bitstreamHeader.syncSubSubframes {
                synchronizedSubSubframeCount += 1
            }
            for subframe in syntax.subframes {
                for (channelIndex, channel) in subframe.bitAllocations.enumerated() {
                    bitAllocationIndices.formUnion(channel)
                    for allocation in channel {
                        bitAllocationHistogram[allocation, default: 0] += 1
                        if bitAllocationCountsByChannel.indices.contains(channelIndex),
                           bitAllocationCountsByChannel[channelIndex].indices.contains(allocation) {
                            bitAllocationCountsByChannel[channelIndex][allocation] += 1
                        }
                    }
                }
                predictionEnabledBandCount += subframe.predictionModes.reduce(0) {
                    $0 + $1.lazy.filter(\.self).count
                }
                nonzeroTransitionBandCount += subframe.transitionModes.reduce(0) {
                    $0 + $1.lazy.filter { $0 != 0 }.count
                }
                for channel in subframe.highFrequencyVQIndices {
                    highFrequencyVQIndices.formUnion(channel)
                }
            }
            totalCoreByteCount += coreByteCount
            totalSampleCount += syntax.bitstreamHeader.pcmBlockCount * 32
        }
        guard let firstFrame else { throw DTSError.malformed("DTS Core stream is empty") }
        return DTSCoreSyntaxVerificationReport(
            inputPath: input.path,
            inputSHA256: try SHA256Hasher.hash(fileAt: input),
            frameCount: accessUnits.count,
            totalCoreByteCount: totalCoreByteCount,
            totalSampleCount: totalSampleCount,
            frameByteCounts: frameByteCounts.sorted(),
            pcmBlockCounts: pcmBlockCounts.sorted(),
            audioModes: audioModes.sorted(),
            sampleRates: sampleRates.sorted(),
            bitrates: bitrates.sorted(),
            primaryChannelCounts: primaryChannelCounts.sorted(),
            subframeCounts: subframeCounts.sorted(),
            primaryAudioHeaderEndBitOffsets: headerEndOffsets.sorted(),
            primaryAudioDataEndBitOffsets: audioEndOffsets.sorted(),
            bitAllocationIndices: bitAllocationIndices.sorted(),
            bitAllocationHistogram: bitAllocationHistogram,
            bitAllocationCountsByChannel: bitAllocationCountsByChannel,
            predictionEnabledBandCount: predictionEnabledBandCount,
            nonzeroTransitionBandCount: nonzeroTransitionBandCount,
            highFrequencyVQStartSubbands: highFrequencyVQStartSubbands.sorted(),
            highFrequencyVQIndices: highFrequencyVQIndices.sorted(),
            synchronizedSubSubframeCount: synchronizedSubSubframeCount,
            firstFrame: firstFrame,
            allFramesParsed: true
        )
    }
}
