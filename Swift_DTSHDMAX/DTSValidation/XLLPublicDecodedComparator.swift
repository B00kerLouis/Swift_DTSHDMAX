import Foundation

public struct XLLPublicDecodedSampleMismatch: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let channelSetIndex: Int
    public let channelIndex: Int
    public let sampleIndex: Int
    public let baseline: Int32
    public let candidate: Int32
}

public struct XLLPublicDecodedComparisonReport: Sendable, Equatable, Codable {
    public let baselinePath: String
    public let candidatePath: String
    public let baselineSHA256: String
    public let candidateSHA256: String
    public let baselineFrameCount: Int
    public let candidateFrameCount: Int
    public let comparedFrameCount: Int
    public let segmentationMismatchFrameCount: Int
    public let channelConfigurationMismatchFrameCount: Int
    public let entropySummaryMismatchFrameCount: Int
    public let decodedSampleMismatchCount: Int
    public let firstDecodedSampleMismatch: XLLPublicDecodedSampleMismatch?
    public let baselinePrivateDataFrameCount: Int
    public let candidatePrivateDataFrameCount: Int
    public let isPublicXLLSemanticallyIdentical: Bool
}

public enum XLLPublicDecodedComparator {
    public static func compare(
        baselineURL: URL,
        candidateURL: URL
    ) throws -> XLLPublicDecodedComparisonReport {
        let baselinePath = baselineURL.standardizedFileURL
        let candidatePath = candidateURL.standardizedFileURL
        let baseline = try XLLPBRStreamReader.read(inputURL: baselinePath)
        let candidate = try XLLPBRStreamReader.read(inputURL: candidatePath)
        let comparedFrameCount = min(baseline.frames.count, candidate.frames.count)

        var segmentationMismatchFrameCount = 0
        var channelConfigurationMismatchFrameCount = 0
        var entropySummaryMismatchFrameCount = 0
        var decodedSampleMismatchCount = 0
        var firstDecodedSampleMismatch: XLLPublicDecodedSampleMismatch?
        var baselinePrivateDataFrameCount = 0
        var candidatePrivateDataFrameCount = 0

        for frameIndex in 0..<comparedFrameCount {
            let baselineFrame = baseline.frames[frameIndex].frame
            let candidateFrame = candidate.frames[frameIndex].frame
            let baselineAST = try XLLFrameASTParser.parse(baselineFrame)
            let candidateAST = try XLLFrameASTParser.parse(candidateFrame)
            if !baselineAST.privateData.isEmpty { baselinePrivateDataFrameCount += 1 }
            if !candidateAST.privateData.isEmpty { candidatePrivateDataFrameCount += 1 }
            if baselineAST.segmentCount != candidateAST.segmentCount
                || baselineAST.segmentSampleCount != candidateAST.segmentSampleCount {
                segmentationMismatchFrameCount += 1
            }

            let baselineDecoded = try XLLDecoder().decodeChannelSets(frame: baselineFrame)
            let candidateDecoded = try XLLDecoder().decodeChannelSets(frame: candidateFrame)
            if baselineDecoded.entropyStateReuseSegmentCount
                    != candidateDecoded.entropyStateReuseSegmentCount
                || baselineDecoded.entropyCommonParameterSegmentCount
                    != candidateDecoded.entropyCommonParameterSegmentCount
                || baselineDecoded.entropyRiceParameterCount
                    != candidateDecoded.entropyRiceParameterCount
                || baselineDecoded.hybridRiceParameterCount
                    != candidateDecoded.hybridRiceParameterCount
                || baselineDecoded.hybridIsolatedSampleCount
                    != candidateDecoded.hybridIsolatedSampleCount {
                entropySummaryMismatchFrameCount += 1
            }

            var configurationMismatch = baselineDecoded.fixedLSBWidth
                != candidateDecoded.fixedLSBWidth
                || baselineDecoded.sampleCount != candidateDecoded.sampleCount
                || baselineDecoded.channelSets.count != candidateDecoded.channelSets.count
            let channelSetCount = min(
                baselineDecoded.channelSets.count,
                candidateDecoded.channelSets.count
            )
            for channelSetIndex in 0..<channelSetCount {
                let baselineSet = baselineDecoded.channelSets[channelSetIndex]
                let candidateSet = candidateDecoded.channelSets[channelSetIndex]
                if !sameConfiguration(baselineSet, candidateSet) {
                    configurationMismatch = true
                }
                let channelCount = min(baselineSet.planes.count, candidateSet.planes.count)
                if baselineSet.planes.count != candidateSet.planes.count {
                    configurationMismatch = true
                }
                for channelIndex in 0..<channelCount {
                    let baselinePlane = baselineSet.planes[channelIndex]
                    let candidatePlane = candidateSet.planes[channelIndex]
                    let sampleCount = min(baselinePlane.count, candidatePlane.count)
                    if baselinePlane.count != candidatePlane.count {
                        configurationMismatch = true
                    }
                    for sampleIndex in 0..<sampleCount
                    where baselinePlane[sampleIndex] != candidatePlane[sampleIndex] {
                        decodedSampleMismatchCount += 1
                        if firstDecodedSampleMismatch == nil {
                            firstDecodedSampleMismatch = XLLPublicDecodedSampleMismatch(
                                frameIndex: frameIndex,
                                channelSetIndex: channelSetIndex,
                                channelIndex: channelIndex,
                                sampleIndex: sampleIndex,
                                baseline: baselinePlane[sampleIndex],
                                candidate: candidatePlane[sampleIndex]
                            )
                        }
                    }
                }
            }
            if configurationMismatch {
                channelConfigurationMismatchFrameCount += 1
            }
        }

        let report = XLLPublicDecodedComparisonReport(
            baselinePath: baselinePath.path,
            candidatePath: candidatePath.path,
            baselineSHA256: try SHA256Hasher.hash(fileAt: baselinePath),
            candidateSHA256: try SHA256Hasher.hash(fileAt: candidatePath),
            baselineFrameCount: baseline.frames.count,
            candidateFrameCount: candidate.frames.count,
            comparedFrameCount: comparedFrameCount,
            segmentationMismatchFrameCount: segmentationMismatchFrameCount,
            channelConfigurationMismatchFrameCount: channelConfigurationMismatchFrameCount,
            entropySummaryMismatchFrameCount: entropySummaryMismatchFrameCount,
            decodedSampleMismatchCount: decodedSampleMismatchCount,
            firstDecodedSampleMismatch: firstDecodedSampleMismatch,
            baselinePrivateDataFrameCount: baselinePrivateDataFrameCount,
            candidatePrivateDataFrameCount: candidatePrivateDataFrameCount,
            isPublicXLLSemanticallyIdentical: baseline.frames.count == candidate.frames.count
                && segmentationMismatchFrameCount == 0
                && channelConfigurationMismatchFrameCount == 0
                && entropySummaryMismatchFrameCount == 0
                && decodedSampleMismatchCount == 0
        )
        return report
    }

    private static func sameConfiguration(
        _ baseline: XLLDecodedChannelSet,
        _ candidate: XLLDecodedChannelSet
    ) -> Bool {
        baseline.index == candidate.index
            && baseline.speakerMask == candidate.speakerMask
            && baseline.residualChannelMask == candidate.residualChannelMask
            && baseline.pcmBitDepth == candidate.pcmBitDepth
            && baseline.storageBitDepth == candidate.storageBitDepth
            && baseline.downmixCoefficientsPresent == candidate.downmixCoefficientsPresent
            && baseline.downmixEmbedded == candidate.downmixEmbedded
            && baseline.downmixScaleCodes == candidate.downmixScaleCodes
            && baseline.downmixCoefficientCodes == candidate.downmixCoefficientCodes
            && baseline.decorrelationEnabled == candidate.decorrelationEnabled
            && baseline.originalOrder == candidate.originalOrder
            && baseline.decorrelationCoefficients == candidate.decorrelationCoefficients
            && baseline.adaptivePredictionOrders == candidate.adaptivePredictionOrders
            && baseline.fixedPredictionOrders == candidate.fixedPredictionOrders
            && baseline.scalableLSBWidths == candidate.scalableLSBWidths
            && baseline.bitWidthAdjustments == candidate.bitWidthAdjustments
    }
}
