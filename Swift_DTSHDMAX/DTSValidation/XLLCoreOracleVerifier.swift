import Foundation

public struct XLLCoreOracleVerificationReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let coreOraclePCMPath: String
    public let sourceDirectory: String
    public let streamSHA256: String
    public let xllFrameCount: Int
    public let coreSampleCount: Int
    public let sourceSampleCount: Int
    public let leadingPrimingSampleCount: Int
    public let comparisons: [XLLChannelPCMComparison]
    public let isBitExactWithZeroPadding: Bool
}

/// Development-only differential check for the native XLL residual path.
/// The Core PCM is supplied as an oracle file; no external decoder is linked
/// or called by the project. Once DTSCoreDecoder is complete, its PCM replaces
/// this argument without changing the residual-combination algorithm.
public enum XLLCoreOracleVerifier {
    private static let coreWaveToPrimaryOrder = [2, 0, 1, 3, 4, 5]
    private static let primaryAndSecondaryToSourceOrder = [1, 2, 0, 3, 6, 7, 4, 5]

    public static func verify(
        inputURL: URL,
        coreOraclePCMURL: URL,
        sourceDirectory: URL
    ) throws -> XLLCoreOracleVerificationReport {
        let input = inputURL.standardizedFileURL
        let coreURL = coreOraclePCMURL.standardizedFileURL
        let core = try WaveFile.readIntegerPCM(from: coreURL)
        guard core.sampleRate == 48_000,
              (core.validBits == 24 || core.validBits == 32),
              core.layout == .fiveOneSide else {
            throw DTSError.invalidArgument("Core oracle PCM must be 48 kHz integer 5.1(side)")
        }
        return try verifyReconstruction(
            inputURL: input,
            corePCMSource: coreURL.path,
            corePlanes: core.planes,
            coreSampleCount: core.sampleCount,
            sourceDirectory: sourceDirectory
        )
    }

    public static func verifyDTSXCompatibilityBed(
        inputURL: URL,
        coreOraclePCMURL: URL,
        sourceDirectory: URL,
        maximumSourceFrameCount: Int? = nil
    ) throws -> XLLCoreOracleVerificationReport {
        let coreURL = coreOraclePCMURL.standardizedFileURL
        let core = try WaveFile.readIntegerPCM(from: coreURL)
        guard core.sampleRate == 48_000,
              (core.validBits == 24 || core.validBits == 32),
              core.layout == .fiveOneSide else {
            throw DTSError.invalidArgument("Core oracle PCM must be 48 kHz integer 5.1(side)")
        }
        let completeSource = try DTS714SourceSet.loadLegacySevenOne(directory: sourceDirectory)
        let source: PCMBuffer
        if let maximumSourceFrameCount {
            guard maximumSourceFrameCount > 0 else {
                throw DTSError.invalidArgument("SOURCE_FRAME_COUNT must be positive")
            }
            let (sampleCount, overflow) = maximumSourceFrameCount.multipliedReportingOverflow(
                by: XLLSyntax.frameSampleCount
            )
            guard !overflow, sampleCount <= completeSource.sampleCount else {
                throw DTSError.valueOutOfRange(
                    field: "DTS:X compatibility source frame count",
                    value: String(maximumSourceFrameCount)
                )
            }
            source = try completeSource.frame(at: 0, count: sampleCount)
        } else {
            source = completeSource
        }
        return try verifyReconstruction(
            inputURL: inputURL.standardizedFileURL,
            corePCMSource: coreURL.path,
            corePlanes: core.planes,
            coreSampleCount: core.sampleCount,
            source: source,
            sourceDirectory: sourceDirectory,
            maximumAlignedSourceSampleCount: maximumSourceFrameCount == nil
                ? nil
                : source.sampleCount
        )
    }

    static func verifyReconstruction(
        inputURL: URL,
        corePCMSource: String,
        corePlanes: [[Int32]],
        coreSampleCount: Int,
        sourceDirectory: URL
    ) throws -> XLLCoreOracleVerificationReport {
        let source = try HDMAReferenceSetVerifier.loadSource(directory: sourceDirectory)
        return try verifyReconstruction(
            inputURL: inputURL,
            corePCMSource: corePCMSource,
            corePlanes: corePlanes,
            coreSampleCount: coreSampleCount,
            source: source,
            sourceDirectory: sourceDirectory
        )
    }

    static func verifyReconstruction(
        inputURL: URL,
        corePCMSource: String,
        corePlanes: [[Int32]],
        coreSampleCount: Int,
        source: PCMBuffer,
        sourceDirectory: URL,
        maximumAlignedSourceSampleCount: Int? = nil
    ) throws -> XLLCoreOracleVerificationReport {
        let input = inputURL.standardizedFileURL
        guard source.format.sampleRate == 48_000,
              source.format.bitDepth == 24,
              source.format.layout == .sevenOne else {
            throw DTSError.invalidArgument("Core + XLL verification source must be 48 kHz/24-bit 7.1 PCM")
        }
        guard corePlanes.count == 6, corePlanes.allSatisfy({ $0.count == coreSampleCount }) else {
            throw DTSError.malformed("Core reconstruction PCM must contain six equal-length planes")
        }
        let stream = try XLLPBRStreamReader.read(inputURL: input)
        let frameSampleCounts = try stream.frames.map { frame in
            let ast = try XLLFrameASTParser.parse(frame.frame)
            return ast.segmentCount * ast.segmentSampleCount
        }
        let leadingTrim = stream.coreCompatiblePrimingSampleCount
            + stream.initialDecodingDelayFrames * XLLSyntax.frameSampleCount
        let selectedFrameCount: Int
        let totalXLLSamples: Int
        if let maximumAlignedSourceSampleCount {
            guard maximumAlignedSourceSampleCount == source.sampleCount else {
                throw DTSError.invalidArgument(
                    "maximum aligned source sample count must match the comparison source"
                )
            }
            let (targetSampleCount, overflow) = leadingTrim.addingReportingOverflow(
                maximumAlignedSourceSampleCount
            )
            guard !overflow else {
                throw DTSError.valueOutOfRange(
                    field: "Core + XLL verification sample prefix",
                    value: String(maximumAlignedSourceSampleCount)
                )
            }
            var accumulated = 0
            var count = 0
            while count < frameSampleCounts.count, accumulated < targetSampleCount {
                accumulated += frameSampleCounts[count]
                count += 1
            }
            guard accumulated == targetSampleCount else {
                throw DTSError.malformed(
                    "requested Core + XLL verification prefix is not XLL-frame aligned"
                )
            }
            selectedFrameCount = count
            totalXLLSamples = accumulated
        } else {
            selectedFrameCount = stream.frames.count
            totalXLLSamples = frameSampleCounts.reduce(0, +)
        }
        let selectedFrames = stream.frames.prefix(selectedFrameCount)
        guard coreSampleCount >= totalXLLSamples,
              maximumAlignedSourceSampleCount != nil || coreSampleCount == totalXLLSamples else {
            throw DTSError.invalidArgument(
                "Core PCM sample count \(coreSampleCount) differs from XLL timeline \(totalXLLSamples)"
            )
        }
        let decodedAlignedSampleCount = totalXLLSamples - leadingTrim
        guard decodedAlignedSampleCount >= source.sampleCount else {
            throw DTSError.truncated(field: "Core + XLL PCM", bitOffset: decodedAlignedSampleCount * 24)
        }

        var mismatches = Array(repeating: 0, count: 8)
        var firstMismatch: [Int?] = Array(repeating: nil, count: 8)
        var expectedAtFirst: [Int32?] = Array(repeating: nil, count: 8)
        var actualAtFirst: [Int32?] = Array(repeating: nil, count: 8)
        var nonzeroTail = Array(repeating: 0, count: 8)
        var globalSample = 0

        for frame in selectedFrames {
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            guard decoded.channelSets.count == 2,
                  decoded.channelSets[0].planes.count == 6,
                  decoded.channelSets[1].planes.count == 2 else {
                throw DTSError.unsupported("Core oracle verifier requires the official 6+2 XLL hierarchy")
            }
            let primary = decoded.channelSets[0]
            let secondary = decoded.channelSets[1]
            let scaleCodes = secondary.downmixEmbedded ? secondary.downmixScaleCodes : []
            let coefficientCodes = secondary.downmixEmbedded ? secondary.downmixCoefficientCodes : []
            guard scaleCodes.isEmpty || scaleCodes.count >= 6 else {
                throw DTSError.malformed("XLL hierarchical downmix scale matrix is incomplete")
            }
            guard coefficientCodes.isEmpty || coefficientCodes.count >= 12 else {
                throw DTSError.malformed("XLL hierarchical downmix coefficient matrix is incomplete")
            }
            let inverseScales = try scaleCodes.map(XLLSyntax.inverseDownmixScaleQ16)
            var undoCoefficients = Array(repeating: Int32(0), count: 12)
            if !coefficientCodes.isEmpty {
                for primaryChannel in 0..<6 {
                    for secondaryChannel in 0..<2 {
                        let index = primaryChannel * 2 + secondaryChannel
                        undoCoefficients[index] = try XLLSyntax.undoDownmixCoefficientQ15(
                            scaleCode: scaleCodes[primaryChannel],
                            coefficientCode: coefficientCodes[index]
                        )
                    }
                }
            }

            for sample in 0..<decoded.sampleCount {
                var hierarchical = Array(repeating: Int32(0), count: 8)
                for channel in 0..<6 {
                    let xll = primary.planes[channel][sample]
                    if primary.residualChannelMask & (UInt64(1) << UInt64(channel)) != 0 {
                        hierarchical[channel] = xll
                    } else {
                        let coreValue = corePlanes[Self.coreWaveToPrimaryOrder[channel]][globalSample]
                        let scaledCore: Int64
                        if inverseScales.isEmpty {
                            scaledCore = Int64(coreValue)
                        } else {
                            scaledCore = multiplyQ16(coreValue, inverseScales[channel])
                        }
                        // XLL combines a reduced-width Core sample with the
                        // decoded MSBs, then assembles the scalable LSBs. Adding
                        // a full-width Core sample to an already assembled XLL
                        // residual is not equivalent when the Core value is
                        // rounded at the MSB boundary (the official surround
                        // channel uses one scalable LSB in some frames).
                        let assemblyShift = try effectiveLSBWidth(
                            channelSet: primary,
                            channel: channel,
                            fixedLSBWidth: decoded.fixedLSBWidth
                        )
                        let coreShift = primary.storageBitDepth - primary.pcmBitDepth + assemblyShift
                        guard coreShift >= 0, coreShift <= primary.storageBitDepth else {
                            throw DTSError.malformed("XLL Core residual shift is outside storage precision")
                        }
                        let rounding = coreShift > 0 ? Int64(1) << Int64(coreShift - 1) : 0
                        let reducedCore = clip24((scaledCore + rounding) >> coreShift)
                        let assembledCore = Int32(
                            truncatingIfNeeded: Int64(reducedCore) << Int64(assemblyShift)
                        )
                        hierarchical[channel] = xll &+ assembledCore
                    }
                }
                hierarchical[6] = secondary.planes[0][sample]
                hierarchical[7] = secondary.planes[1][sample]
                if !coefficientCodes.isEmpty {
                    for primaryChannel in 0..<6 {
                        for secondaryChannel in 0..<2 {
                            let coefficient = undoCoefficients[primaryChannel * 2 + secondaryChannel]
                            if coefficient != 0 {
                                hierarchical[primaryChannel] = hierarchical[primaryChannel] &- multiplyQ15(
                                    hierarchical[6 + secondaryChannel],
                                    coefficient
                                )
                            }
                        }
                    }
                }

                let alignedSample = globalSample - leadingTrim
                if alignedSample >= 0 {
                    let sourceOrdered = Self.primaryAndSecondaryToSourceOrder.map { hierarchical[$0] }
                    if alignedSample < source.sampleCount {
                        for channel in 0..<8 where source.planes[channel][alignedSample] != sourceOrdered[channel] {
                            mismatches[channel] += 1
                            if firstMismatch[channel] == nil {
                                firstMismatch[channel] = alignedSample
                                expectedAtFirst[channel] = source.planes[channel][alignedSample]
                                actualAtFirst[channel] = sourceOrdered[channel]
                            }
                        }
                    } else {
                        for channel in 0..<8 where sourceOrdered[channel] != 0 {
                            nonzeroTail[channel] += 1
                        }
                    }
                }
                globalSample += 1
            }
        }

        let comparisons = (0..<8).map { channel in
            XLLChannelPCMComparison(
                channel: channel,
                expectedSampleCount: source.sampleCount,
                decodedSampleCount: decodedAlignedSampleCount,
                mismatchCount: mismatches[channel],
                firstMismatchSample: firstMismatch[channel],
                expectedAtFirstMismatch: expectedAtFirst[channel],
                actualAtFirstMismatch: actualAtFirst[channel],
                nonzeroTailSampleCount: nonzeroTail[channel]
            )
        }
        return XLLCoreOracleVerificationReport(
            inputPath: input.path,
            coreOraclePCMPath: corePCMSource,
            sourceDirectory: sourceDirectory.standardizedFileURL.path,
            streamSHA256: try SHA256Hasher.hash(fileAt: input),
            xllFrameCount: selectedFrameCount,
            coreSampleCount: totalXLLSamples,
            sourceSampleCount: source.sampleCount,
            leadingPrimingSampleCount: leadingTrim,
            comparisons: comparisons,
            isBitExactWithZeroPadding: comparisons.allSatisfy(\.isBitExactWithZeroPadding)
        )
    }

    private static func multiplyQ16(_ first: Int32, _ second: Int32) -> Int64 {
        (Int64(first) * Int64(second) + 32_768) >> 16
    }

    private static func effectiveLSBWidth(
        channelSet: XLLDecodedChannelSet,
        channel: Int,
        fixedLSBWidth: Int
    ) throws -> Int {
        guard channelSet.scalableLSBWidths.indices.contains(channel),
              channelSet.bitWidthAdjustments.indices.contains(channel) else {
            throw DTSError.malformed("XLL scalable-LSB channel metadata is incomplete")
        }
        if fixedLSBWidth > 0 { return fixedLSBWidth }
        let scalable = channelSet.scalableLSBWidths[channel]
        let adjustment = channelSet.bitWidthAdjustments[channel]
        return scalable > 0 && adjustment > 0
            ? scalable + adjustment - 1
            : scalable + adjustment
    }

    private static func multiplyQ15(_ first: Int32, _ second: Int32) -> Int32 {
        Int32(truncatingIfNeeded: (Int64(first) * Int64(second) + 16_384) >> 15)
    }

    private static func clip24(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }
}
