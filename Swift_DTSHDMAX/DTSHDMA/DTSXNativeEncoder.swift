import Foundation

/// Product-level guard for the public 7.1 Core/XLL compatibility bed.
///
/// DTS:X delivery uses the reference 6+2 Core-residual XLL hierarchy. The
/// public XLL channel masks and downmix matrix must agree with the embedded
/// Core, rather than substituting a full-primary experimental layout. PCM
/// statistics enforce signed 24-bit range and frame-boundary continuity.
public struct DTSXXLLCompatibilitySafetyReport: Sendable, Equatable, Codable {
    public let coreAssociationPolicy: XLLCoreAssociationPolicy
    public let xllFrameCount: Int
    public let dtsxAssetDescriptorFrameCount: Int
    public let primaryResidualChannelMasks: [UInt64]
    public let secondaryResidualChannelMasks: [UInt64]
    public let storageBitDepths: [Int]
    public let maximumAbsoluteInputSample: Int64
    public let maximumAbsoluteDecodedSample: Int64
    public let inputFullScaleSampleCount: Int
    public let decodedFullScaleSampleCount: Int
    public let inputSamplesOutsideSigned24Bit: Int
    public let decodedSamplesOutsideSigned24Bit: Int
    public let frameBoundaryDeltaMismatchCount: Int
    public let masksMatchDTSXResidualHierarchy: Bool
    public let masksMatchSelectedCoreAssociation: Bool
    public let allDTSXAssetDescriptorsMatchPrivateFrames: Bool
    public let isCompatible: Bool
}

public struct DTSXNativeEncodingReport: Sendable, Equatable, Codable {
    public let streamKind: DTSHDMAStreamKind
    public let frameRate: DTSFrameRate
    public let publicXLLCoreAssociationPolicy: XLLCoreAssociationPolicy
    public let publicXLLCodingMode: XLLCodingMode
    public let publicXLLForcedSegmentCount: Int?
    public let privateXLLXCodingMode: DTSXPrivateCodingMode
    public let sourceGuardPolicy: DTSXSourceGuardPolicy
    /// Encoder-boundary height-onset continuity conditioning of the 7.1.4
    /// source (programme-head ramp plus silence-to-active onset slew on the
    /// four height planes). Present whenever ``sourceGuardPolicy`` is
    /// ``DTSXSourceGuardPolicy/delivery``; `isTransparent` is true when no
    /// height onset needed conditioning and the planes passed through
    /// bit-exact.
    public let sourceOnsetConditioning: DTS714HeightOnsetConditioningReport?
    /// Encoder-boundary composite-headroom conditioning of the 7.1.4 source.
    /// Present whenever ``sourceGuardPolicy`` is ``DTSXSourceGuardPolicy/delivery``;
    /// `isTransparent` is true when the source never overloaded any
    /// downstream contract and passed through bit-exact.
    public let sourceRenderGuard: DTS714RenderGuardReport?
    public let sourceSampleCount: Int
    public let encodedSampleCount: Int
    public let accessUnitCount: Int
    public let streamByteCount: Int
    public let streamSHA256: String
    public let privateEncoding: DTSXPrivateStreamEncodingReport
    /// Hard clips the legacy Q15 height fold applied while building the
    /// public 7.1 compatibility bed from the 7.1.4 source. Renders produced
    /// by ``DTS714Renderer`` are guarded and always report zero; a nonzero
    /// count means externally supplied 7.1.4 planes overload the fold and the
    /// delivered bed is irreversibly cracked at exactly those samples.
    public let compatibilityBedFoldHardClipSampleCount: Int
    public let compatibilityBedFoldMaximumExcess: Int64
    public let compatibilityBedFoldFirstHardClipSample: Int?
    /// Populated only when the caller explicitly requests integrated
    /// encode/decode verification. Production encoding deliberately leaves
    /// these fields nil so a complete program is not decoded a second time
    /// as part of the encode operation.
    public let compatibilityBedComparison: PCMPaddedComparison?
    public let compatibilitySafety: DTSXXLLCompatibilitySafetyReport?
    public let isNativePrivateEncoding: Bool
    public let isInternallyBitExact: Bool
}

public struct DTSXNativeEncodedResult: Sendable {
    public let stream: Data
    public let report: DTSXNativeEncodingReport
}

/// Controls the deliberately expensive, whole-stream validation pass.
///
/// Encoding itself always performs the local syntax checks needed to build a
/// valid stream. ``integrated`` is reserved for explicit QC/test callers; the
/// default keeps production encoding on the forward-only path.
public enum DTSXNativeVerificationPolicy: String, Sendable, Codable {
    case none
    case integrated
}

/// Controls the encoder-boundary conditioning of the twelve 7.1.4 source
/// planes.
///
/// The rendered-Atmos path is already guarded inside ``DTS714Renderer``, but
/// stems directories, wave sets, and direct plane callers historically
/// reached the encoder unguarded: hot content then hard-clips the legacy Q15
/// compatibility fold (irreversible bed cracks the lossless layers deliver
/// as clicks) and forces per-frame hierarchy declarations - coefficient
/// escapes from the constant matrix code 473 and residual-mask flips - that
/// the reference corpus never exercises, for exactly as long as the content
/// stays hot. ``delivery`` bounds every source against the downstream
/// composite contracts before any layer encodes it; the guard is bit-exact
/// passthrough whenever nothing overloads, so double-guarding rendered
/// content is transparent.
public enum DTSXSourceGuardPolicy: String, Sendable, Codable {
    /// Delivery default: run the shared boundary pipeline
    /// (``DTS714DeliverySourceConditioner``) on the source planes -
    /// height-onset continuity conditioning followed by
    /// ``DTS714RenderGuard``.
    case delivery
    /// Differential-study bypass: hand the encoder the raw planes and allow
    /// the historical out-of-contract syntax, so negative controls can keep
    /// demonstrating the defects the delivery pipeline exists to prevent.
    /// Never a delivery configuration.
    case bypassForDifferential = "bypass-for-differential"
}

public enum DTSXNativeFileVerificationScope: String, Sendable, Codable {
    /// File structure and the native private XLL-X PCM loop were verified.
    /// The public compatibility bed was not decoded during production encode.
    case structureAndPrivateXLLXPCM = "structure-and-private-xllx-pcm"
    /// File structure plus public XLL and private XLL-X PCM loops were verified.
    case integratedPublicAndPrivatePCM = "integrated-public-and-private-pcm"
}

public struct DTSXNativeFileEncodingReport: Sendable, Equatable, Codable {
    public let outputPath: String
    public let encoding: DTSXNativeEncodingReport
    public let structuralVerification: DTSXStreamVerificationReport
    public let verificationScope: DTSXNativeFileVerificationScope
    public let publicCompatibilityBedPCMVerified: Bool
    public let privateXLLXPCMVerified: Bool
    public let structuralVerificationPassed: Bool
    /// True only when every check declared by ``verificationScope`` passed.
    public let isVerified: Bool
}

/// Pure-Swift 7.1.4 PCM to Core+ExSS/XLL+XLL-X encoder path.
///
/// The public compatibility bed is encoded by the existing native HDMA codec.
/// The four height planes are encoded independently by
/// ``DTSXPrivateFrameEncoder`` and inserted into the size-accounted, aligned
/// private region of each XLL frame. No reference stream bytes are read or
/// replayed by this path.
public struct DTSXNativeHDMAEncoder: Sendable {
    public let verificationPolicy: DTSXNativeVerificationPolicy
    public let publicXLLCoreAssociationPolicy: XLLCoreAssociationPolicy
    public let publicXLLCodingMode: XLLCodingMode
    /// Test-only public XLL segmentation override. Nil preserves the
    /// production per-frame search.
    public let publicXLLForcedSegmentCount: Int?
    public let privateXLLXCodingMode: DTSXPrivateCodingMode
    public let sourceGuardPolicy: DTSXSourceGuardPolicy

    public init(
        verificationPolicy: DTSXNativeVerificationPolicy = .none,
        publicXLLCoreAssociationPolicy: XLLCoreAssociationPolicy = .coreResidual,
        // The public XLL residual path stays free of locally selected
        // prediction/decorrelation and entropy-state transitions, but its
        // active segments now use ordinary Rice with explicit per-channel
        // parameters: every observed official active delivery segment is
        // Rice-coded, while the previous all-linear form is a grammar the
        // corpus never exercises. With the Core carrying the declared
        // downmix fold, residuals shrink to Core-codec-error size and an
        // all-linear stream spends its life in small uncertified linear
        // widths - the hardware presented that as noise-gate-like dropouts
        // on quiet content and an unreadable first active frame.
        publicXLLCodingMode: XLLCodingMode = .terminalOfficialRice,
        publicXLLForcedSegmentCount: Int? = nil,
        // Hardware accepted the Branch-0 Straight-Rice controls while Linear
        // controls were not recognized and Branch-2 controls clicked. The
        // delivery default stays on fixed-order-zero Branch-0 Rice, but with
        // the perfect-stream parameter selection: official mean-magnitude
        // ABIT bounded to the corpus-maximum unary quotient of 22. The
        // previous exact-minimum ABIT of ``terminalRice`` emitted unary runs
        // past that bound on heavy-tailed height residuals, which terminal
        // bounded readers misparse into full-scale pops.
        privateXLLXCodingMode: DTSXPrivateCodingMode = .terminalRiceOfficial,
        sourceGuardPolicy: DTSXSourceGuardPolicy = .delivery
    ) {
        self.verificationPolicy = verificationPolicy
        self.publicXLLCoreAssociationPolicy = publicXLLCoreAssociationPolicy
        self.publicXLLCodingMode = publicXLLCodingMode
        self.publicXLLForcedSegmentCount = publicXLLForcedSegmentCount
        self.privateXLLXCodingMode = privateXLLXCodingMode
        self.sourceGuardPolicy = sourceGuardPolicy
    }

    public func encode(
        source: DTS714PCMBuffer,
        frameRate: DTSFrameRate,
        maximumSourceFrameCount: Int? = nil,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> DTSXNativeEncodedResult {
        let progressTotal = 1_000
        progress?(0, progressTotal)
        let (effectiveSource, sourceOnset, sourceGuard) = try conditionedSource(try truncated(
            source,
            maximumSourceFrameCount: maximumSourceFrameCount
        ))
        let privateSession = try DTSXPrivateStreamEncodingSession(
            source: effectiveSource,
            codingMode: privateXLLXCodingMode
        )
        let (compatibilityBed, foldDiagnostics) =
            try DTS714CompatibilityBedRenderer.renderWithDiagnostics(effectiveSource)
        progress?(100, progressTotal)
        let publicEncoder = DTSHDMAEncoder(configuration: DTSHDMAEncoderConfiguration(
            format: compatibilityBed.format,
            profile: .dtsHDMA,
            deterministic: true,
            tailPolicy: .zeroPad,
            xllCodingMode: publicXLLCodingMode,
            officialHierarchyGrammarEnforced: sourceGuardPolicy == .delivery,
            forcedXLLSegmentCount: publicXLLForcedSegmentCount
        ))
        let coupledStream = try publicEncoder.encode(
            compatibilityBed,
            privateXLLXSession: privateSession,
            coreAssociationPolicy: publicXLLCoreAssociationPolicy,
            progress: { completed, total in
                progress?(100 + (750 * completed / max(1, total)), progressTotal)
            }
        )
        let elementaryStream = coupledStream.stream
        let privateStream = coupledStream.privateStream
        let stream = try DTSHDFileContainer.wrapHDMA(
            elementaryStream: elementaryStream,
            format: compatibilityBed.format,
            sourceSampleCount: effectiveSource.sampleCount,
            frameRate: frameRate,
            streamKind: .dtsxHDMA
        )
        progress?(900, progressTotal)
        let bedComparison: PCMPaddedComparison?
        let compatibilitySafety: DTSXXLLCompatibilitySafetyReport?
        if verificationPolicy == .integrated {
            let decodedBed = try DTSHDMADecoder().decode(stream)
            bedComparison = try PCMComparator.compareWithZeroPadding(
                expected: compatibilityBed,
                paddedActual: decodedBed
            )
            compatibilitySafety = try makeCompatibilitySafetyReport(
                elementaryStream: elementaryStream,
                input: compatibilityBed,
                decoded: decodedBed,
                coreAssociationPolicy: publicXLLCoreAssociationPolicy
            )
        } else {
            bedComparison = nil
            compatibilitySafety = nil
        }
        let encodedSampleCount = privateStream.report.encodedSourceSampleCount
        let report = DTSXNativeEncodingReport(
            streamKind: .dtsxHDMA,
            frameRate: frameRate,
            publicXLLCoreAssociationPolicy: publicXLLCoreAssociationPolicy,
            publicXLLCodingMode: publicXLLCodingMode,
            publicXLLForcedSegmentCount: publicXLLForcedSegmentCount,
            privateXLLXCodingMode: privateXLLXCodingMode,
            sourceGuardPolicy: sourceGuardPolicy,
            sourceOnsetConditioning: sourceOnset,
            sourceRenderGuard: sourceGuard,
            sourceSampleCount: effectiveSource.sampleCount,
            encodedSampleCount: encodedSampleCount,
            accessUnitCount: privateStream.frames.count,
            streamByteCount: stream.count,
            streamSHA256: SHA256Hasher.hash(stream),
            privateEncoding: privateStream.report,
            compatibilityBedFoldHardClipSampleCount: foldDiagnostics.hardClipCount,
            compatibilityBedFoldMaximumExcess: foldDiagnostics.channels.map {
                max($0.maximumPositiveExcess, $0.maximumNegativeExcess)
            }.max() ?? 0,
            compatibilityBedFoldFirstHardClipSample: foldDiagnostics.channels
                .compactMap(\.firstHardClipSample).min(),
            compatibilityBedComparison: bedComparison,
            compatibilitySafety: compatibilitySafety,
            isNativePrivateEncoding: true,
            // ``isInternallyBitExact`` describes the local XLL-X frame
            // encoder/decoder gate. Whole-stream PCM exactness is intentionally
            // reported only by an explicit integrated verification pass.
            isInternallyBitExact: privateStream.report.isBitExact
                && (verificationPolicy == .none
                    || (bedComparison?.isBitExact == true
                        && compatibilitySafety?.isCompatible == true))
        )
        guard report.isInternallyBitExact else {
            throw DTSError.malformed(
                "native DTS:X Core/XLL/XLL-X encode-decode round-trip is not sample-exact"
            )
        }
        progress?(progressTotal, progressTotal)
        return DTSXNativeEncodedResult(stream: stream, report: report)
    }

    public func encode(
        source: DTS714PCMBuffer,
        to outputURL: URL,
        frameRate: DTSFrameRate,
        maximumSourceFrameCount: Int? = nil,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> DTSXNativeFileEncodingReport {
        let output = outputURL.standardizedFileURL
        guard output.pathExtension.lowercased() == "dtshd" else {
            throw DTSError.invalidArgument("native DTS:X output must use the .dtshd extension")
        }
        let progressTotal = 1_000
        progress?(0, progressTotal)
        let (effectiveSource, sourceOnset, sourceGuard) = try conditionedSource(try truncated(
            source,
            maximumSourceFrameCount: maximumSourceFrameCount
        ))
        let privateSession = try DTSXPrivateStreamEncodingSession(
            source: effectiveSource,
            codingMode: privateXLLXCodingMode
        )
        let (compatibilityBed, foldDiagnostics) =
            try DTS714CompatibilityBedRenderer.renderWithDiagnostics(effectiveSource)
        let writer = try DTSHDFileContainer.StreamingWriter(
            outputURL: output,
            format: compatibilityBed.format,
            sourceSampleCount: effectiveSource.sampleCount,
            frameRate: frameRate,
            streamKind: .dtsxHDMA
        )
        var verified = false
        defer {
            if !verified {
                writer.cancel()
                try? FileManager.default.removeItem(at: output)
            }
        }
        progress?(100, progressTotal)
        let privateStream: DTSXPrivateEncodedStream
        do {
            privateStream = try DTSHDMAEncoder(configuration: DTSHDMAEncoderConfiguration(
                format: compatibilityBed.format,
                profile: .dtsHDMA,
                deterministic: true,
                tailPolicy: .zeroPad,
                xllCodingMode: publicXLLCodingMode,
                officialHierarchyGrammarEnforced: sourceGuardPolicy == .delivery,
                forcedXLLSegmentCount: publicXLLForcedSegmentCount
            )).encode(
                compatibilityBed,
                privateXLLXSession: privateSession,
                coreAssociationPolicy: publicXLLCoreAssociationPolicy,
                writingAccessUnitsTo: { accessUnit in
                    try writer.append(accessUnit: accessUnit)
                },
                progress: { completed, total in
                    progress?(100 + (750 * completed / max(1, total)), progressTotal)
                }
            )
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
        progress?(900, 1_000)
        let bedComparison: PCMPaddedComparison?
        let compatibilitySafety: DTSXXLLCompatibilitySafetyReport?
        if verificationPolicy == .integrated {
            let stream: Data
            do {
                stream = try Data(contentsOf: output, options: .mappedIfSafe)
            } catch {
                throw DTSError.io("cannot read progressive DTS:X output \(output.path): \(error.localizedDescription)")
            }
            let decodedBed = try DTSHDMADecoder().decode(stream)
            bedComparison = try PCMComparator.compareWithZeroPadding(
                expected: compatibilityBed,
                paddedActual: decodedBed
            )
            compatibilitySafety = try makeCompatibilitySafetyReport(
                elementaryStream: try DTSHDFileContainer.elementaryStream(in: stream),
                input: compatibilityBed,
                decoded: decodedBed,
                coreAssociationPolicy: publicXLLCoreAssociationPolicy
            )
        } else {
            bedComparison = nil
            compatibilitySafety = nil
        }
        let streamByteCount: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            guard let byteCount = attributes[.size] as? NSNumber else {
                throw DTSError.io("cannot determine \(output.path) size")
            }
            streamByteCount = byteCount.intValue
        } catch let error as DTSError {
            throw error
        } catch {
            throw DTSError.io("cannot determine \(output.path) size: \(error.localizedDescription)")
        }
        let encoding = DTSXNativeEncodingReport(
            streamKind: .dtsxHDMA,
            frameRate: frameRate,
            publicXLLCoreAssociationPolicy: publicXLLCoreAssociationPolicy,
            publicXLLCodingMode: publicXLLCodingMode,
            publicXLLForcedSegmentCount: publicXLLForcedSegmentCount,
            privateXLLXCodingMode: privateXLLXCodingMode,
            sourceGuardPolicy: sourceGuardPolicy,
            sourceOnsetConditioning: sourceOnset,
            sourceRenderGuard: sourceGuard,
            sourceSampleCount: effectiveSource.sampleCount,
            encodedSampleCount: privateStream.report.encodedSourceSampleCount,
            accessUnitCount: privateStream.frames.count,
            streamByteCount: streamByteCount,
            streamSHA256: try SHA256Hasher.hash(fileAt: output),
            privateEncoding: privateStream.report,
            compatibilityBedFoldHardClipSampleCount: foldDiagnostics.hardClipCount,
            compatibilityBedFoldMaximumExcess: foldDiagnostics.channels.map {
                max($0.maximumPositiveExcess, $0.maximumNegativeExcess)
            }.max() ?? 0,
            compatibilityBedFoldFirstHardClipSample: foldDiagnostics.channels
                .compactMap(\.firstHardClipSample).min(),
            compatibilityBedComparison: bedComparison,
            compatibilitySafety: compatibilitySafety,
            isNativePrivateEncoding: true,
            isInternallyBitExact: privateStream.report.isBitExact
                && (verificationPolicy == .none
                    || (bedComparison?.isBitExact == true
                        && compatibilitySafety?.isCompatible == true))
        )
        guard encoding.isInternallyBitExact else {
            throw DTSError.malformed(
                "native DTS:X Core/XLL/XLL-X encode-decode round-trip is not sample-exact"
            )
        }
        let structural = try DTSXObjectExtractor.verify(inputURL: output)
        progress?(980, 1_000)
        let publicCompatibilityBedPCMVerified =
            encoding.compatibilityBedComparison?.isBitExact == true
            && encoding.compatibilitySafety?.isCompatible == true
        let privateXLLXPCMVerified = encoding.privateEncoding.isBitExact
        let structuralVerificationPassed = structural.isStructurallyValid
            && structural.privateFrameCount == encoding.accessUnitCount
        let verificationScope: DTSXNativeFileVerificationScope = verificationPolicy == .integrated
            ? .integratedPublicAndPrivatePCM
            : .structureAndPrivateXLLXPCM
        let report = DTSXNativeFileEncodingReport(
            outputPath: output.path,
            encoding: encoding,
            structuralVerification: structural,
            verificationScope: verificationScope,
            publicCompatibilityBedPCMVerified: publicCompatibilityBedPCMVerified,
            privateXLLXPCMVerified: privateXLLXPCMVerified,
            structuralVerificationPassed: structuralVerificationPassed,
            isVerified: encoding.isInternallyBitExact
                && privateXLLXPCMVerified
                && structuralVerificationPassed
                && (verificationPolicy == .none || publicCompatibilityBedPCMVerified)
        )
        guard report.isVerified else {
            throw DTSError.malformed("native DTS:X file failed structural verification")
        }
        verified = true
        progress?(1_000, 1_000)
        return report
    }

    /// Conditions the twelve source planes through the shared delivery
    /// boundary pipeline before any layer encodes them: height-onset
    /// continuity first (programme-head ramp plus silence-to-active onset
    /// slew on the four height planes - the object-onset pop carriers), then
    /// the downstream-headroom composite guard (plane range, legacy Q15
    /// height fold, Core-residual recovery composite). The rendered-Atmos
    /// path is already composite-guarded inside ``DTS714Renderer``;
    /// re-applying either stage to compliant content is bit-exact
    /// passthrough, so this single boundary covers stems directories, wave
    /// sets, and direct plane callers. Closed-loop verifiers reproduce the
    /// same pipeline through ``DTS714DeliverySourceConditioner``.
    private func conditionedSource(
        _ source: DTS714PCMBuffer
    ) throws -> (
        source: DTS714PCMBuffer,
        onsetReport: DTS714HeightOnsetConditioningReport?,
        guardReport: DTS714RenderGuardReport?
    ) {
        guard sourceGuardPolicy == .delivery else { return (source, nil, nil) }
        var planes = source.planes
        let reports = DTS714DeliverySourceConditioner.condition(planes: &planes)
        guard reports.renderGuard.isHeadroomSafe else {
            throw DTSError.malformed(
                "DTS:X source guard could not close every downstream headroom constraint"
            )
        }
        if reports.onset.isTransparent && reports.renderGuard.isTransparent {
            return (source, reports.onset, reports.renderGuard)
        }
        return (try DTS714PCMBuffer(planes: planes), reports.onset, reports.renderGuard)
    }

    private func truncated(
        _ source: DTS714PCMBuffer,
        maximumSourceFrameCount: Int?
    ) throws -> DTS714PCMBuffer {
        guard let maximumSourceFrameCount else { return source }
        guard maximumSourceFrameCount > 0 else {
            throw DTSError.invalidArgument("maximum DTS:X source frame count must be positive")
        }
        let (maximumSampleCount, overflow) = maximumSourceFrameCount.multipliedReportingOverflow(
            by: DTSXPrivateFrameEncoder.frameSampleCount
        )
        guard !overflow else {
            throw DTSError.valueOutOfRange(
                field: "maximum DTS:X source frame count",
                value: String(maximumSourceFrameCount)
            )
        }
        let count = min(
            source.sampleCount,
            maximumSampleCount
        )
        return try DTS714PCMBuffer(
            planes: source.planes.map { Array($0.prefix(count)) }
        )
    }

    private func makeCompatibilitySafetyReport(
        elementaryStream: Data,
        input: PCMBuffer,
        decoded: PCMBuffer,
        coreAssociationPolicy: XLLCoreAssociationPolicy
    ) throws -> DTSXXLLCompatibilitySafetyReport {
        guard input.format == decoded.format, decoded.sampleCount >= input.sampleCount else {
            throw DTSError.malformed("DTS:X compatibility-bed safety timelines do not align")
        }

        let accessUnits = try DTSStreamInspector().inspect(
            data: elementaryStream,
            maximumAccessUnits: Int.max
        )
        var primaryMasks = Set<UInt64>()
        var secondaryMasks = Set<UInt64>()
        var storageBitDepths = Set<Int>()
        var xllFrameCount = 0
        var dtsxAssetDescriptorFrameCount = 0
        var allDTSXAssetDescriptorsMatchPrivateFrames = true
        for accessUnit in accessUnits {
            guard let exssByteCount = accessUnit.exssByteCount else {
                throw DTSError.malformed("DTS:X compatibility access unit has no ExSS component")
            }
            let coreByteCount = accessUnit.coreByteCount.map { ($0 + 3) & ~3 } ?? 0
            let start = Int(accessUnit.byteOffset) + coreByteCount
            let end = start + exssByteCount
            guard start >= 0, end <= elementaryStream.count else {
                throw DTSError.truncated(
                    field: "DTS:X compatibility ExSS component",
                    bitOffset: max(0, start) * 8
                )
            }
            let exss = try ExSSParser().parse(frame: elementaryStream.subdata(in: start..<end))
            if let signal = exss.info.dtsxAssetDescriptorSignal {
                dtsxAssetDescriptorFrameCount += 1
                allDTSXAssetDescriptorsMatchPrivateFrames =
                    allDTSXAssetDescriptorsMatchPrivateFrames
                        && exss.info.headerByteCount == 40
                        && exss.info.assetDescriptorByteCount == 23
                        && signal.xllXByteOffset + signal.xllXFrameByteCount
                            == exss.info.xllByteCount
            } else {
                allDTSXAssetDescriptorsMatchPrivateFrames = false
            }
            let xll = try XLLFrameASTParser.parse(exss.xllData)
            guard xll.channelSets.count == 2,
                  xll.channelSets[0].channelCount == 6,
                  xll.channelSets[1].channelCount == 2 else {
                throw DTSError.malformed("DTS:X compatibility XLL is not the recovered 6+2 hierarchy")
            }
            primaryMasks.insert(xll.channelSets[0].residualChannelMask)
            secondaryMasks.insert(xll.channelSets[1].residualChannelMask)
            storageBitDepths.formUnion(xll.channelSets.map(\.storageBitDepth))
            xllFrameCount += 1
        }

        var maximumInput: Int64 = 0
        var maximumDecoded: Int64 = 0
        var inputFullScale = 0
        var decodedFullScale = 0
        var inputOutside = 0
        var decodedOutside = 0
        var boundaryMismatchCount = 0
        for channel in input.planes.indices {
            let expected = input.planes[channel]
            let actual = decoded.planes[channel]
            for sample in expected.indices {
                let expectedValue = Int64(expected[sample])
                let actualValue = Int64(actual[sample])
                maximumInput = max(maximumInput, abs(expectedValue))
                maximumDecoded = max(maximumDecoded, abs(actualValue))
                if expectedValue == -8_388_608 || expectedValue == 8_388_607 {
                    inputFullScale += 1
                }
                if actualValue == -8_388_608 || actualValue == 8_388_607 {
                    decodedFullScale += 1
                }
                if expectedValue < -8_388_608 || expectedValue > 8_388_607 {
                    inputOutside += 1
                }
                if actualValue < -8_388_608 || actualValue > 8_388_607 {
                    decodedOutside += 1
                }
            }
            var boundary = XLLSyntax.frameSampleCount
            while boundary < expected.count {
                let expectedDelta = Int64(expected[boundary]) - Int64(expected[boundary - 1])
                let actualDelta = Int64(actual[boundary]) - Int64(actual[boundary - 1])
                if expectedDelta != actualDelta { boundaryMismatchCount += 1 }
                boundary += XLLSyntax.frameSampleCount
            }
        }

        let sortedPrimaryMasks = primaryMasks.sorted()
        let sortedSecondaryMasks = secondaryMasks.sorted()
        let sortedStorageBitDepths = storageBitDepths.sorted()
        let masksMatchDTSXResidualHierarchy = sortedPrimaryMasks.contains(0x00)
            && sortedPrimaryMasks.allSatisfy { $0 <= 0x3f }
            && sortedSecondaryMasks == [0x03]
        let masksMatchSelectedCoreAssociation: Bool = switch coreAssociationPolicy {
        case .fullPrimaryChannels:
            sortedPrimaryMasks == [0x3f] && sortedSecondaryMasks == [0x03]
        case .coreResidual:
            masksMatchDTSXResidualHierarchy
        }
        let isCompatible = xllFrameCount == accessUnits.count
            && xllFrameCount > 0
            && dtsxAssetDescriptorFrameCount == xllFrameCount
            && allDTSXAssetDescriptorsMatchPrivateFrames
            && masksMatchSelectedCoreAssociation
            && sortedStorageBitDepths == [24]
            && maximumInput <= 8_388_608
            && maximumDecoded <= 8_388_608
            && inputFullScale == decodedFullScale
            && inputOutside == 0
            && decodedOutside == 0
            && boundaryMismatchCount == 0
        return DTSXXLLCompatibilitySafetyReport(
            coreAssociationPolicy: coreAssociationPolicy,
            xllFrameCount: xllFrameCount,
            dtsxAssetDescriptorFrameCount: dtsxAssetDescriptorFrameCount,
            primaryResidualChannelMasks: sortedPrimaryMasks,
            secondaryResidualChannelMasks: sortedSecondaryMasks,
            storageBitDepths: sortedStorageBitDepths,
            maximumAbsoluteInputSample: maximumInput,
            maximumAbsoluteDecodedSample: maximumDecoded,
            inputFullScaleSampleCount: inputFullScale,
            decodedFullScaleSampleCount: decodedFullScale,
            inputSamplesOutsideSigned24Bit: inputOutside,
            decodedSamplesOutsideSigned24Bit: decodedOutside,
            frameBoundaryDeltaMismatchCount: boundaryMismatchCount,
            masksMatchDTSXResidualHierarchy: masksMatchDTSXResidualHierarchy,
            masksMatchSelectedCoreAssociation: masksMatchSelectedCoreAssociation,
            allDTSXAssetDescriptorsMatchPrivateFrames:
                allDTSXAssetDescriptorsMatchPrivateFrames,
            isCompatible: isCompatible
        )
    }
}
