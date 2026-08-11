import Foundation

public struct XLLDecodedChannelSetInspection: Sendable, Equatable, Codable {
    public let index: Int
    public let speakerMask: UInt64
    public let residualChannelMask: UInt64
    public let pcmBitDepth: Int
    public let storageBitDepth: Int
    public let downmixCoefficientsPresent: Bool
    public let downmixEmbedded: Bool
    public let downmixScaleCodes: [Int]
    public let downmixCoefficientCodes: [Int]
    public let decorrelationEnabled: Bool
    public let originalOrder: [Int]
    public let decorrelationCoefficients: [Int32]
    public let adaptivePredictionOrders: [Int]
    public let fixedPredictionOrders: [Int]
    public let scalableLSBWidths: [Int]
    public let bitWidthAdjustments: [Int]
    public let samplePrefixes: [[Int32]]
}

public struct XLLFrameDecodeInspection: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let frameByteCount: Int
    public let commonHeaderByteCount: Int
    public let frameSizeBitCount: Int
    public let sampleCount: Int
    public let segmentCount: Int
    public let segmentSampleCount: Int
    public let segmentSizeBitCount: Int
    public let segmentByteCounts: [Int]
    public let fixedLSBWidth: Int
    public let entropyStateReuseSegmentCount: Int
    public let entropyCommonParameterSegmentCount: Int
    public let entropyRiceParameterCount: Int
    public let hybridRiceParameterCount: Int
    public let hybridIsolatedSampleCount: Int
    public let channelSets: [XLLDecodedChannelSetInspection]
}

public enum XLLFrameDecodeInspector {
    public static func inspect(inputURL: URL, frameIndex: Int) throws -> XLLFrameDecodeInspection {
        guard frameIndex >= 0 else { throw DTSError.invalidArgument("XLL frame index must be non-negative") }
        let stream = try XLLPBRStreamReader.read(inputURL: inputURL)
        guard frameIndex < stream.frames.count else {
            throw DTSError.valueOutOfRange(field: "XLL frame index", value: String(frameIndex))
        }
        let decoded = try XLLDecoder().decodeChannelSets(frame: stream.frames[frameIndex].frame)
        let ast = try XLLFrameASTParser.parse(stream.frames[frameIndex].frame)
        return XLLFrameDecodeInspection(
            frameIndex: frameIndex,
            frameByteCount: decoded.frameByteCount,
            commonHeaderByteCount: ast.commonHeaderByteCount,
            frameSizeBitCount: ast.frameSizeBitCount,
            sampleCount: decoded.sampleCount,
            segmentCount: ast.segmentCount,
            segmentSampleCount: ast.segmentSampleCount,
            segmentSizeBitCount: ast.segmentSizeBitCount,
            segmentByteCounts: ast.naviSegmentByteCounts,
            fixedLSBWidth: decoded.fixedLSBWidth,
            entropyStateReuseSegmentCount: decoded.entropyStateReuseSegmentCount,
            entropyCommonParameterSegmentCount: decoded.entropyCommonParameterSegmentCount,
            entropyRiceParameterCount: decoded.entropyRiceParameterCount,
            hybridRiceParameterCount: decoded.hybridRiceParameterCount,
            hybridIsolatedSampleCount: decoded.hybridIsolatedSampleCount,
            channelSets: decoded.channelSets.map {
                XLLDecodedChannelSetInspection(
                    index: $0.index,
                    speakerMask: $0.speakerMask,
                    residualChannelMask: $0.residualChannelMask,
                    pcmBitDepth: $0.pcmBitDepth,
                    storageBitDepth: $0.storageBitDepth,
                    downmixCoefficientsPresent: $0.downmixCoefficientsPresent,
                    downmixEmbedded: $0.downmixEmbedded,
                    downmixScaleCodes: $0.downmixScaleCodes,
                    downmixCoefficientCodes: $0.downmixCoefficientCodes,
                    decorrelationEnabled: $0.decorrelationEnabled,
                    originalOrder: $0.originalOrder,
                    decorrelationCoefficients: $0.decorrelationCoefficients,
                    adaptivePredictionOrders: $0.adaptivePredictionOrders,
                    fixedPredictionOrders: $0.fixedPredictionOrders,
                    scalableLSBWidths: $0.scalableLSBWidths,
                    bitWidthAdjustments: $0.bitWidthAdjustments,
                    samplePrefixes: $0.planes.map { Array($0.prefix(512)) }
                )
            }
        )
    }
}

public struct DTSXTerminalChannelSetInspection: Sendable, Equatable, Codable {
    public let index: Int
    public let channelCount: Int
    public let speakerMask: UInt64?
    public let residualChannelMask: UInt64
    public let isPrimary: Bool
    public let hierarchical: Bool
    public let hasEmbeddedDownmix: Bool
}

public struct DTSXTerminalPrivateFrameInspection: Sendable, Equatable, Codable {
    public let byteCount: Int
    public let headerCRCIsValid: Bool
    public let primarySixBitCode: UInt8
    public let routingPermutation: [Int]
    public let routingBranchCode: Int
    public let predictionCRCIsValid: Bool
    public let navigationCRCIsValid: Bool?
    public let navigationSegmentByteCounts: [Int]?
}

public struct DTSXTerminalAccessUnitInspection: Sendable, Equatable, Codable {
    public let accessUnitIndex: Int
    public let coreByteCount: Int?
    public let exssByteCount: Int
    public let exssHeaderByteCount: Int
    public let assetDescriptorByteCount: Int
    public let xllByteCount: Int
    public let peakBitRateSmoothingBufferSizeCode: Int
    public let xllInitialDecodingDelayBitCount: Int
    public let xllInitialDecodingDelayFrames: Int
    public let xllSyncByteOffset: Int
    public let xllCommonHeaderByteCount: Int
    public let xllSegmentCount: Int
    public let xllSegmentSampleCount: Int
    public let xllPrivateDataByteOffset: Int
    public let xllPrivateDataByteCount: Int
    public let descriptorXLLXByteOffset: Int?
    public let descriptorXLLXByteCount: Int?
    public let channelSets: [DTSXTerminalChannelSetInspection]
    public let privateFrame: DTSXTerminalPrivateFrameInspection?
}

public struct DTSXTerminalFrameInspection: Sendable, Equatable, Codable {
    public let inputPath: String
    public let accessUnits: [DTSXTerminalAccessUnitInspection]
}

/// Reports the terminal-facing ExSS/XLL/XLL-X boundary without treating the
/// local XLL-X PCM decoder as an external interoperability oracle.
public enum DTSXTerminalFrameInspector {
    public static func inspect(
        inputURL: URL,
        accessUnitCount: Int
    ) throws -> DTSXTerminalFrameInspection {
        guard accessUnitCount > 0 else {
            throw DTSError.invalidArgument("DTS:X access-unit count must be positive")
        }
        let input = inputURL.standardizedFileURL
        let accessUnits = try DTSStreamInspector().inspect(
            url: input,
            maximumAccessUnits: accessUnitCount
        )
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: input)
        } catch {
            throw DTSError.io("cannot open \(input.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        return DTSXTerminalFrameInspection(
            inputPath: input.path,
            accessUnits: try accessUnits.map { accessUnit in
                let coreByteCount = accessUnit.coreByteCount.map { ($0 + 3) & ~3 } ?? 0
                let exssOffset = accessUnit.byteOffset + UInt64(coreByteCount)
                guard let exssByteCount = accessUnit.exssByteCount else {
                    throw DTSError.malformed("DTS:X access unit has no ExSS component")
                }
                let exssData = try readExactly(
                    handle: handle,
                    offset: exssOffset,
                    count: exssByteCount
                )
                let exss = try ExSSParser().parse(frame: exssData)
                let xll = try XLLFrameASTParser.parse(exss.xllData)
                let signal = exss.info.dtsxAssetDescriptorSignal
                let privateFrame: DTSXTerminalPrivateFrameInspection?
                if !xll.privateData.isEmpty {
                    let privateAST = try DTSXPrivateFrameAST.parse(xll.privateData[...])
                    let navigation = try? privateAST.parseNavigation(
                        segmentCount: xll.segmentCount
                    )
                    privateFrame = DTSXTerminalPrivateFrameInspection(
                        byteCount: xll.privateData.count,
                        headerCRCIsValid: privateAST.headerCRCIsValid,
                        primarySixBitCode: privateAST.primarySixBitCode,
                        routingPermutation: privateAST.candidateCodedPlaneToHeightPermutation,
                        routingBranchCode: privateAST.candidateSecondaryBranchCode,
                        predictionCRCIsValid: (try? privateAST.parsePredictionCRC().isValid) ?? false,
                        navigationCRCIsValid: navigation?.crcIsValid,
                        navigationSegmentByteCounts: navigation?.segmentByteCounts
                    )
                } else {
                    privateFrame = nil
                }

                return DTSXTerminalAccessUnitInspection(
                    accessUnitIndex: accessUnit.index,
                    coreByteCount: accessUnit.coreByteCount,
                    exssByteCount: exssByteCount,
                    exssHeaderByteCount: exss.info.headerByteCount,
                    assetDescriptorByteCount: exss.info.assetDescriptorByteCount,
                    xllByteCount: exss.info.xllByteCount,
                    peakBitRateSmoothingBufferSizeCode:
                        exss.info.peakBitRateSmoothingBufferSizeCode,
                    xllInitialDecodingDelayBitCount:
                        exss.info.xllInitialDecodingDelayBitCount,
                    xllInitialDecodingDelayFrames: exss.info.xllInitialDecodingDelayFrames,
                    xllSyncByteOffset: exss.info.xllSyncByteOffset,
                    xllCommonHeaderByteCount: xll.commonHeaderByteCount,
                    xllSegmentCount: xll.segmentCount,
                    xllSegmentSampleCount: xll.segmentSampleCount,
                    xllPrivateDataByteOffset: xll.privateDataByteRange.lowerBound,
                    xllPrivateDataByteCount: xll.privateDataByteRange.count,
                    descriptorXLLXByteOffset: signal?.xllXByteOffset,
                    descriptorXLLXByteCount: signal?.xllXFrameByteCount,
                    channelSets: xll.channelSets.enumerated().map { index, channelSet in
                        DTSXTerminalChannelSetInspection(
                            index: index,
                            channelCount: channelSet.channelCount,
                            speakerMask: channelSet.speakerMask,
                            residualChannelMask: channelSet.residualChannelMask,
                            isPrimary: channelSet.isPrimary,
                            hierarchical: channelSet.hierarchical,
                            hasEmbeddedDownmix: channelSet.hasEmbeddedDownmix
                        )
                    },
                    privateFrame: privateFrame
                )
            }
        )
    }

    private static func readExactly(
        handle: FileHandle,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        guard count > 0 else {
            throw DTSError.malformed("DTS:X ExSS component has no bytes")
        }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else {
                throw DTSError.truncated(
                    field: "DTS:X ExSS component",
                    bitOffset: Int(offset) * 8 + data.count * 8
                )
            }
            return data
        } catch let error as DTSError {
            throw error
        } catch {
            throw DTSError.io("cannot read DTS:X ExSS component: \(error.localizedDescription)")
        }
    }
}
