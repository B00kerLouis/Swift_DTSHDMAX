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
