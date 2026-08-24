import Foundation

public struct DTSXNativeEncoderVerificationReport: Sendable, Equatable, Codable {
    public let sourceSampleCount: Int
    public let privateXLLXCodingMode: DTSXPrivateCodingMode
    public let productionPrivateProfileIsOfficialBoundedRice: Bool
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
    public let terminalCoreSynchronizationPassed: Bool
    public let terminalCoreResidualChannelSetsPassed: Bool
    public let terminalConservativeXLLSyntaxPassed: Bool
    public let terminalPredictiveXLLSyntaxPassed: Bool
    public let terminalConservativeXLLXSyntaxPassed: Bool
    public let terminalStartupTransitionPassed: Bool
    public let terminalActiveStartupSegmentationPolicyPassed: Bool
    public let objectGainUnsmoothedMaximumStepQ30: Int64
    public let objectGainSmoothingMaximumStepQ30: Int64
    public let objectGainStepReductionFactor: Double
    public let objectGainSmoothingPassed: Bool
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
        let coreSyntax = try DTSCoreSyntaxVerifier.verify(inputURL: output)
        let terminalCoreSynchronizationPassed =
            coreSyntax.synchronizedSubSubframeCount == coreSyntax.frameCount
            && coreSyntax.firstFrame.bitstreamHeader.syncSubSubframes
            && coreSyntax.firstFrame.bitstreamHeader.copyHistory == 1
            && coreSyntax.firstFrame.subframes.allSatisfy {
                $0.dsyncCount == $0.subSubframeCount
            }
        let terminalCoreResidualChannelSetsPassed = try verifyTerminalCoreResidualChannelSets(
            inputURL: output
        )
        let terminalConservativeXLLSyntaxPassed = try verifyTerminalConservativeXLLSyntax(
            inputURL: output
        )
        let terminalPredictiveXLLSyntaxPassed = try verifyTerminalPredictiveXLLSyntax(
            inputURL: output
        )
        let terminalConservativeXLLXSyntaxPassed =
            first.report.privateEncoding.adaptivePredictedPlaneCount == 0
            && first.report.privateEncoding.fixedPredictionOrderHistogram.dropFirst().allSatisfy { $0 == 0 }
            && first.report.privateEncoding.decorrelationBranchHistogram.dropFirst().allSatisfy { $0 == 0 }
            && first.report.privateEncoding.hybridRiceParameterCount == 0
            && first.report.privateEncoding.hybridIsolatedSampleCount == 0
        let terminalStartupTransitionPassed = try verifyTerminalStartupTransition()
        let terminalActiveStartupSegmentationPolicyPassed = try
            verifyTerminalActiveStartupSegmentationPolicy()
        let objectGainSmoothing = DTS714ObjectGainSmoothingVerifier.verify()
        let adaptiveXLL = try verifyAdaptiveXLLRegression()
        let hybridXLL = try verifyHybridXLLRegression()

        let privateMismatchCount = first.report.privateEncoding.decodedSampleMismatchCount
        let bedMismatchCount = bedComparison.prefix.differentSamples
            + bedComparison.nonZeroPaddingSamples
        // The default production encoder must stay on the official-corpus
        // bounded mean-magnitude Rice profile; a silently changed default is
        // a delivery regression even when the stream still closes internally.
        let productionPrivateProfileIsOfficialBoundedRice =
            first.report.privateXLLXCodingMode == .terminalRiceOfficial
            && first.report.privateXLLXCodingMode.guaranteesBoundedUnaryQuotients
        let verified = deterministic
            && productionPrivateProfileIsOfficialBoundedRice
            && first.report.isInternallyBitExact
            && compatibilitySafety.isCompatible
            && structural.isStructurallyValid
            && structural.privateFrameCount == first.report.accessUnitCount
            && structural.allPrivateFramesMatchPublicSegmentation
            && privateMismatchCount == 0
            && bedMismatchCount == 0
            && terminalCoreSynchronizationPassed
            && terminalCoreResidualChannelSetsPassed
            && terminalConservativeXLLSyntaxPassed
            && terminalPredictiveXLLSyntaxPassed
            && terminalConservativeXLLXSyntaxPassed
            && terminalStartupTransitionPassed
            && terminalActiveStartupSegmentationPolicyPassed
            && objectGainSmoothing.isVerified
            && adaptiveXLL.passed
            && hybridXLL.passed
        let report = DTSXNativeEncoderVerificationReport(
            sourceSampleCount: source.sampleCount,
            privateXLLXCodingMode: first.report.privateXLLXCodingMode,
            productionPrivateProfileIsOfficialBoundedRice:
                productionPrivateProfileIsOfficialBoundedRice,
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
            terminalCoreSynchronizationPassed: terminalCoreSynchronizationPassed,
            terminalCoreResidualChannelSetsPassed: terminalCoreResidualChannelSetsPassed,
            terminalConservativeXLLSyntaxPassed: terminalConservativeXLLSyntaxPassed,
            terminalPredictiveXLLSyntaxPassed: terminalPredictiveXLLSyntaxPassed,
            terminalConservativeXLLXSyntaxPassed: terminalConservativeXLLXSyntaxPassed,
            terminalStartupTransitionPassed: terminalStartupTransitionPassed,
            terminalActiveStartupSegmentationPolicyPassed:
                terminalActiveStartupSegmentationPolicyPassed,
            objectGainUnsmoothedMaximumStepQ30:
                objectGainSmoothing.unsmoothedMaximumGainStepQ30,
            objectGainSmoothingMaximumStepQ30:
                objectGainSmoothing.maximumObservedGainStepQ30,
            objectGainStepReductionFactor:
                objectGainSmoothing.gainStepReductionFactor,
            objectGainSmoothingPassed: objectGainSmoothing.isVerified,
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

    private static func verifyTerminalCoreResidualChannelSets(inputURL: URL) throws -> Bool {
        let stream = try XLLPBRStreamReader.read(inputURL: inputURL)
        guard !stream.frames.isEmpty else { return false }
        var primaryMasks: Set<UInt64> = []
        for frame in stream.frames {
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            guard decoded.channelSets.count == 2 else { return false }
            let primary = decoded.channelSets[0]
            let secondary = decoded.channelSets[1]
            primaryMasks.insert(primary.residualChannelMask)
            // DTS:X reference delivery carries the six primary channels as
            // Core residuals and keeps the rear pair full-range in the
            // secondary set. The embedded matrix is part of this contract.
            guard primary.residualChannelMask == 0,
                  secondary.residualChannelMask == 0x03,
                  !primary.downmixCoefficientsPresent,
                  secondary.downmixCoefficientsPresent,
                  primary.downmixScaleCodes.isEmpty,
                  primary.downmixCoefficientCodes.isEmpty,
                  secondary.downmixScaleCodes.count == 6,
                  secondary.downmixCoefficientCodes.count == 12 else {
                return false
            }
        }
        return primaryMasks == [0]
    }

    private static func verifyTerminalConservativeXLLSyntax(inputURL: URL) throws -> Bool {
        let stream = try XLLPBRStreamReader.read(inputURL: inputURL)
        guard !stream.frames.isEmpty else { return false }
        let primingFrameCount = XLLSyntax.coreCompatiblePrimingSampleCount
            / XLLSyntax.frameSampleCount
        guard stream.frames.count >= primingFrameCount else { return false }
        for (frameIndex, frame) in stream.frames.enumerated() {
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            // The Core pre-roll access units carry no audio, but they are the
            // first two access units a terminal synchronizes to, so they must
            // declare exactly what every later access unit declares. Shared
            // entropy parameters, retained entropy state and a non-identity
            // pairwise-decorrelation channel order are all research-only
            // syntax and must never appear anywhere in a delivery stream.
            guard decoded.entropyStateReuseSegmentCount == 0,
                  decoded.entropyCommonParameterSegmentCount == 0,
                  decoded.entropyRiceParameterCount == 0,
                  decoded.hybridRiceParameterCount == 0,
                  decoded.hybridIsolatedSampleCount == 0,
                  decoded.channelSets.allSatisfy({ channelSet in
                      !channelSet.decorrelationEnabled
                          && channelSet.adaptivePredictionOrders.allSatisfy { $0 == 0 }
                          && channelSet.fixedPredictionOrders.allSatisfy { $0 == 0 }
                  }) else {
                return false
            }
            if frameIndex < primingFrameCount {
                guard decoded.channelSets.allSatisfy({ channelSet in
                    channelSet.planes.allSatisfy { plane in
                        plane.allSatisfy { $0 == 0 }
                    }
                }) else {
                    return false
                }
            }
        }
        return true
    }

    private static func verifyTerminalPredictiveXLLSyntax(inputURL: URL) throws -> Bool {
        let stream = try XLLPBRStreamReader.read(inputURL: inputURL)
        guard !stream.frames.isEmpty else { return false }
        let primingFrameCount = XLLSyntax.coreCompatiblePrimingSampleCount
            / XLLSyntax.frameSampleCount
        guard stream.frames.count >= primingFrameCount else { return false }

        for (frameIndex, frame) in stream.frames.enumerated() {
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            guard decoded.entropyStateReuseSegmentCount == 0,
                  decoded.hybridRiceParameterCount == 0,
                  decoded.hybridIsolatedSampleCount == 0,
                  decoded.channelSets.allSatisfy({ channelSet in
                      // The profile retains the reference channel-order field,
                      // but never emits a locally optimized pair transform.
                      channelSet.decorrelationCoefficients.allSatisfy { $0 == 0 }
                  }) else {
                return false
            }
            if frameIndex < primingFrameCount {
                guard decoded.entropyCommonParameterSegmentCount == 0,
                      decoded.entropyRiceParameterCount == 0,
                      decoded.channelSets.allSatisfy({ channelSet in
                          !channelSet.decorrelationEnabled
                              && channelSet.adaptivePredictionOrders.allSatisfy { $0 == 0 }
                              && channelSet.fixedPredictionOrders.allSatisfy { $0 == 0 }
                              && channelSet.planes.allSatisfy { plane in
                                  plane.allSatisfy { $0 == 0 }
                              }
                      }) else {
                    return false
                }
            }
        }
        return true
    }

    /// The Nature's Fury terminal reference has a frame-indexed silent-start
    /// grammar: after two Core-priming 2x256 access units, both first source
    /// frames use 4x128.
    /// The paired private frames are an explicitly navigated 52-byte silence
    /// and then the 56-byte code-16 no-NAVI silence. A third silent source AU
    /// must leave startup syntax and use the official 2x256, 52-byte code-16
    /// mid-stream form. Compression-cost search must never blur these states.
    private static func verifyTerminalStartupTransition() throws -> Bool {
        let sourceSampleCount = XLLSyntax.frameSampleCount * 3
        let silentSource = try DTS714PCMBuffer(
            planes: Array(
                repeating: Array(repeating: Int32(0), count: sourceSampleCount),
                count: DTS714Channel.allCases.count
            )
        )
        func verifyEncoding(publicForcedSegmentCount: Int?) throws -> Bool {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("swift-native-dtsx-startup-\(UUID().uuidString)")
            let output = root.appendingPathExtension("dtshd")
            let payload = root.appendingPathExtension("xllx")
            let index = root.appendingPathExtension("json")
            defer {
                try? FileManager.default.removeItem(at: output)
                try? FileManager.default.removeItem(at: payload)
                try? FileManager.default.removeItem(at: index)
            }

            let encoded = try DTSXNativeHDMAEncoder(
                verificationPolicy: .integrated,
                publicXLLForcedSegmentCount: publicForcedSegmentCount
            ).encode(source: silentSource, frameRate: .fps24)
            try encoded.stream.write(to: output, options: .atomic)
            let publicStream = try XLLPBRStreamReader.read(inputURL: output)
            let publicSegments = try publicStream.frames.map {
                try XLLFrameASTParser.parse($0.frame).segmentCount
            }
            guard publicSegments == [2, 2, 4, 4, 2] else { return false }

            let extraction = try DTSXObjectExtractor.extract(
                inputURL: output,
                payloadOutputURL: payload,
                indexOutputURL: index
            )
            guard extraction.frames.count == 5,
                  extraction.frames.map({ $0.xllSyntax?.segmentCount }) == [2, 2, 4, 4, 2] else {
                return false
            }
            let payloadBytes = try Data(contentsOf: payload)
            let expected: [(byteCount: Int, code: UInt8, segments: [Int]?)] = [
                (48, 15, nil),
                (48, 15, nil),
                (52, 15, [2, 1, 1, 1]),
                (56, 16, nil),
                (52, 16, nil)
            ]
            for (frameIndex, pair) in zip(extraction.frames, expected).enumerated() {
                let (record, expectation) = pair
                guard let payloadOffset = record.payloadFileOffset,
                      record.payloadByteCount == expectation.byteCount,
                      payloadOffset >= 0,
                      payloadOffset + record.payloadByteCount <= payloadBytes.count else {
                    return false
                }
                let frame = payloadBytes.subdata(
                    in: payloadOffset..<(payloadOffset + record.payloadByteCount)
                )
                let ast = try DTSXPrivateFrameAST.parse(frame[...])
                guard ast.headerCRCIsValid,
                      ast.primarySixBitCode == expectation.code,
                      try ast.parsePredictionCRC().isValid else {
                    return false
                }
                let navigation = try? ast.parseNavigation(
                    segmentCount: record.xllSyntax?.segmentCount ?? 0
                )
                if let segments = expectation.segments {
                    guard navigation?.crcIsValid == true,
                          navigation?.segmentByteCounts == segments else {
                        return false
                    }
                } else if navigation != nil {
                    return false
                }
                if frameIndex == expected.count - 1 {
                    guard SHA256Hasher.hash(frame)
                            == "df3fcd92dc6671572596e9c9ede1ca5a278bf4c9563f80d22c867533bdcc1144",
                          let header = try ast.parsePredictionHeaderCandidates().first,
                          let sideInfo = try DTSXPrivateNoNavigationZeroSideInfo.parse(
                            ast,
                            prediction: header,
                            segmentCount: 2,
                            segmentSampleCount: 256
                          ),
                          sideInfo.controlCode == 0x20 else {
                        return false
                    }
                }
            }
            return true
        }

        // The diagnostic override applies only after the terminal's observed
        // startup sequence. A forced 2x256 investigation must not regress the
        // first two source AUs to the unplayable all-2x256 startup grammar.
        return try verifyEncoding(publicForcedSegmentCount: nil)
            && verifyEncoding(publicForcedSegmentCount: 2)
    }

    /// Active-height controlled references do not use Nature's Fury's silent
    /// 4x128 transition. Verify both the session policy and the enclosing HDMA
    /// selection so a second unconditional startup override cannot return.
    private static func verifyTerminalActiveStartupSegmentationPolicy() throws -> Bool {
        let sourceSampleCount = XLLSyntax.frameSampleCount * 3
        var planes = Array(
            repeating: Array(repeating: Int32(0), count: sourceSampleCount),
            count: DTS714Channel.allCases.count
        )
        let heightIndex = DTS714Channel.allCases.firstIndex(of: .leftFrontHeight)!
        for sample in 0..<(XLLSyntax.frameSampleCount * 2) {
            planes[heightIndex][sample] = sample.isMultiple(of: 2) ? 1_000_000 : -1_000_000
        }
        let activeSource = try DTS714PCMBuffer(planes: planes)
        let session = try DTSXPrivateStreamEncodingSession(
            source: activeSource,
            codingMode: .terminalRiceOfficial
        )
        guard (0..<session.frameCount).map({
            session.terminalPreferredPublicSegmentCount(at: $0)
        }) == [2, 2, nil, nil, 2] else {
            return false
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-native-dtsx-active-startup-\(UUID().uuidString)")
        let output = root.appendingPathExtension("dtshd")
        defer { try? FileManager.default.removeItem(at: output) }
        let encoded = try DTSXNativeHDMAEncoder(
            verificationPolicy: .none,
            publicXLLForcedSegmentCount: 2,
            privateXLLXCodingMode: .terminalRiceOfficial
        ).encode(source: activeSource, frameRate: .fps24)
        try encoded.stream.write(to: output, options: .atomic)
        let publicStream = try XLLPBRStreamReader.read(inputURL: output)
        let publicSegments = try publicStream.frames.map {
            try XLLFrameASTParser.parse($0.frame).segmentCount
        }
        guard publicSegments == [2, 2, 2, 2, 2] else { return false }
        let structural = try DTSXObjectExtractor.verify(inputURL: output)
        return structural.isStructurallyValid
            && structural.allPrivateFramesMatchPublicSegmentation
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
