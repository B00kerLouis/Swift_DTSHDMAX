import Foundation

/// Everything a terminal latches when it first synchronizes on a DTS:X
/// stream. Segmentation is deliberately not part of this signature: the
/// startup partition is allowed to follow the observed silent-start grammar,
/// while the channel-set and entropy declarations are not allowed to change
/// at any point in the programme.
public struct DTSXStreamConfigurationSignature: Sendable, Equatable, Hashable, Codable {
    public let channelSetCount: Int
    public let channelCounts: [Int]
    public let speakerMasks: [UInt64?]
    public let residualChannelMasks: [UInt64]
    public let hierarchicalFlags: [Bool]
    public let embeddedDownmixFlags: [Bool]
    public let decorrelationEnabledFlags: [Bool]
    public let channelOrderIsIdentity: Bool
    public let sharedEntropyParameterSegmentCount: Int
    public let entropyStateReuseSegmentCount: Int
    public let initialDecodingDelayFrames: Int
}

public struct DTSXStreamAccessUnitDeclaration: Sendable, Equatable, Codable {
    public let accessUnitIndex: Int
    public let isPriming: Bool
    public let isStartupDelivery: Bool
    public let signature: DTSXStreamConfigurationSignature
    public let segmentCount: Int
    public let segmentSampleCount: Int
    public let hasPrivateFrame: Bool
    public let privateCRCsValid: Bool
    public let routingPermutation: [Int]
    public let routingBranchCode: Int
    public let matchesDeliverySignature: Bool
}

public struct DTSXStreamStartupSeamReport: Sendable, Equatable, Codable {
    public let sourceSampleCount: Int
    public let accessUnitCount: Int
    public let primingAccessUnitCount: Int
    public let deliverySignature: DTSXStreamConfigurationSignature
    public let accessUnits: [DTSXStreamAccessUnitDeclaration]
    public let primingDeclarationsMatchDelivery: Bool
    public let allDeclarationsMatchDelivery: Bool
    public let distinctConfigurationSignatureCount: Int
    public let allPrivateFrameCRCsValid: Bool
    public let routingIsStable: Bool
    public let startupSegmentCounts: [Int]
    public let midStreamSegmentCounts: [Int]
    public let midStreamSegmentationIsStable: Bool
    public let bedSeamStepCount: Int
    public let maximumBedSeamStep: Int64
    public let maximumBedInteriorStep: Int64
    public let bedSeamsAreContinuous: Bool
    public let heightVerification: DTSXPrivateHeightVerificationReport
    public let heightSeamsAreContinuous: Bool
    public let bedIsBitExact: Bool
    public let isVerified: Bool
}

/// Closed-loop verification of the two symptoms a terminal reports at the
/// edges of a DTS:X programme: the first access units being skipped, and
/// mid-programme clicks on the channels whose content is changing.
///
/// Both symptoms share a mechanism that no PCM comparison can observe — a
/// structural *declaration* that changes part-way through the stream. A
/// decoder that latches its channel-set configuration and segment navigation
/// when it first synchronizes has to reconfigure when a later access unit
/// declares something else, and a reconfiguration is audible. The encode is
/// lossless, so a bit-exact round trip stays green through exactly the
/// grammar changes that make hardware misbehave.
///
/// This verifier therefore reads the declarations directly. It drives the
/// production encoder with a continuous, wide-dynamic-range 7.1.4 vector
/// chosen to sweep the public encoder's segmentation cost across its
/// decision boundary several times, then asserts that
///
/// * every access unit — including the two Core-priming units a terminal
///   sees first — declares one identical channel-set configuration,
/// * the mid-stream public XLL partition never changes,
/// * every private XLL-X frame carries a valid header, prediction and
///   navigation CRC with one stable routing word, and
/// * no decoded frame seam introduces a step the interior of the frame does
///   not already contain.
public enum DTSXStreamStartupSeamVerifier {
    private static let sourceFrameCount = 20

    /// Channels the terminal reported clicking on, driven hardest here.
    private static let reportedPopChannels: Set<DTS714Channel> = [
        .left,
        .leftRearSurround,
        .rightRearSurround,
        .leftFrontHeight,
        .leftRearHeight,
        .rightRearHeight
    ]

    public static func verify() throws -> DTSXStreamStartupSeamReport {
        let sampleCount = XLLSyntax.frameSampleCount * sourceFrameCount
        let source = try makeSegmentationSweepVector(sampleCount: sampleCount)

        let encoder = DTSXNativeHDMAEncoder(verificationPolicy: .integrated)
        let encoded = try encoder.encode(source: source, frameRate: .fps24)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swift-dtsx-startup-seam-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw DTSError.io(
                "cannot create startup/seam directory: \(error.localizedDescription)"
            )
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let streamURL = temporaryDirectory.appendingPathComponent("program.dtshd")
        do {
            try encoded.stream.write(to: streamURL, options: .atomic)
        } catch {
            throw DTSError.io(
                "cannot write startup/seam stream: \(error.localizedDescription)"
            )
        }

        let primingAccessUnitCount = XLLSyntax.coreCompatiblePrimingSampleCount
            / XLLSyntax.frameSampleCount
        let inspection = try DTSXTerminalFrameInspector.inspect(
            inputURL: streamURL,
            accessUnitCount: encoded.report.accessUnitCount
        )
        let entropyDeclarations = try readEntropyDeclarations(inputURL: streamURL)
        guard entropyDeclarations.count == inspection.accessUnits.count else {
            throw DTSError.malformed(
                "DTS:X stream does not carry one XLL frame per access unit"
            )
        }
        guard inspection.accessUnits.count > primingAccessUnitCount + 2 else {
            throw DTSError.malformed(
                "DTS:X startup/seam vector is too short to observe a mid-stream partition"
            )
        }

        var declarations: [DTSXStreamAccessUnitDeclaration] = []
        declarations.reserveCapacity(inspection.accessUnits.count)
        var signatures: [DTSXStreamConfigurationSignature] = []
        signatures.reserveCapacity(inspection.accessUnits.count)
        for (index, accessUnit) in inspection.accessUnits.enumerated() {
            signatures.append(makeSignature(
                accessUnit: accessUnit,
                entropy: entropyDeclarations[index]
            ))
        }
        // The delivery signature is the one a terminal must be able to keep
        // for the whole programme, so it is taken from the first ordinary
        // source access unit rather than from the priming pair.
        let deliverySignature = signatures[primingAccessUnitCount]

        for (index, accessUnit) in inspection.accessUnits.enumerated() {
            let privateFrame = accessUnit.privateFrame
            declarations.append(DTSXStreamAccessUnitDeclaration(
                accessUnitIndex: accessUnit.accessUnitIndex,
                isPriming: index < primingAccessUnitCount,
                isStartupDelivery: index >= primingAccessUnitCount
                    && index < primingAccessUnitCount + 2,
                signature: signatures[index],
                segmentCount: accessUnit.xllSegmentCount,
                segmentSampleCount: accessUnit.xllSegmentSampleCount,
                hasPrivateFrame: privateFrame != nil,
                privateCRCsValid: privateFrame.map {
                    $0.headerCRCIsValid
                        && $0.predictionCRCIsValid
                        && ($0.navigationCRCIsValid ?? true)
                } ?? false,
                routingPermutation: privateFrame?.routingPermutation ?? [],
                routingBranchCode: privateFrame?.routingBranchCode ?? -1,
                matchesDeliverySignature: signatures[index] == deliverySignature
            ))
        }

        let primingDeclarationsMatchDelivery = declarations
            .filter(\.isPriming)
            .allSatisfy(\.matchesDeliverySignature)
        let allDeclarationsMatchDelivery = declarations
            .allSatisfy(\.matchesDeliverySignature)
        let allPrivateFrameCRCsValid = declarations
            .allSatisfy { $0.hasPrivateFrame && $0.privateCRCsValid }
        let routingIsStable = declarations.allSatisfy {
            $0.routingPermutation == declarations[0].routingPermutation
                && $0.routingBranchCode == declarations[0].routingBranchCode
        }

        let startupSegmentCounts = declarations
            .prefix(primingAccessUnitCount + 2)
            .map(\.segmentCount)
        let midStream = declarations.dropFirst(primingAccessUnitCount + 2)
        let midStreamSegmentCounts = midStream.map(\.segmentCount)
        let midStreamSegmentationIsStable = midStream.allSatisfy {
            $0.segmentCount == midStream.first!.segmentCount
                && $0.segmentSampleCount == midStream.first!.segmentSampleCount
        }

        let decodedBed = try DTSHDMADecoder().decode(encoded.stream)
        let seam = bedSeamAnalysis(planes: decodedBed.planes, sampleCount: sampleCount)
        let heightVerification = try DTSXPrivateHeightVerifier.verify(
            inputURL: streamURL,
            source: source
        )
        let heightSeamsAreContinuous = heightVerification.frameBoundaryDeltaMismatchCount == 0
            && heightVerification.segmentBoundaryDeltaMismatchCount == 0
        let bedIsBitExact = encoded.report.compatibilityBedComparison?.isBitExact ?? false

        let verified = encoded.report.isInternallyBitExact
            && bedIsBitExact
            && allDeclarationsMatchDelivery
            && primingDeclarationsMatchDelivery
            && allPrivateFrameCRCsValid
            && routingIsStable
            && midStreamSegmentationIsStable
            && seam.isContinuous
            && heightSeamsAreContinuous
            && heightVerification.isBitExact
        return DTSXStreamStartupSeamReport(
            sourceSampleCount: sampleCount,
            accessUnitCount: inspection.accessUnits.count,
            primingAccessUnitCount: primingAccessUnitCount,
            deliverySignature: deliverySignature,
            accessUnits: declarations,
            primingDeclarationsMatchDelivery: primingDeclarationsMatchDelivery,
            allDeclarationsMatchDelivery: allDeclarationsMatchDelivery,
            distinctConfigurationSignatureCount: Set(signatures).count,
            allPrivateFrameCRCsValid: allPrivateFrameCRCsValid,
            routingIsStable: routingIsStable,
            startupSegmentCounts: Array(startupSegmentCounts),
            midStreamSegmentCounts: Array(midStreamSegmentCounts),
            midStreamSegmentationIsStable: midStreamSegmentationIsStable,
            bedSeamStepCount: seam.seamCount,
            maximumBedSeamStep: seam.maximumSeamStep,
            maximumBedInteriorStep: seam.maximumInteriorStep,
            bedSeamsAreContinuous: seam.isContinuous,
            heightVerification: heightVerification,
            heightSeamsAreContinuous: heightSeamsAreContinuous,
            bedIsBitExact: bedIsBitExact,
            isVerified: verified
        )
    }

    /// A continuous 7.1.4 vector that repeatedly gates from digital silence
    /// up to near full scale and back.
    ///
    /// Sample-to-sample continuity is preserved everywhere, including across
    /// every 512-sample frame boundary, so any step the decoder introduces at
    /// a seam is attributable to the codec rather than to the source. The
    /// gating is what matters structurally: a resting frame codes more
    /// cheaply as 2x256 and an active one as 4x128, so a per-frame
    /// byte-count search walks back and forth across its decision boundary —
    /// the condition under which the declared partition used to flip
    /// part-way through a programme, on exactly the access units where
    /// content was changing.
    private static func makeSegmentationSweepVector(
        sampleCount: Int
    ) throws -> DTS714PCMBuffer {
        let channels = DTS714Channel.allCases
        var planes = Array(
            repeating: Array(repeating: Int32(0), count: sampleCount),
            count: channels.count
        )
        for (index, channel) in channels.enumerated() {
            let peak = reportedPopChannels.contains(channel) ? 3_400_000.0 : 900_000.0
            let frequency = 110.0 + Double(index) * 37.0
            let phase = Double(index) * 0.37
            for sample in 0..<sampleCount {
                let time = Double(sample) / Double(DTS714PCMBuffer.sampleRate)
                let position = Double(sample) / Double(sampleCount)
                // A gated envelope: whole frames rest at digital silence and
                // whole frames run near full scale, joined by smooth ramps.
                let gate = cos(2.0 * Double.pi * 3.0 * position)
                let level = gate > 0 ? gate * gate * gate : 0
                let value = peak * level
                    * sin(2.0 * Double.pi * frequency * time + phase)
                planes[index][sample] = Int32(value.rounded())
            }
        }
        return try DTS714PCMBuffer(planes: planes)
    }

    private static func makeSignature(
        accessUnit: DTSXTerminalAccessUnitInspection,
        entropy: EntropyDeclaration
    ) -> DTSXStreamConfigurationSignature {
        DTSXStreamConfigurationSignature(
            channelSetCount: accessUnit.channelSets.count,
            channelCounts: accessUnit.channelSets.map(\.channelCount),
            speakerMasks: accessUnit.channelSets.map(\.speakerMask),
            residualChannelMasks: accessUnit.channelSets.map(\.residualChannelMask),
            hierarchicalFlags: accessUnit.channelSets.map(\.hierarchical),
            embeddedDownmixFlags: accessUnit.channelSets.map(\.hasEmbeddedDownmix),
            decorrelationEnabledFlags: entropy.decorrelationEnabledFlags,
            channelOrderIsIdentity: entropy.channelOrderIsIdentity,
            sharedEntropyParameterSegmentCount: entropy.commonParameterSegmentCount,
            entropyStateReuseSegmentCount: entropy.stateReuseSegmentCount,
            initialDecodingDelayFrames: accessUnit.xllInitialDecodingDelayFrames
        )
    }

    private struct EntropyDeclaration {
        let decorrelationEnabledFlags: [Bool]
        let channelOrderIsIdentity: Bool
        let commonParameterSegmentCount: Int
        let stateReuseSegmentCount: Int
    }

    /// The channel-set headers carry the decorrelation and channel-order
    /// declarations, and the frame carries the shared-entropy declarations.
    /// Neither is visible in the ExSS/navigation layer, so the public XLL
    /// frames are decoded here in one pass.
    private static func readEntropyDeclarations(
        inputURL: URL
    ) throws -> [EntropyDeclaration] {
        let stream = try XLLPBRStreamReader.read(inputURL: inputURL)
        let decoder = XLLDecoder()
        return try stream.frames.map { frame in
            let decoded = try decoder.decodeChannelSets(frame: frame.frame)
            return EntropyDeclaration(
                decorrelationEnabledFlags: decoded.channelSets.map(\.decorrelationEnabled),
                channelOrderIsIdentity: decoded.channelSets.allSatisfy {
                    $0.originalOrder == Array(0..<$0.originalOrder.count)
                },
                commonParameterSegmentCount: decoded.entropyCommonParameterSegmentCount,
                stateReuseSegmentCount: decoded.entropyStateReuseSegmentCount
            )
        }
    }

    private struct BedSeamAnalysis {
        let seamCount: Int
        let maximumSeamStep: Int64
        let maximumInteriorStep: Int64
        var isContinuous: Bool { maximumSeamStep <= maximumInteriorStep }
    }

    /// The source is continuous, so the largest step across a frame boundary
    /// must not exceed the largest step the frame interiors already contain.
    /// A decoder-state discontinuity at a seam — the audible symptom — breaks
    /// that relation even when the surrounding samples are correct.
    private static func bedSeamAnalysis(
        planes: [[Int32]],
        sampleCount: Int
    ) -> BedSeamAnalysis {
        var seamCount = 0
        var maximumSeamStep: Int64 = 0
        var maximumInteriorStep: Int64 = 0
        for plane in planes {
            let limit = min(sampleCount, plane.count)
            guard limit > 1 else { continue }
            for sample in 1..<limit {
                let step = abs(Int64(plane[sample]) - Int64(plane[sample - 1]))
                if sample.isMultiple(of: XLLSyntax.frameSampleCount) {
                    seamCount += 1
                    maximumSeamStep = max(maximumSeamStep, step)
                } else {
                    maximumInteriorStep = max(maximumInteriorStep, step)
                }
            }
        }
        return BedSeamAnalysis(
            seamCount: seamCount,
            maximumSeamStep: maximumSeamStep,
            maximumInteriorStep: maximumInteriorStep
        )
    }
}
