import Foundation

public struct DTSXNativeEncoderVerificationReport: Sendable, Equatable, Codable {
    public let sourceSampleCount: Int
    public let accessUnitCount: Int
    public let streamByteCount: Int
    public let streamSHA256: String
    public let repeatStreamSHA256: String
    public let deterministic: Bool
    public let privateFrameCount: Int
    public let privateSegmentationMatchedFrameCount: Int
    public let allPrivateFramesMatchPublicSegmentation: Bool
    public let dtsxAssetDescriptorFrameCount: Int
    public let privatePayloadByteCount: Int
    public let compatibilityBedDifferentSampleCount: Int
    public let privateDifferentSampleCount: Int
    public let adaptiveXLLPredictionOrders: [Int]
    public let adaptiveXLLSegmentCount: Int
    public let adaptiveXLLDifferentSampleCount: Int
    public let adaptiveXLLRegressionPassed: Bool
    public let hybridXLLParameterCount: Int
    public let hybridXLLIsolatedSampleCount: Int
    public let hybridXLLDifferentSampleCount: Int
    public let hybridXLLRegressionPassed: Bool
    public let isStructurallyValid: Bool
    public let isVerified: Bool
}

public enum DTSXNativeEncoderVerifier {
    public static func verify() throws -> DTSXNativeEncoderVerificationReport {
        let source = try syntheticSource()
        let encoder = DTSXNativeHDMAEncoder(verificationPolicy: .integrated)
        let first = try encoder.encode(source: source, frameRate: .fps24)
        let second = try encoder.encode(source: source, frameRate: .fps24)
        let deterministic = first.stream == second.stream
        guard let bedComparison = first.report.compatibilityBedComparison,
              let compatibilitySafety = first.report.compatibilitySafety else {
            throw DTSError.malformed(
                "native DTS:X integrated verification did not produce its PCM reports"
            )
        }

        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-native-dtsx-verification-\(UUID().uuidString).dtshd"
        )
        do {
            try first.stream.write(to: output, options: .atomic)
        } catch {
            throw DTSError.io("cannot write native DTS:X verification stream: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let structural = try DTSXObjectExtractor.verify(inputURL: output)
        let adaptiveXLL = try verifyAdaptiveXLLRegression()
        let hybridXLL = try verifyHybridXLLRegression()

        let privateMismatchCount = first.report.privateEncoding.decodedSampleMismatchCount
        let bedMismatchCount = bedComparison.prefix.differentSamples
            + bedComparison.nonZeroPaddingSamples
        let verified = deterministic
            && first.report.isInternallyBitExact
            && compatibilitySafety.isCompatible
            && structural.isStructurallyValid
            && structural.privateFrameCount == first.report.accessUnitCount
            && structural.allPrivateFramesMatchPublicSegmentation
            && privateMismatchCount == 0
            && bedMismatchCount == 0
            && adaptiveXLL.passed
            && hybridXLL.passed
        let report = DTSXNativeEncoderVerificationReport(
            sourceSampleCount: source.sampleCount,
            accessUnitCount: first.report.accessUnitCount,
            streamByteCount: first.stream.count,
            streamSHA256: first.report.streamSHA256,
            repeatStreamSHA256: second.report.streamSHA256,
            deterministic: deterministic,
            privateFrameCount: structural.privateFrameCount,
            privateSegmentationMatchedFrameCount:
                structural.privateSegmentationMatchedFrameCount,
            allPrivateFramesMatchPublicSegmentation:
                structural.allPrivateFramesMatchPublicSegmentation,
            dtsxAssetDescriptorFrameCount: structural.dtsxAssetDescriptorFrameCount,
            privatePayloadByteCount: structural.privatePayloadByteCount,
            compatibilityBedDifferentSampleCount: bedMismatchCount,
            privateDifferentSampleCount: privateMismatchCount,
            adaptiveXLLPredictionOrders: adaptiveXLL.predictionOrders,
            adaptiveXLLSegmentCount: adaptiveXLL.segmentCount,
            adaptiveXLLDifferentSampleCount: adaptiveXLL.differentSampleCount,
            adaptiveXLLRegressionPassed: adaptiveXLL.passed,
            hybridXLLParameterCount: hybridXLL.parameterCount,
            hybridXLLIsolatedSampleCount: hybridXLL.isolatedSampleCount,
            hybridXLLDifferentSampleCount: hybridXLL.differentSampleCount,
            hybridXLLRegressionPassed: hybridXLL.passed,
            isStructurallyValid: structural.isStructurallyValid,
            isVerified: verified
        )
        guard report.isVerified else {
            throw DTSError.malformed("native DTS:X integrated encoder verification failed")
        }
        return report
    }

    /// Exercises the adaptive predictor's one-time Part A seed partition and
    /// the following segment's explicit entropy state. A smooth two-tone input
    /// makes an adaptive order preferable to fixed finite differences.
    private static func verifyAdaptiveXLLRegression() throws -> (
        predictionOrders: [Int],
        segmentCount: Int,
        differentSampleCount: Int,
        passed: Bool
    ) {
        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .stereo)
        let frequencies = [997.0, 2_117.0]
        let planes = frequencies.enumerated().map { channel, frequency in
            (0..<XLLSyntax.frameSampleCount).map { sample -> Int32 in
                let phase = 2.0 * Double.pi * frequency * Double(sample) / 48_000.0
                    + Double(channel) * 0.37
                return Int32((sin(phase) * 3_000_000.0).rounded())
            }
        }
        let input = try PCMBuffer(format: format, planes: planes)
        let encoded = try XLLEncoder().encode(frame: input)
        let decodedChannelSets = try XLLDecoder().decodeChannelSets(frame: encoded.data)
        let decoded = try XLLDecoder().decode(frame: encoded.data).pcm
        let predictionOrders = decodedChannelSets.channelSets
            .flatMap(\.adaptivePredictionOrders)
        let segmentCount = try XLLFrameASTParser.parse(encoded.data).segmentCount
        var differentSampleCount = 0
        for channel in input.planes.indices {
            for sample in input.planes[channel].indices
            where input.planes[channel][sample] != decoded.planes[channel][sample] {
                differentSampleCount += 1
            }
        }
        let passed = predictionOrders.contains(where: { $0 > 0 })
            && segmentCount > 1
            && differentSampleCount == 0
        return (predictionOrders, segmentCount, differentSampleCount, passed)
    }

    private static func verifyHybridXLLRegression() throws -> (
        parameterCount: Int,
        isolatedSampleCount: Int,
        differentSampleCount: Int,
        passed: Bool
    ) {
        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .stereo)
        let planes = (0..<2).map { channel in
            (0..<XLLSyntax.frameSampleCount).map { sample -> Int32 in
                if sample % (61 + channel * 2) == channel {
                    return sample.isMultiple(of: 2) ? 8_000_000 : -8_000_000
                }
                return Int32((sample * (channel + 3) * 29) % 257 - 128)
            }
        }
        let input = try PCMBuffer(format: format, planes: planes)
        let encoded = try XLLEncoder().encode(frame: input)
        let decodedSets = try XLLDecoder().decodeChannelSets(frame: encoded.data)
        let decoded = try XLLDecoder().decode(frame: encoded.data).pcm
        var differentSampleCount = 0
        for channel in input.planes.indices {
            for sample in input.planes[channel].indices
            where input.planes[channel][sample] != decoded.planes[channel][sample] {
                differentSampleCount += 1
            }
        }
        let passed = decodedSets.hybridRiceParameterCount > 0
            && decodedSets.hybridIsolatedSampleCount > 0
            && differentSampleCount == 0
        return (
            decodedSets.hybridRiceParameterCount,
            decodedSets.hybridIsolatedSampleCount,
            differentSampleCount,
            passed
        )
    }

    private static func syntheticSource() throws -> DTS714PCMBuffer {
        let planes = (0..<DTS714Channel.allCases.count).map { channel in
            (0..<DTSXPrivateFrameEncoder.frameSampleCount).map { sample -> Int32 in
                let period = 1_800_001
                let raw = (sample * (channel * 37 + 11) * 7919 + channel * 104_729) % period
                return Int32(raw - period / 2)
            }
        }
        return try DTS714PCMBuffer(planes: planes)
    }
}
