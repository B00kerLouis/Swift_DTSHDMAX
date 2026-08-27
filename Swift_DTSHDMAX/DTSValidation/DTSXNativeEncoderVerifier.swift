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
    public let terminalCoreSynchronizationPassed: Bool
    public let terminalCoreResidualChannelSetsPassed: Bool
    public let terminalOfficialRiceXLLSyntaxPassed: Bool
    public let terminalPredictiveXLLSyntaxPassed: Bool
    public let terminalConservativeXLLXSyntaxPassed: Bool
    public let terminalStartupTransitionPassed: Bool
    public let terminalHotStartStartupTransitionPassed: Bool
    public let terminalBedOnlyProgrammeTimelinePassed: Bool
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
    public let recoveryScaleCodesMatchOfficialConstant: Bool
    public let recoveryClipSampleCount: Int
    public let recoveryMaximumAbsoluteResidual: Int64
    public let recoveryStartupPassed: Bool
    public let earlyProgramme: DTSXEarlyProgrammeGrammarReport
    public let earlyProgrammePassed: Bool
    public let renderGuard: DTS714RenderGuardVerificationReport
    public let renderGuardPassed: Bool
    public let isStructurallyValid: Bool
    public let isVerified: Bool
}

public enum DTSXNativeEncoderVerifier {
    /// Byte count of one delivery-grammar zero priming access unit: the same
    /// explicit-entropy silent 2x256 form every mid-stream silent delivery
    /// frame uses (eight bytes larger than the research-only compact zero
    /// form it replaces).
    public static let deliveryPrimingFrameByteCount = 140

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
        let terminalOfficialRiceXLLSyntaxPassed = try verifyTerminalOfficialRiceXLLSyntax(
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
        let terminalHotStartStartupTransitionPassed = try
            verifyTerminalHotStartStartupTransition()
        let terminalBedOnlyProgrammeTimelinePassed = try
            verifyTerminalBedOnlyProgrammeTimeline()
        let terminalActiveStartupSegmentationPolicyPassed = try
            verifyTerminalActiveStartupSegmentationPolicy()
        let objectGainSmoothing = DTS714ObjectGainSmoothingVerifier.verify()
        let adaptiveXLL = try verifyAdaptiveXLLRegression()
        let hybridXLL = try verifyHybridXLLRegression()
        let recoveryPrimary = try XLLRecoveryStartupVerifier.verify(inputURL: output)
        let recoveryHotStart = try verifyHotStartRecoveryWindow()
        let recoveryStartupPassed = recoveryPrimary.isRecoverySafe
            && recoveryHotStart.isRecoverySafe
        let earlyProgrammePrimary = try DTSXEarlyProgrammeGrammarVerifier.verify(
            inputURL: output
        )
        let earlyProgrammeHostile = try verifyHostileStartEarlyProgramme()
        let earlyProgrammePassed = earlyProgrammePrimary.isEarlyProgrammeSafe
            && earlyProgrammeHostile.isEarlyProgrammeSafe
        let renderGuard = try DTS714RenderGuardVerifier.verify()

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
            && terminalCoreSynchronizationPassed
            && terminalCoreResidualChannelSetsPassed
            && terminalOfficialRiceXLLSyntaxPassed
            && terminalPredictiveXLLSyntaxPassed
            && terminalConservativeXLLXSyntaxPassed
            && terminalStartupTransitionPassed
            && terminalHotStartStartupTransitionPassed
            && terminalBedOnlyProgrammeTimelinePassed
            && terminalActiveStartupSegmentationPolicyPassed
            && objectGainSmoothing.isVerified
            && adaptiveXLL.passed
            && hybridXLL.passed
            && recoveryStartupPassed
            && earlyProgrammePassed
            && renderGuard.isVerified
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
            terminalCoreSynchronizationPassed: terminalCoreSynchronizationPassed,
            terminalCoreResidualChannelSetsPassed: terminalCoreResidualChannelSetsPassed,
            terminalOfficialRiceXLLSyntaxPassed: terminalOfficialRiceXLLSyntaxPassed,
            terminalPredictiveXLLSyntaxPassed: terminalPredictiveXLLSyntaxPassed,
            terminalConservativeXLLXSyntaxPassed: terminalConservativeXLLXSyntaxPassed,
            terminalStartupTransitionPassed: terminalStartupTransitionPassed,
            terminalHotStartStartupTransitionPassed:
                terminalHotStartStartupTransitionPassed,
            terminalBedOnlyProgrammeTimelinePassed:
                terminalBedOnlyProgrammeTimelinePassed,
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
            recoveryScaleCodesMatchOfficialConstant:
                recoveryPrimary.scaleCodesMatchOfficialConstant
                && recoveryHotStart.scaleCodesMatchOfficialConstant,
            recoveryClipSampleCount: recoveryHotStart.recoveryClipSampleCount,
            recoveryMaximumAbsoluteResidual: recoveryHotStart.maximumAbsoluteResidual,
            recoveryStartupPassed: recoveryStartupPassed,
            earlyProgramme: earlyProgrammeHostile,
            earlyProgrammePassed: earlyProgrammePassed,
            renderGuard: renderGuard,
            renderGuardPassed: renderGuard.isVerified,
            isStructurallyValid: structural.isStructurallyValid,
            isVerified: verified
        )
        guard report.isVerified else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = (try? encoder.encode(report))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "unencodable report"
            throw DTSError.malformed(
                "native DTS:X integrated encoder verification failed: \(json)"
            )
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

    /// Gates the official-corpus delivery grammar of the public XLL residual
    /// path. Every frame - the two zero priming frames included - must keep
    /// the delivery channel-set declarations: every segment that carries
    /// residual content must be ordinary Rice with an explicit per-channel
    /// parameter, and only all-zero segments may keep the compact zero-width
    /// linear form. A nonzero-width linear active segment is the one grammar
    /// the recovered references never exercise; once the Core carried the
    /// declared downmix fold, the shrunken residuals put an all-linear
    /// encode permanently inside that unexercised form, which the terminal
    /// presented as noise-gate-like dropouts on quiet content and an
    /// unreadable first active frame. Priming AUs additionally pin the
    /// canonical silent delivery form: research-only compact priming
    /// (pairwise-decorrelation declaration, permuted channel order, shared
    /// entropy parameters) latched terminals onto a configuration no later
    /// frame repeats and made hot-start first frames unplayable until AU3.
    private static func verifyTerminalOfficialRiceXLLSyntax(inputURL: URL) throws -> Bool {
        let stream = try XLLPBRStreamReader.read(inputURL: inputURL)
        guard !stream.frames.isEmpty else { return false }
        let primingFrameCount = XLLSyntax.coreCompatiblePrimingSampleCount
            / XLLSyntax.frameSampleCount
        guard stream.frames.count >= primingFrameCount else { return false }
        for (frameIndex, frame) in stream.frames.enumerated() {
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            if frameIndex < primingFrameCount {
                // Delivery-grammar priming: identical channel-set
                // declarations to every later silent delivery frame, with
                // all-zero planes and no research-only syntax.
                guard decoded.frameByteCount == deliveryPrimingFrameByteCount,
                      decoded.entropyStateReuseSegmentCount == 0,
                      decoded.entropyCommonParameterSegmentCount == 0,
                      decoded.entropyRiceParameterCount == 0,
                      decoded.hybridRiceParameterCount == 0,
                      decoded.hybridIsolatedSampleCount == 0,
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
                continue
            }
            let segmentCount = try XLLFrameASTParser.parse(frame.frame).segmentCount
            guard segmentCount > 0,
                  XLLSyntax.frameSampleCount.isMultiple(of: segmentCount) else {
                return false
            }
            let segmentSampleCount = XLLSyntax.frameSampleCount / segmentCount
            // With prediction and decorrelation disabled the decoded planes
            // are the coded residual planes, so the exact per-segment
            // activity map is recoverable from the decode.
            var activeSegmentParameterCount = 0
            for channelSet in decoded.channelSets {
                for plane in channelSet.planes {
                    guard plane.count == XLLSyntax.frameSampleCount else { return false }
                    for segment in 0..<segmentCount {
                        let start = segment * segmentSampleCount
                        if plane[start..<(start + segmentSampleCount)].contains(where: { $0 != 0 }) {
                            activeSegmentParameterCount += 1
                        }
                    }
                }
            }
            guard decoded.entropyStateReuseSegmentCount == 0,
                  decoded.entropyCommonParameterSegmentCount == 0,
                  decoded.hybridRiceParameterCount == 0,
                  decoded.hybridIsolatedSampleCount == 0,
                  decoded.entropyRiceParameterCount == activeSegmentParameterCount,
                  decoded.channelSets.allSatisfy({ channelSet in
                      channelSet.adaptivePredictionOrders.allSatisfy { $0 == 0 }
                          && channelSet.fixedPredictionOrders.allSatisfy { $0 == 0 }
                          && !channelSet.decorrelationEnabled
                  }) else {
                return false
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
                guard decoded.frameByteCount == deliveryPrimingFrameByteCount,
                      decoded.entropyCommonParameterSegmentCount == 0,
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

    /// SHA-256 of the deterministic 48-byte compact zero XLL-X frame - the
    /// Core-priming declaration. It must appear on exactly the two priming
    /// access units of every delivery stream.
    static let corePrimingXLLXFrameSHA256 =
        "0f9c24a65b214a2a81df643d102e2facf4f176e9fb784c1eb60f6c57cf1c5604"
    /// SHA-256 of the deterministic 52-byte code-0x20 no-NAVI XLL-X frame -
    /// the ordinary 2x256 silence declaration for fully silent (bed and
    /// heights) source access units.
    static let midStreamSilenceXLLXFrameSHA256 =
        "df3fcd92dc6671572596e9c9ede1ca5a278bf4c9563f80d22c867533bdcc1144"
    /// SHA-256 of the deterministic 52-byte ordinary navigated 2x256
    /// delivery frame that decodes to zero heights - the required private
    /// frame class for every bed-audible height-silent access unit (tbh's
    /// bed-only head and tail). A compact/no-NAVI silence declaration on
    /// such an access unit is the DTS:X-only "bed plays, DTS:X presentation
    /// fails" defect.
    ///
    /// The frame's entropy segments carry the corpus zero-plane declaration
    /// (shared-parameter signed-linear width 0: `0x80 0x00` then `0x40`),
    /// the same segment bytes as every recovered official zero declaration.
    /// The previous 316-byte pin
    /// (`7c312a858b6517e76082f6529524b1946031412359c1ed128f1fb4d28b7da82c`)
    /// carried the same navigated class but Rice-coded each digital-zero
    /// plane at ABIT 0 - 256 unary terminator bits per plane per segment, a
    /// run form no recovered corpus frame exercises anywhere.
    static let bedAudibleZeroHeightsXLLXFrameByteCount = 52
    static let bedAudibleZeroHeightsXLLXFrameSHA256 =
        "b320058985299c06b9164545d88ac85415ce31183e8647126e542b6486eba542"

    private struct HotStartPrivateFrameExpectation {
        /// nil expects an active navigated frame whose size is content-defined.
        let byteCount: Int?
        let code: UInt8
        let expectsNavigation: Bool
        let sideInfoControlCode: UInt8?
        let sha256: String?
        /// True requires the private frame to decode to four all-zero
        /// height planes (the navigated zero-height delivery class).
        let expectsZeroDecodedHeights: Bool
    }

    /// tbh-class hot starts: the bed is active somewhere inside the two-AU
    /// startup window while the startup heights stay silent. The public
    /// partition must stay on the ordinary 2x256 delivery form for every
    /// access unit (the 4x128 startup pair belongs exclusively to fully
    /// silent starts), and the private timeline must key its frame class on
    /// whole-access-unit audibility: the 48-byte compact zero form on
    /// exactly AU0/AU1, the code-0x20 silence declaration on exactly the
    /// fully silent source access units, and an ordinary navigated delivery
    /// frame decoding to zero heights on every bed-audible height-silent
    /// access unit. The regressions this gates are both DTS:X-only "bed
    /// plays, DTS:X presentation fails" failures: priming declarations
    /// leaking over audible source AUs (first frames unplayable until AU3)
    /// and silence declarations leaking over the audible bed (tbh's bed-only
    /// head unplayable for ~10 s while the 7.1 bed - the same downmix -
    /// stayed playable).
    private static func verifyTerminalHotStartStartupTransition() throws -> Bool {
        let sourceFrameCount = 3
        let sourceSampleCount = XLLSyntax.frameSampleCount * sourceFrameCount
        let center = DTS714Channel.allCases.firstIndex(of: .center)!
        let leftFrontHeight = DTS714Channel.allCases.firstIndex(of: .leftFrontHeight)!

        func silentPlanes() -> [[Int32]] {
            Array(
                repeating: Array(repeating: Int32(0), count: sourceSampleCount),
                count: DTS714Channel.allCases.count
            )
        }
        func writeTone(
            into planes: inout [[Int32]],
            channel: Int,
            samples: Range<Int>,
            amplitude: Double,
            frequency: Double
        ) {
            for sample in samples {
                let phase = 2.0 * Double.pi * frequency * Double(sample) / 48_000.0
                planes[channel][sample] = Int32((sin(phase) * amplitude).rounded())
            }
        }

        let corePriming = HotStartPrivateFrameExpectation(
            byteCount: 48,
            code: 15,
            expectsNavigation: false,
            sideInfoControlCode: nil,
            sha256: corePrimingXLLXFrameSHA256,
            expectsZeroDecodedHeights: true
        )
        let sourceSilence = HotStartPrivateFrameExpectation(
            byteCount: 52,
            code: 16,
            expectsNavigation: false,
            sideInfoControlCode: 0x20,
            sha256: midStreamSilenceXLLXFrameSHA256,
            expectsZeroDecodedHeights: true
        )
        let bedAudibleZeroHeights = HotStartPrivateFrameExpectation(
            byteCount: bedAudibleZeroHeightsXLLXFrameByteCount,
            code: 17,
            expectsNavigation: true,
            sideInfoControlCode: nil,
            sha256: bedAudibleZeroHeightsXLLXFrameSHA256,
            expectsZeroDecodedHeights: true
        )
        let activeFrame = HotStartPrivateFrameExpectation(
            byteCount: nil,
            code: 17,
            expectsNavigation: true,
            sideInfoControlCode: nil,
            sha256: nil,
            expectsZeroDecodedHeights: false
        )

        // Hot from sample zero: the tbh shape. Every source access unit is
        // bed-audible with silent heights, so the whole run must carry the
        // ordinary navigated zero-height delivery frame - never a silence
        // declaration.
        var hotFromSampleZero = silentPlanes()
        writeTone(
            into: &hotFromSampleZero,
            channel: center,
            samples: 0..<sourceSampleCount,
            amplitude: 5_000_000,
            frequency: 997.0
        )
        // Silent first source AU, bed enters at the second window AU: the
        // window is half-active, so the 4x128 startup pair must not appear
        // as a lone declaration; the fully silent AU2 keeps the code-0x20
        // silence declaration and the bed-audible AU3/AU4 leave it.
        var hotFromSecondWindowAccessUnit = silentPlanes()
        writeTone(
            into: &hotFromSecondWindowAccessUnit,
            channel: center,
            samples: XLLSyntax.frameSampleCount..<sourceSampleCount,
            amplitude: 5_000_000,
            frequency: 997.0
        )
        // Silent bed with heights active only at the second window AU: the
        // private half of the same half-active window. The fully silent
        // AU2/AU4 keep the code-0x20 silence declaration.
        var heightsAtSecondWindowAccessUnit = silentPlanes()
        writeTone(
            into: &heightsAtSecondWindowAccessUnit,
            channel: leftFrontHeight,
            samples: XLLSyntax.frameSampleCount..<(XLLSyntax.frameSampleCount * 2),
            amplitude: 3_000_000,
            frequency: 641.0
        )

        let scenarios: [(planes: [[Int32]], expected: [HotStartPrivateFrameExpectation])] = [
            (hotFromSampleZero, [
                corePriming, corePriming,
                bedAudibleZeroHeights, bedAudibleZeroHeights, bedAudibleZeroHeights
            ]),
            (hotFromSecondWindowAccessUnit, [
                corePriming, corePriming,
                sourceSilence, bedAudibleZeroHeights, bedAudibleZeroHeights
            ]),
            (heightsAtSecondWindowAccessUnit, [
                corePriming, corePriming, sourceSilence, activeFrame, sourceSilence
            ])
        ]
        for scenario in scenarios {
            guard try verifyHotStartScenario(
                planes: scenario.planes,
                expected: scenario.expected
            ) else {
                return false
            }
        }
        return true
    }

    /// Bed-only programme timeline: mid-stream height dropouts and the
    /// end-of-programme tail. Once the programme has started hot, every
    /// bed-audible height-silent access unit - however late in the stream,
    /// the zero-padded final access unit included - must carry the ordinary
    /// navigated zero-height delivery frame, and every fully silent access
    /// unit must carry the code-0x20 mid-stream silence declaration. Neither
    /// class may ever re-enter the startup or Core-priming grammar
    /// mid-stream or at the tail. This pins the fix for tbh's bed-only tail
    /// (片尾) failing on hardware while height-active regions play.
    private static func verifyTerminalBedOnlyProgrammeTimeline() throws -> Bool {
        let corePriming = HotStartPrivateFrameExpectation(
            byteCount: 48,
            code: 15,
            expectsNavigation: false,
            sideInfoControlCode: nil,
            sha256: corePrimingXLLXFrameSHA256,
            expectsZeroDecodedHeights: true
        )
        let sourceSilence = HotStartPrivateFrameExpectation(
            byteCount: 52,
            code: 16,
            expectsNavigation: false,
            sideInfoControlCode: 0x20,
            sha256: midStreamSilenceXLLXFrameSHA256,
            expectsZeroDecodedHeights: true
        )
        let bedAudibleZeroHeights = HotStartPrivateFrameExpectation(
            byteCount: bedAudibleZeroHeightsXLLXFrameByteCount,
            code: 17,
            expectsNavigation: true,
            sideInfoControlCode: nil,
            sha256: bedAudibleZeroHeightsXLLXFrameSHA256,
            expectsZeroDecodedHeights: true
        )
        let activeFrame = HotStartPrivateFrameExpectation(
            byteCount: nil,
            code: 17,
            expectsNavigation: true,
            sideInfoControlCode: nil,
            sha256: nil,
            expectsZeroDecodedHeights: false
        )

        let center = DTS714Channel.allCases.firstIndex(of: .center)!
        let heights = [
            DTS714Channel.leftFrontHeight, .rightFrontHeight,
            .leftRearHeight, .rightRearHeight
        ].map { DTS714Channel.allCases.firstIndex(of: $0)! }

        func tone(
            into planes: inout [[Int32]],
            channel: Int,
            samples: Range<Int>,
            amplitude: Double,
            frequency: Double
        ) {
            for sample in samples {
                let phase = 2.0 * Double.pi * frequency * Double(sample) / 48_000.0
                planes[channel][sample] = Int32((sin(phase) * amplitude).rounded())
            }
        }
        func silentPlanes(sampleCount: Int) -> [[Int32]] {
            Array(
                repeating: Array(repeating: Int32(0), count: sampleCount),
                count: DTS714Channel.allCases.count
            )
        }

        // Height dropout mid-stream, bed hot to the last sample: the tail
        // must stay on the navigated zero-height class.
        let dropoutSampleCount = XLLSyntax.frameSampleCount * 6
        var heightDropout = silentPlanes(sampleCount: dropoutSampleCount)
        tone(
            into: &heightDropout,
            channel: center,
            samples: 0..<dropoutSampleCount,
            amplitude: 5_000_000,
            frequency: 997.0
        )
        for (heightOrdinal, channel) in heights.enumerated() {
            tone(
                into: &heightDropout,
                channel: channel,
                samples: (XLLSyntax.frameSampleCount * 2)..<(XLLSyntax.frameSampleCount * 4),
                amplitude: 3_000_000,
                frequency: 503.0 + Double(heightOrdinal) * 137.0
            )
        }

        // Bed fades to digital silence before the end: the fully silent
        // trailing access units must use the mid-stream silence declaration,
        // never the startup pair or the priming form.
        var silentTail = silentPlanes(sampleCount: dropoutSampleCount)
        tone(
            into: &silentTail,
            channel: center,
            samples: 0..<(XLLSyntax.frameSampleCount * 3),
            amplitude: 5_000_000,
            frequency: 997.0
        )

        // Bed hot through a partial final access unit: the encoder zero-pads
        // the tail, and the padded access unit is still bed-audible, so it
        // must carry the navigated zero-height class.
        let paddedSampleCount = XLLSyntax.frameSampleCount * 3
            + XLLSyntax.frameSampleCount / 2
        var paddedTail = silentPlanes(sampleCount: paddedSampleCount)
        tone(
            into: &paddedTail,
            channel: center,
            samples: 0..<paddedSampleCount,
            amplitude: 5_000_000,
            frequency: 997.0
        )

        let scenarios: [(planes: [[Int32]], expected: [HotStartPrivateFrameExpectation])] = [
            (heightDropout, [
                corePriming, corePriming,
                bedAudibleZeroHeights, bedAudibleZeroHeights,
                activeFrame, activeFrame,
                bedAudibleZeroHeights, bedAudibleZeroHeights
            ]),
            (silentTail, [
                corePriming, corePriming,
                bedAudibleZeroHeights, bedAudibleZeroHeights, bedAudibleZeroHeights,
                sourceSilence, sourceSilence, sourceSilence
            ]),
            (paddedTail, [
                corePriming, corePriming,
                bedAudibleZeroHeights, bedAudibleZeroHeights,
                bedAudibleZeroHeights, bedAudibleZeroHeights
            ])
        ]
        for scenario in scenarios {
            guard try verifyHotStartScenario(
                planes: scenario.planes,
                expected: scenario.expected
            ) else {
                return false
            }
        }
        return true
    }

    private static func verifyHotStartScenario(
        planes: [[Int32]],
        expected: [HotStartPrivateFrameExpectation]
    ) throws -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-native-dtsx-hot-startup-\(UUID().uuidString)")
        let output = root.appendingPathExtension("dtshd")
        let payload = root.appendingPathExtension("xllx")
        let index = root.appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: payload)
            try? FileManager.default.removeItem(at: index)
        }

        let encoded = try DTSXNativeHDMAEncoder(verificationPolicy: .integrated)
            .encode(source: try DTS714PCMBuffer(planes: planes), frameRate: .fps24)
        try encoded.stream.write(to: output, options: .atomic)
        let publicStream = try XLLPBRStreamReader.read(inputURL: output)
        let publicSegments = try publicStream.frames.map {
            try XLLFrameASTParser.parse($0.frame).segmentCount
        }
        guard publicSegments == Array(repeating: 2, count: expected.count) else {
            return false
        }

        let extraction = try DTSXObjectExtractor.extract(
            inputURL: output,
            payloadOutputURL: payload,
            indexOutputURL: index
        )
        guard extraction.frames.count == expected.count else { return false }
        let payloadBytes = try Data(contentsOf: payload)
        for (record, expectation) in zip(extraction.frames, expected) {
            guard let payloadOffset = record.payloadFileOffset,
                  payloadOffset >= 0,
                  payloadOffset + record.payloadByteCount <= payloadBytes.count else {
                return false
            }
            if let byteCount = expectation.byteCount,
               record.payloadByteCount != byteCount {
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
            if expectation.expectsNavigation {
                guard navigation?.crcIsValid == true else { return false }
            }
            if let controlCode = expectation.sideInfoControlCode {
                guard let header = try ast.parsePredictionHeaderCandidates().first,
                      let sideInfo = try DTSXPrivateNoNavigationZeroSideInfo.parse(
                          ast,
                          prediction: header,
                          segmentCount: 2,
                          segmentSampleCount: 256
                      ),
                      sideInfo.controlCode == controlCode else {
                    return false
                }
            }
            if expectation.expectsZeroDecodedHeights {
                let segmentCount = record.xllSyntax?.segmentCount ?? 0
                guard segmentCount > 0,
                      XLLSyntax.frameSampleCount.isMultiple(of: segmentCount) else {
                    return false
                }
                let decoded = try DTSXPrivateFrameDecoder.decode(
                    ast,
                    segmentCount: segmentCount,
                    segmentSampleCount: XLLSyntax.frameSampleCount / segmentCount
                )
                guard decoded.codedPlanes.allSatisfy({ plane in
                    plane.allSatisfy { $0 == 0 }
                }) else {
                    return false
                }
            }
            if let sha256 = expectation.sha256,
               SHA256Hasher.hash(frame) != sha256 {
                return false
            }
        }
        return true
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
            codingMode: .terminalRice
        )
        guard (0..<session.frameCount).map({
            session.terminalPreferredPublicSegmentCount(at: $0)
        }) == [2, 2, nil, nil, 2] else {
            return false
        }

        // The forced-2 diagnostic must hold, and so must the production free
        // search: the official corpus reaches 4x128 only through the
        // frame-indexed silent-start transition, so an active start must stay
        // on the ordinary 2x256 delivery partition even when no override is
        // present. The regression this gates was real - a compression-cost
        // search that was allowed to discover 4x128 put the first active
        // access unit into a partition the references never pair with active
        // content, and the terminal could not read that first frame.
        for forcedSegmentCount in [Int?.some(2), nil] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("swift-native-dtsx-active-startup-\(UUID().uuidString)")
            let output = root.appendingPathExtension("dtshd")
            defer { try? FileManager.default.removeItem(at: output) }
            let encoded = try DTSXNativeHDMAEncoder(
                verificationPolicy: .none,
                publicXLLForcedSegmentCount: forcedSegmentCount,
                privateXLLXCodingMode: .terminalRice
            ).encode(source: activeSource, frameRate: .fps24)
            try encoded.stream.write(to: output, options: .atomic)
            let publicStream = try XLLPBRStreamReader.read(inputURL: output)
            let publicSegments = try publicStream.frames.map {
                try XLLFrameASTParser.parse($0.frame).segmentCount
            }
            guard publicSegments == [2, 2, 2, 2, 2] else { return false }
            let structural = try DTSXObjectExtractor.verify(inputURL: output)
            guard structural.isStructurallyValid
                && structural.allPrivateFramesMatchPublicSegmentation else {
                return false
            }
        }
        return true
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

    /// tbh-class active start: loud bed and height content from sample zero.
    /// The reference decoder forces lossy recovery on the first XLL frame it
    /// filters, playing `clip23(Core x sqrt(2))` alone on every Core-mapped
    /// channel, so the embedded Core must actually carry the declared
    /// -3.0103 dB DownmixScale fold. A Core without the fold clips the
    /// recovery intermediate on this vector (the "first frame unplayable"
    /// hardware failure) and leaves a level-error residual at every loud
    /// onset; both directions fail this regression.
    private static func verifyHotStartRecoveryWindow() throws -> XLLRecoveryStartupReport {
        let sourceSampleCount = XLLSyntax.frameSampleCount * 3
        // The centre runs at exact full scale: what recovery plays is the
        // *decoded* Core times sqrt(2), and the decoded Core carries codec
        // error on top of the ideal fold, so a full-scale plane clips the
        // recovery intermediate unless the source guard's Core-codec-error
        // recovery reserve holds the Core-mapped values below full scale
        // (the FULLSCALE_C controllable-vector failure, +0.14 dB measured).
        // The other amplitudes keep the 7.1 compatibility bed near
        // -0.3 dBFS (far above the -3.0103 dB recovery headroom) while the
        // hierarchy fold target (Lss + Lsr-with-height) stays inside the
        // signed 24-bit range, keeping the official constant matrix in use.
        let amplitudes: [Double] = [
            6_000_000, 6_000_000, 8_388_607, 6_000_000,
            3_000_000, 3_000_000, 2_000_000, 2_000_000,
            3_000_000, 3_000_000, 3_000_000, 3_000_000
        ]
        // The LFE tone stays inside the Core's decimated LFE passband so the
        // residual measures codec error rather than out-of-band content.
        let frequencies: [Double] = [
            409.0, 523.0, 641.0, 61.0,
            757.0, 881.0, 997.0, 1_103.0,
            1_213.0, 1_327.0, 1_439.0, 1_553.0
        ]
        let planes = (0..<DTS714Channel.allCases.count).map { channel in
            (0..<sourceSampleCount).map { sample -> Int32 in
                let phase = 2.0 * Double.pi * frequencies[channel]
                    * Double(sample) / 48_000.0
                return Int32((sin(phase) * amplitudes[channel]).rounded())
            }
        }
        let hotSource = try DTS714PCMBuffer(planes: planes)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-native-dtsx-hot-recovery-\(UUID().uuidString).dtshd"
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let encoded = try DTSXNativeHDMAEncoder(verificationPolicy: .none)
            .encode(source: hotSource, frameRate: .fps24)
        do {
            try encoded.stream.write(to: output, options: .atomic)
        } catch {
            throw DTSError.io(
                "cannot write hot-start recovery verification stream: \(error.localizedDescription)"
            )
        }
        return try XLLRecoveryStartupVerifier.verify(inputURL: output)
    }

    /// tbh-class hostile start: sparse full-scale transients over a hot bed
    /// with silent startup heights, held across several access units. Without
    /// the perfect-stream bounds this content class produced public XLL Rice
    /// unary quotients past 100 (terminal bounded readers stop at 22) and
    /// forced the silent-start 4x128 partition onto active bed frames - the
    /// exact "first ~10 seconds unplayable, pops at every later transient"
    /// hardware failure. The whole window must satisfy the multi-access-unit
    /// early-programme grammar, not just the first access unit.
    private static func verifyHostileStartEarlyProgramme() throws
        -> DTSXEarlyProgrammeGrammarReport {
        let sourceFrameCount = 8
        let sourceSampleCount = XLLSyntax.frameSampleCount * sourceFrameCount
        var planes = Array(
            repeating: Array(repeating: Int32(0), count: sourceSampleCount),
            count: DTS714Channel.allCases.count
        )
        let left = DTS714Channel.allCases.firstIndex(of: .left)!
        let center = DTS714Channel.allCases.firstIndex(of: .center)!
        let leftRearSurround = DTS714Channel.allCases.firstIndex(of: .leftRearSurround)!
        let heights = [
            DTS714Channel.leftFrontHeight, .rightFrontHeight,
            .leftRearHeight, .rightRearHeight
        ].map { DTS714Channel.allCases.firstIndex(of: $0)! }

        // Sparse transients are the heavy-tailed residual class: a mostly
        // quiet segment drives the mean-magnitude Rice parameter down, and
        // the lone loud sample must then still fit the bounded unary reader.
        for frame in 0..<sourceFrameCount {
            let offset = frame * XLLSyntax.frameSampleCount
            planes[left][offset] = frame.isMultiple(of: 2) ? 4_000_000 : -4_000_000
            if frame > 0 {
                planes[leftRearSurround][offset - 1] = 4_000_000
                planes[leftRearSurround][offset] = -4_000_000
            }
        }
        // A hot bed from sample zero keeps the start active (the tbh shape)
        // while the startup heights stay silent, so the private session still
        // nominates the silent-start 4x128 form that delivery must refuse.
        for sample in 0..<sourceSampleCount {
            let phase = 2.0 * Double.pi * 997.0 * Double(sample) / 48_000.0
            planes[center][sample] = Int32((sin(phase) * 5_000_000.0).rounded())
        }
        // Heights enter late and hot so the private XLL-X path also codes
        // heavy-tailed residuals inside the audited window.
        for (heightOrdinal, channel) in heights.enumerated() {
            let frequency = 503.0 + Double(heightOrdinal) * 137.0
            for sample in (XLLSyntax.frameSampleCount * 2)..<sourceSampleCount {
                let phase = 2.0 * Double.pi * frequency * Double(sample) / 48_000.0
                planes[channel][sample] = Int32((sin(phase) * 3_000_000.0).rounded())
            }
        }

        let source = try DTS714PCMBuffer(planes: planes)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-native-dtsx-early-programme-\(UUID().uuidString).dtshd"
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let encoded = try DTSXNativeHDMAEncoder(verificationPolicy: .integrated)
            .encode(source: source, frameRate: .fps24)
        do {
            try encoded.stream.write(to: output, options: .atomic)
        } catch {
            throw DTSError.io(
                "cannot write early-programme verification stream: \(error.localizedDescription)"
            )
        }
        return try DTSXEarlyProgrammeGrammarVerifier.verify(inputURL: output)
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
