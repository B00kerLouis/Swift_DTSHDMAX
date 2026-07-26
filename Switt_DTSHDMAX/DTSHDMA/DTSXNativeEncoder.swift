import Foundation

/// Product-level guard for the public 7.1 Core/XLL compatibility bed.
///
/// Native product mode encodes the six-channel primary set in full (`0x3f`),
/// keeping lossless output independent of implementation-specific Core PCM.
/// The reference residual form (`0x00`) remains an explicit research policy.
/// The two-channel rear set is full XLL (`0x03`) in both forms. PCM statistics
/// additionally enforce signed 24-bit range and frame-boundary continuity.
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
    public let sourceSampleCount: Int
    public let encodedSampleCount: Int
    public let accessUnitCount: Int
    public let streamByteCount: Int
    public let streamSHA256: String
    public let privateEncoding: DTSXPrivateStreamEncodingReport
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

    public init(
        verificationPolicy: DTSXNativeVerificationPolicy = .none,
        publicXLLCoreAssociationPolicy: XLLCoreAssociationPolicy = .coreResidual
    ) {
        self.verificationPolicy = verificationPolicy
        self.publicXLLCoreAssociationPolicy = publicXLLCoreAssociationPolicy
    }

    public func encode(
        source: DTS714PCMBuffer,
        frameRate: DTSFrameRate,
        maximumSourceFrameCount: Int? = nil,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> DTSXNativeEncodedResult {
        let progressTotal = 1_000
        progress?(0, progressTotal)
        let effectiveSource = try truncated(
            source,
            maximumSourceFrameCount: maximumSourceFrameCount
        )
        let privateSession = try DTSXPrivateStreamEncodingSession(
            source: effectiveSource
        )
        let compatibilityBed = try DTS714CompatibilityBedRenderer.render(effectiveSource)
        progress?(100, progressTotal)
        let publicEncoder = DTSHDMAEncoder(configuration: DTSHDMAEncoderConfiguration(
            format: compatibilityBed.format,
            profile: .dtsHDMA,
            deterministic: true,
            tailPolicy: .zeroPad
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
            sourceSampleCount: effectiveSource.sampleCount,
            encodedSampleCount: encodedSampleCount,
            accessUnitCount: privateStream.frames.count,
            streamByteCount: stream.count,
            streamSHA256: SHA256Hasher.hash(stream),
            privateEncoding: privateStream.report,
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
        let result = try encode(
            source: source,
            frameRate: frameRate,
            maximumSourceFrameCount: maximumSourceFrameCount,
            progress: { completed, total in
                progress?(850 * completed / max(1, total), 1_000)
            }
        )
        do {
            try result.stream.write(to: output, options: .atomic)
        } catch {
            throw DTSError.io("cannot write \(output.path): \(error.localizedDescription)")
        }
        progress?(900, 1_000)
        var verified = false
        defer {
            if !verified { try? FileManager.default.removeItem(at: output) }
        }
        let structural = try DTSXObjectExtractor.verify(inputURL: output)
        progress?(980, 1_000)
        let publicCompatibilityBedPCMVerified =
            result.report.compatibilityBedComparison?.isBitExact == true
            && result.report.compatibilitySafety?.isCompatible == true
        let privateXLLXPCMVerified = result.report.privateEncoding.isBitExact
        let structuralVerificationPassed = structural.isStructurallyValid
            && structural.privateFrameCount == result.report.accessUnitCount
        let verificationScope: DTSXNativeFileVerificationScope = verificationPolicy == .integrated
            ? .integratedPublicAndPrivatePCM
            : .structureAndPrivateXLLXPCM
        let report = DTSXNativeFileEncodingReport(
            outputPath: output.path,
            encoding: result.report,
            structuralVerification: structural,
            verificationScope: verificationScope,
            publicCompatibilityBedPCMVerified: publicCompatibilityBedPCMVerified,
            privateXLLXPCMVerified: privateXLLXPCMVerified,
            structuralVerificationPassed: structuralVerificationPassed,
            isVerified: result.report.isInternallyBitExact
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
