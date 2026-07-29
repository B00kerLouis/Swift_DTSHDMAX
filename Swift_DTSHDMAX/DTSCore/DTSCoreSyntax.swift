import Foundation

public struct DTSCoreBitstreamHeader: Sendable, Equatable, Codable {
    public let normalFrame: Bool
    public let deficitSampleCount: Int
    public let crcPresent: Bool
    public let pcmBlockCount: Int
    public let frameByteCount: Int
    public let audioMode: Int
    public let primaryChannelCount: Int
    public let sampleRateCode: Int
    public let sampleRate: Int
    public let bitrateCode: Int
    public let bitrate: Int
    public let dynamicRangePresent: Bool
    public let timestampPresent: Bool
    public let auxiliaryDataPresent: Bool
    public let hdcdMaster: Bool
    public let extensionAudioType: Int
    public let extensionAudioPresent: Bool
    public let syncSubSubframes: Bool
    public let lfeCode: Int
    public let predictorHistory: Bool
    public let headerCRC: UInt16?
    public let perfectFilter: Bool
    public let encoderRevision: Int
    public let copyHistory: Int
    public let sourcePCMResolutionCode: Int
    public let sourcePCMBitDepth: Int
    public let extendedSurround: Bool
    public let sumDifferenceFront: Bool
    public let sumDifferenceSurround: Bool
    public let dialogNormalizationCode: Int
}

public struct DTSCorePrimaryAudioCodingHeader: Sendable, Equatable, Codable {
    public let subframeCount: Int
    public let primaryChannelCount: Int
    public let subbandActivityCounts: [Int]
    public let highFrequencyVQStartSubbands: [Int]
    public let jointIntensityIndices: [Int]
    public let transitionModeSelectors: [Int]
    public let scaleFactorSelectors: [Int]
    public let bitAllocationSelectors: [Int]
    public let quantizationIndexSelectors: [[Int]]
    public let scaleFactorAdjustmentCodes: [[Int?]]
    public let audioHeaderCRC: UInt16?
    public let endBitOffset: Int
}

public struct DTSCoreSubframeSyntax: Sendable, Equatable, Codable {
    public let index: Int
    public let subSubframeCount: Int
    public let partialSampleCountCode: Int
    public let predictionModes: [[Bool]]
    public let predictionVQIndices: [[Int?]]
    public let bitAllocations: [[Int]]
    public let transitionModes: [[Int]]
    public let scaleFactorIndices: [[[Int]]]
    public let highFrequencyVQIndices: [[Int]]
    public let lfeSamples: [Int32]
    public let lfeScaleFactorIndex: Int?
    /// Quantizer-domain samples for the scalar-coded bands. The dimensions are
    /// channel, band, then the complete subframe sample timeline.
    public let quantizedSubbandSamples: [[[Int32]]]
    public let sideInformationEndBitOffset: Int
    public let audioDataEndBitOffset: Int
    public let dsyncCount: Int
}

public struct DTSCoreFrameSyntax: Sendable, Equatable, Codable {
    public let bitstreamHeader: DTSCoreBitstreamHeader
    public let primaryAudioHeader: DTSCorePrimaryAudioCodingHeader
    public let subframes: [DTSCoreSubframeSyntax]
    public let primaryAudioDataEndBitOffset: Int
}

/// Parser for the public DTS Coherent Acoustics Core frame and primary audio
/// coding headers. Audio subframes are deliberately left to the decoder stage;
/// this type already validates the exact topology and codebook selectors that
/// the native fixed-point decode loop must consume.
public enum DTSCoreSyntaxParser {
    private static let channelCounts = [1, 2, 2, 2, 2, 3, 3, 4, 4, 5, 6, 6, 6, 7, 8, 8]
    private static let sampleRates = [
        0, 8_000, 16_000, 32_000, 0, 0, 11_025, 22_050,
        44_100, 0, 0, 12_000, 24_000, 48_000, 96_000, 192_000
    ]
    private static let bitrates = [
        32_000, 56_000, 64_000, 96_000, 112_000, 128_000, 192_000, 224_000,
        256_000, 320_000, 384_000, 448_000, 512_000, 576_000, 640_000, 768_000,
        896_000, 1_024_000, 1_152_000, 1_280_000, 1_344_000, 1_408_000,
        1_411_200, 1_472_000, 1_536_000, 1_920_000, 2_048_000, 3_072_000,
        3_840_000, 1, 2, 3
    ]
    private static let sourcePCMBitDepths = [16, 16, 20, 20, 0, 24, 24, 0]
    private static let quantizationSelectorBitCounts = [1, 2, 2, 2, 2, 3, 3, 3, 3, 3]
    private static let quantizationSelectorGroupSizes = [1, 3, 3, 3, 3, 7, 7, 7, 7, 7]

    public static func parse(frame data: Data) throws -> DTSCoreFrameSyntax {
        var reader = try BitReader(data: data)
        guard try reader.read(32, field: "DTS Core sync") == 0x7ffe_8001 else {
            throw DTSError.malformed("DTS Core sync word is missing")
        }
        let normalFrame = try reader.read(1, field: "FTYPE") == 1
        let deficitSampleCount = Int(try reader.read(5, field: "SHORT")) + 1
        guard deficitSampleCount == 32 else {
            throw DTSError.unsupported("DTS Core deficit sample count \(deficitSampleCount)")
        }
        let crcPresent = try reader.read(1, field: "CPF") == 1
        let pcmBlockCount = Int(try reader.read(7, field: "NBLKS")) + 1
        guard pcmBlockCount.isMultiple(of: 8) else {
            throw DTSError.malformed("DTS Core PCM block count is not a multiple of eight")
        }
        let frameByteCount = Int(try reader.read(14, field: "FSIZE")) + 1
        guard frameByteCount >= 96, frameByteCount <= data.count else {
            throw DTSError.truncated(field: "DTS Core frame", bitOffset: data.count * 8)
        }
        let audioMode = Int(try reader.read(6, field: "AMODE"))
        guard channelCounts.indices.contains(audioMode) else {
            throw DTSError.unsupported("DTS Core audio mode \(audioMode)")
        }
        let primaryChannelCount = channelCounts[audioMode]
        let sampleRateCode = Int(try reader.read(4, field: "SFREQ"))
        guard sampleRates.indices.contains(sampleRateCode), sampleRates[sampleRateCode] != 0 else {
            throw DTSError.malformed("DTS Core sample-rate code \(sampleRateCode)")
        }
        let bitrateCode = Int(try reader.read(5, field: "RATE"))
        guard bitrates.indices.contains(bitrateCode) else {
            throw DTSError.malformed("DTS Core bitrate code \(bitrateCode)")
        }
        guard try reader.read(1, field: "reserved") == 0 else {
            throw DTSError.malformed("DTS Core reserved header bit is set")
        }
        let dynamicRangePresent = try reader.read(1, field: "DYNF") == 1
        let timestampPresent = try reader.read(1, field: "TIMEF") == 1
        let auxiliaryDataPresent = try reader.read(1, field: "AUXF") == 1
        let hdcdMaster = try reader.read(1, field: "HDCD") == 1
        let extensionAudioType = Int(try reader.read(3, field: "EXT_AUDIO_ID"))
        let extensionAudioPresent = try reader.read(1, field: "EXT_AUDIO") == 1
        let syncSubSubframes = try reader.read(1, field: "ASPF") == 1
        let lfeCode = Int(try reader.read(2, field: "LFF"))
        guard lfeCode != 3 else { throw DTSError.malformed("DTS Core LFE code is invalid") }
        let predictorHistory = try reader.read(1, field: "HFLAG") == 1
        let headerCRC = crcPresent ? UInt16(try reader.read(16, field: "header CRC")) : nil
        let perfectFilter = try reader.read(1, field: "FILTS") == 1
        let encoderRevision = Int(try reader.read(4, field: "VERNUM"))
        let copyHistory = Int(try reader.read(2, field: "CHIST"))
        let sourcePCMResolutionCode = Int(try reader.read(3, field: "PCMR"))
        guard sourcePCMBitDepths.indices.contains(sourcePCMResolutionCode),
              sourcePCMBitDepths[sourcePCMResolutionCode] != 0 else {
            throw DTSError.malformed("DTS Core PCM resolution code \(sourcePCMResolutionCode)")
        }
        let sumDifferenceFront = try reader.read(1, field: "SUMF") == 1
        let sumDifferenceSurround = try reader.read(1, field: "SUMS") == 1
        let dialogNormalizationCode = Int(try reader.read(4, field: "DIALNORM"))

        let coding = try parsePrimaryAudioCodingHeader(
            reader: &reader,
            expectedChannelCount: primaryChannelCount,
            crcPresent: crcPresent
        )
        let subframes = try parseSubframes(
            reader: &reader,
            coding: coding,
            pcmBlockCount: pcmBlockCount,
            lfeCode: lfeCode,
            syncSubSubframes: syncSubSubframes,
            dynamicRangePresent: dynamicRangePresent,
            crcPresent: crcPresent
        )
        return DTSCoreFrameSyntax(
            bitstreamHeader: DTSCoreBitstreamHeader(
                normalFrame: normalFrame,
                deficitSampleCount: deficitSampleCount,
                crcPresent: crcPresent,
                pcmBlockCount: pcmBlockCount,
                frameByteCount: frameByteCount,
                audioMode: audioMode,
                primaryChannelCount: primaryChannelCount,
                sampleRateCode: sampleRateCode,
                sampleRate: sampleRates[sampleRateCode],
                bitrateCode: bitrateCode,
                bitrate: bitrates[bitrateCode],
                dynamicRangePresent: dynamicRangePresent,
                timestampPresent: timestampPresent,
                auxiliaryDataPresent: auxiliaryDataPresent,
                hdcdMaster: hdcdMaster,
                extensionAudioType: extensionAudioType,
                extensionAudioPresent: extensionAudioPresent,
                syncSubSubframes: syncSubSubframes,
                lfeCode: lfeCode,
                predictorHistory: predictorHistory,
                headerCRC: headerCRC,
                perfectFilter: perfectFilter,
                encoderRevision: encoderRevision,
                copyHistory: copyHistory,
                sourcePCMResolutionCode: sourcePCMResolutionCode,
                sourcePCMBitDepth: sourcePCMBitDepths[sourcePCMResolutionCode],
                extendedSurround: sourcePCMResolutionCode & 1 == 1,
                sumDifferenceFront: sumDifferenceFront,
                sumDifferenceSurround: sumDifferenceSurround,
                dialogNormalizationCode: dialogNormalizationCode
            ),
            primaryAudioHeader: coding,
            subframes: subframes,
            primaryAudioDataEndBitOffset: reader.bitOffset
        )
    }

    private static func parsePrimaryAudioCodingHeader(
        reader: inout BitReader,
        expectedChannelCount: Int,
        crcPresent: Bool
    ) throws -> DTSCorePrimaryAudioCodingHeader {
        let subframeCount = Int(try reader.read(4, field: "SUBFRAMES")) + 1
        let primaryChannelCount = Int(try reader.read(3, field: "PCHS")) + 1
        guard primaryChannelCount == expectedChannelCount else {
            throw DTSError.malformed(
                "DTS Core primary channel count \(primaryChannelCount) disagrees with AMODE \(expectedChannelCount)"
            )
        }
        var subbandActivityCounts: [Int] = []
        var highFrequencyVQStartSubbands: [Int] = []
        var jointIntensityIndices: [Int] = []
        var transitionModeSelectors: [Int] = []
        var scaleFactorSelectors: [Int] = []
        var bitAllocationSelectors: [Int] = []
        for channel in 0..<primaryChannelCount {
            let count = Int(try reader.read(5, field: "SUBBAND_ACTIVITY[\(channel)]")) + 2
            guard count <= 32 else { throw DTSError.malformed("DTS Core subband activity exceeds 32") }
            subbandActivityCounts.append(count)
        }
        for channel in 0..<primaryChannelCount {
            highFrequencyVQStartSubbands.append(
                Int(try reader.read(5, field: "VQ_START[\(channel)]")) + 1
            )
        }
        for channel in 0..<primaryChannelCount {
            let index = Int(try reader.read(3, field: "JOINT_INTENSITY[\(channel)]"))
            guard index <= primaryChannelCount else {
                throw DTSError.malformed("DTS Core joint-intensity channel index is invalid")
            }
            jointIntensityIndices.append(index)
        }
        for channel in 0..<primaryChannelCount {
            transitionModeSelectors.append(Int(try reader.read(2, field: "TRANSIENT_SEL[\(channel)]")))
        }
        for channel in 0..<primaryChannelCount {
            let selector = Int(try reader.read(3, field: "SCALE_SEL[\(channel)]"))
            guard selector != 7 else { throw DTSError.malformed("DTS Core scale-factor selector 7 is invalid") }
            scaleFactorSelectors.append(selector)
        }
        for channel in 0..<primaryChannelCount {
            let selector = Int(try reader.read(3, field: "BITALLOC_SEL[\(channel)]"))
            guard selector != 7 else { throw DTSError.malformed("DTS Core bit-allocation selector 7 is invalid") }
            bitAllocationSelectors.append(selector)
        }

        var quantizationIndexSelectors = Array(
            repeating: Array(repeating: 0, count: quantizationSelectorBitCounts.count),
            count: primaryChannelCount
        )
        for codebook in quantizationSelectorBitCounts.indices {
            for channel in 0..<primaryChannelCount {
                quantizationIndexSelectors[channel][codebook] = Int(try reader.read(
                    quantizationSelectorBitCounts[codebook],
                    field: "QUANT_INDEX_SEL[\(channel)][\(codebook)]"
                ))
            }
        }
        var scaleFactorAdjustmentCodes = Array(
            repeating: Array<Int?>(repeating: nil, count: quantizationSelectorBitCounts.count),
            count: primaryChannelCount
        )
        for codebook in quantizationSelectorBitCounts.indices {
            for channel in 0..<primaryChannelCount
            where quantizationIndexSelectors[channel][codebook] < quantizationSelectorGroupSizes[codebook] {
                scaleFactorAdjustmentCodes[channel][codebook] = Int(try reader.read(
                    2,
                    field: "SCALE_ADJ[\(channel)][\(codebook)]"
                ))
            }
        }
        let audioHeaderCRC = crcPresent ? UInt16(try reader.read(16, field: "audio header CRC")) : nil
        return DTSCorePrimaryAudioCodingHeader(
            subframeCount: subframeCount,
            primaryChannelCount: primaryChannelCount,
            subbandActivityCounts: subbandActivityCounts,
            highFrequencyVQStartSubbands: highFrequencyVQStartSubbands,
            jointIntensityIndices: jointIntensityIndices,
            transitionModeSelectors: transitionModeSelectors,
            scaleFactorSelectors: scaleFactorSelectors,
            bitAllocationSelectors: bitAllocationSelectors,
            quantizationIndexSelectors: quantizationIndexSelectors,
            scaleFactorAdjustmentCodes: scaleFactorAdjustmentCodes,
            audioHeaderCRC: audioHeaderCRC,
            endBitOffset: reader.bitOffset
        )
    }

    private static func parseSubframes(
        reader: inout BitReader,
        coding: DTSCorePrimaryAudioCodingHeader,
        pcmBlockCount: Int,
        lfeCode: Int,
        syncSubSubframes: Bool,
        dynamicRangePresent: Bool,
        crcPresent: Bool
    ) throws -> [DTSCoreSubframeSyntax] {
        var output: [DTSCoreSubframeSyntax] = []
        output.reserveCapacity(coding.subframeCount)
        var parsedPCMBlocks = 0
        for subframe in 0..<coding.subframeCount {
            let subSubframeCount = Int(try reader.read(2, field: "SUBSUBFRAMES[\(subframe)]")) + 1
            let partialSampleCountCode = Int(try reader.read(3, field: "PARTIAL_SAMPLES[\(subframe)]"))
            let subframePCMBlocks = subSubframeCount * 8
            guard parsedPCMBlocks + subframePCMBlocks <= pcmBlockCount else {
                throw DTSError.malformed("DTS Core subframe sample count exceeds frame PCM blocks")
            }

            var predictionModes = Array(
                repeating: [Bool](),
                count: coding.primaryChannelCount
            )
            var predictionVQIndices = Array(
                repeating: [Int?](),
                count: coding.primaryChannelCount
            )
            for channel in 0..<coding.primaryChannelCount {
                let count = coding.subbandActivityCounts[channel]
                predictionModes[channel].reserveCapacity(count)
                predictionVQIndices[channel].reserveCapacity(count)
                for band in 0..<count {
                    let predicted = try reader.read(
                        1,
                        field: "PRED[\(subframe)][\(channel)][\(band)]"
                    ) == 1
                    predictionModes[channel].append(predicted)
                    predictionVQIndices[channel].append(nil)
                }
            }
            for channel in 0..<coding.primaryChannelCount {
                for band in predictionModes[channel].indices where predictionModes[channel][band] {
                    predictionVQIndices[channel][band] = Int(try reader.read(
                        12,
                        field: "PRED_VQ[\(subframe)][\(channel)][\(band)]"
                    ))
                }
            }

            var bitAllocations = Array(
                repeating: [Int](),
                count: coding.primaryChannelCount
            )
            for channel in 0..<coding.primaryChannelCount {
                let selector = coding.bitAllocationSelectors[channel]
                guard selector >= 5 else {
                    throw DTSError.unsupported(
                        "DTS Core Huffman bit-allocation selector \(selector)"
                    )
                }
                let count = coding.highFrequencyVQStartSubbands[channel]
                bitAllocations[channel].reserveCapacity(count)
                for band in 0..<count {
                    let allocation = Int(try reader.read(
                        selector - 1,
                        field: "ABITS[\(subframe)][\(channel)][\(band)]"
                    ))
                    guard allocation <= 26 else {
                        throw DTSError.malformed("DTS Core bit-allocation index exceeds 26")
                    }
                    bitAllocations[channel].append(allocation)
                }
            }

            var transitionModes = bitAllocations.map {
                Array(repeating: 0, count: $0.count)
            }
            if subSubframeCount > 1 {
                for channel in 0..<coding.primaryChannelCount {
                    let selector = coding.transitionModeSelectors[channel]
                    for band in bitAllocations[channel].indices where bitAllocations[channel][band] != 0 {
                        transitionModes[channel][band] = try readTransitionMode(
                            reader: &reader,
                            selector: selector,
                            field: "TRANSITION[\(subframe)][\(channel)][\(band)]"
                        )
                    }
                }
            }

            var scaleFactorIndices = Array(
                repeating: [[Int]](),
                count: coding.primaryChannelCount
            )
            for channel in 0..<coding.primaryChannelCount {
                let selector = coding.scaleFactorSelectors[channel]
                guard selector >= 5 else {
                    throw DTSError.unsupported("DTS Core Huffman scale-factor selector \(selector)")
                }
                let codedBandCount = max(
                    coding.highFrequencyVQStartSubbands[channel],
                    coding.subbandActivityCounts[channel]
                )
                scaleFactorIndices[channel] = Array(repeating: [], count: codedBandCount)
                for band in 0..<coding.highFrequencyVQStartSubbands[channel]
                where bitAllocations[channel][band] != 0 {
                    scaleFactorIndices[channel][band].append(Int(try reader.read(
                        selector + 1,
                        field: "SCALE[\(subframe)][\(channel)][\(band)][0]"
                    )))
                    if transitionModes[channel][band] != 0 {
                        scaleFactorIndices[channel][band].append(Int(try reader.read(
                            selector + 1,
                            field: "SCALE[\(subframe)][\(channel)][\(band)][1]"
                        )))
                    }
                }
                if coding.highFrequencyVQStartSubbands[channel] < coding.subbandActivityCounts[channel] {
                    let vqStart = coding.highFrequencyVQStartSubbands[channel]
                    let vqEnd = coding.subbandActivityCounts[channel]
                    for band in vqStart..<vqEnd {
                        scaleFactorIndices[channel][band].append(Int(try reader.read(
                            selector + 1,
                            field: "VQ_SCALE[\(subframe)][\(channel)][\(band)]"
                        )))
                    }
                }
            }

            for channel in 0..<coding.primaryChannelCount
            where coding.jointIntensityIndices[channel] != 0 {
                throw DTSError.unsupported("DTS Core joint-intensity side information")
            }
            if dynamicRangePresent { try reader.skip(8, field: "dynamic range coefficient") }
            if crcPresent { try reader.skip(16, field: "side information CRC") }
            let sideInformationEndBitOffset = reader.bitOffset

            var highFrequencyVQIndices = Array(
                repeating: [Int](),
                count: coding.primaryChannelCount
            )
            for channel in 0..<coding.primaryChannelCount {
                let start = coding.highFrequencyVQStartSubbands[channel]
                let end = coding.subbandActivityCounts[channel]
                if start < end {
                    highFrequencyVQIndices[channel].reserveCapacity(end - start)
                    for band in start..<end {
                        highFrequencyVQIndices[channel].append(Int(try reader.read(
                            10,
                            field: "HF_VQ[\(subframe)][\(channel)][\(band)]"
                        )))
                    }
                }
            }

            var lfeSamples: [Int32] = []
            var lfeScaleFactorIndex: Int?
            if lfeCode != 0 {
                let count = 2 * lfeCode * subSubframeCount
                lfeSamples.reserveCapacity(count)
                for sample in 0..<count {
                    lfeSamples.append(try readSigned(
                        reader: &reader,
                        width: 8,
                        field: "LFE[\(subframe)][\(sample)]"
                    ))
                }
                let scale = Int(try reader.read(8, field: "LFE_SCALE[\(subframe)]"))
                guard scale < 128 else { throw DTSError.malformed("DTS Core LFE scale index exceeds 127") }
                lfeScaleFactorIndex = scale
            }

            var dsyncCount = 0
            var quantizedSubbandSamples = Array(
                repeating: [[Int32]](),
                count: coding.primaryChannelCount
            )
            for channel in 0..<coding.primaryChannelCount {
                quantizedSubbandSamples[channel] = Array(
                    repeating: [],
                    count: coding.highFrequencyVQStartSubbands[channel]
                )
            }
            for subSubframe in 0..<subSubframeCount {
                for channel in 0..<coding.primaryChannelCount {
                    for band in bitAllocations[channel].indices {
                        quantizedSubbandSamples[channel][band].append(contentsOf: try readAudioCodewords(
                            reader: &reader,
                            allocation: bitAllocations[channel][band],
                            quantizationSelector: coding.quantizationIndexSelectors[channel],
                            field: "AUDIO[\(subframe)][\(subSubframe)][\(channel)][\(band)]"
                        ))
                    }
                }
                if subSubframe == subSubframeCount - 1 || syncSubSubframes {
                    guard try reader.read(16, field: "DSYNC[\(subframe)][\(subSubframe)]") == 0xffff else {
                        throw DTSError.malformed("DTS Core DSYNC check failed")
                    }
                    dsyncCount += 1
                }
            }
            parsedPCMBlocks += subframePCMBlocks
            output.append(DTSCoreSubframeSyntax(
                index: subframe,
                subSubframeCount: subSubframeCount,
                partialSampleCountCode: partialSampleCountCode,
                predictionModes: predictionModes,
                predictionVQIndices: predictionVQIndices,
                bitAllocations: bitAllocations,
                transitionModes: transitionModes,
                scaleFactorIndices: scaleFactorIndices,
                highFrequencyVQIndices: highFrequencyVQIndices,
                lfeSamples: lfeSamples,
                lfeScaleFactorIndex: lfeScaleFactorIndex,
                quantizedSubbandSamples: quantizedSubbandSamples,
                sideInformationEndBitOffset: sideInformationEndBitOffset,
                audioDataEndBitOffset: reader.bitOffset,
                dsyncCount: dsyncCount
            ))
        }
        guard parsedPCMBlocks == pcmBlockCount else {
            throw DTSError.malformed(
                "DTS Core subframes contain \(parsedPCMBlocks) PCM blocks, expected \(pcmBlockCount)"
            )
        }
        return output
    }

    private static func readTransitionMode(
        reader: inout BitReader,
        selector: Int,
        field: String
    ) throws -> Int {
        switch selector {
        case 0:
            if try reader.read(1, field: field) == 0 { return 0 }
            if try reader.read(1, field: field) == 0 { return 1 }
            return try reader.read(1, field: field) == 0 ? 2 : 3
        case 1:
            if try reader.read(1, field: field) == 0 { return 3 }
            if try reader.read(1, field: field) == 0 { return 0 }
            return try reader.read(1, field: field) == 0 ? 1 : 2
        case 2:
            if try reader.read(1, field: field) == 0 { return 2 }
            if try reader.read(1, field: field) == 0 { return 3 }
            return try reader.read(1, field: field) == 0 ? 0 : 1
        case 3:
            return Int(try reader.read(2, field: field))
        default:
            throw DTSError.malformed("DTS Core transition selector is invalid")
        }
    }

    private static func readAudioCodewords(
        reader: inout BitReader,
        allocation: Int,
        quantizationSelector: [Int],
        field: String
    ) throws -> [Int32] {
        guard allocation >= 0, allocation <= 26 else {
            throw DTSError.malformed("DTS Core bit-allocation index is invalid")
        }
        if allocation == 0 { return Array(repeating: 0, count: 8) }
        if allocation <= quantizationSelectorBitCounts.count {
            let codebook = allocation - 1
            if quantizationSelector[codebook] < quantizationSelectorGroupSizes[codebook] {
                throw DTSError.unsupported("DTS Core Huffman quantization codewords")
            }
            if allocation <= blockCodeBitCounts.count {
                let width = blockCodeBitCounts[codebook]
                let first = Int(try reader.read(width, field: field))
                let second = Int(try reader.read(width, field: field))
                let levels = Int(DTSCoreDecodeTables.quantLevels[allocation])
                var output: [Int32] = []
                output.reserveCapacity(8)
                var codes = [first, second]
                let offset = (levels - 1) / 2
                for half in 0..<2 {
                    for _ in 0..<4 {
                        let quotient = codes[half] / levels
                        output.append(Int32(codes[half] - quotient * levels - offset))
                        codes[half] = quotient
                    }
                }
                guard codes[0] == 0, codes[1] == 0 else {
                    throw DTSError.malformed("DTS Core block code exceeds quantizer levels")
                }
                return output
            }
        }
        let width = allocation - 3
        return try (0..<8).map { sample in
            try readSigned(reader: &reader, width: width, field: "\(field)[\(sample)]")
        }
    }

    private static func readSigned(
        reader: inout BitReader,
        width: Int,
        field: String
    ) throws -> Int32 {
        let raw = try reader.read(width, field: field)
        let signBit = UInt64(1) << UInt64(width - 1)
        return raw & signBit == 0
            ? Int32(raw)
            : Int32(Int64(raw) - (Int64(1) << Int64(width)))
    }

    private static let blockCodeBitCounts = [7, 10, 12, 13, 15, 17, 19]
}
