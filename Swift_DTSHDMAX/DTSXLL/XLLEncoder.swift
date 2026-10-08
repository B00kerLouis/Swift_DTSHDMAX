import Foundation

public enum XLLCoreAssociationPolicy: String, Sendable, Equatable, Codable {
    /// Stores every primary XLL channel in full so lossless reconstruction does
    /// not depend on another decoder reproducing the local Core PCM bit-exactly.
    case fullPrimaryChannels
    /// Core-residual hierarchy used by the DTS:X references. A channel falls
    /// back to full coding only when its residual is not representable at the
    /// stream's signed 24-bit storage depth.
    case coreResidual
}

/// Restricts the emitted public XLL syntax when validating terminal
/// interoperability. The conservative form keeps the mandatory channel-set
/// and residual declarations but removes locally selected prediction,
/// decorrelation, Rice/Hybrid entropy, shared allocation, and state reuse from
/// the terminal-facing DTS:X path.
public enum XLLCodingMode: Sendable, Equatable, Codable {
    case research
    case terminalConservative
    /// Fixed-order-zero, Linear terminal gate that preserves the reference
    /// channel-order declaration while keeping entropy parameters explicit.
    /// This isolates the ordering syntax from prediction and entropy state.
    case terminalOrderedConservative
    /// Reproduces the terminal-clean legacy public-XLL control: reference
    /// channel order, fixed-order-zero Linear entropy, shared parameters/state,
    /// and the full 2/4/8-segment cost search. This remains a diagnostic mode.
    case terminalLegacyLinear
    /// Terminal-facing prediction and Rice coding with the recovered fixed
    /// channel order. Dynamic pairwise decorrelation and Hybrid Rice remain
    /// confined to the research profile.
    case terminalPredictive
    /// Experimental fixed-segmentation Rice syntax. It is retained for
    /// reference-stream experiments and is not a product default.
    case terminalRice
    /// Official-corpus delivery grammar for the DTS:X Core-residual path:
    /// active segments use ordinary Rice with explicit per-channel
    /// parameters (the recovered reference streams code every observed
    /// active segment as Rice even when a linear width would also fit),
    /// all-zero segments keep the compact zero-width linear form, and the
    /// free partition search is pinned to the ordinary 2x256 delivery form
    /// (the references reach 4x128 only through the frame-indexed
    /// silent-start transition, which arrives as a forced segment count).
    /// Prediction, decorrelation, hybrid Rice, shared allocation and
    /// state reuse remain disabled exactly as in ``terminalConservative``.
    ///
    /// This exists because the previous all-linear delivery emitted a
    /// grammar the official corpus never exercises for active content; the
    /// same terminal family already failed to recognize Linear controls in
    /// the private XLL-X layer, and once the Core carries the declared
    /// downmix fold the residuals shrink into small linear widths on all
    /// quiet content, which presented as noise-gate-like dropouts and an
    /// unreadable first active frame on hardware.
    case terminalOfficialRice
}

struct XLLEncoder: Sendable {
    /// Longest Rice unary quotient observed anywhere in the recovered
    /// official corpus (public XLL and private XLL-X share the terminal
    /// bounded-reader family). A minimum-bit Rice parameter minimizes the
    /// average payload but leaves heavy-tailed residual peaks - Core codec
    /// error at loud onsets, object transients - with unary runs far past
    /// this bound, which a terminal bounded reader misparses into
    /// full-scale pops and sustained early-programme desync on active
    /// starts. Delivery Rice therefore raises the parameter until every
    /// emitted quotient fits the official bound; raising ABIT cannot alter
    /// the decoded residual, it only trades remainder bits for a shorter
    /// quotient.
    static let terminalMaximumUnaryQuotient: UInt64 = 22

    private enum EntropyMode: Equatable {
        case linear(width: Int)
        case rice(parameter: Int)
        case hybridRice(parameter: Int, linearWidth: Int, isolatedSampleOffsets: [Int])
    }

    private struct HybridRicePlan {
        let linearWidth: Int
        let bitCount: Int
    }

    private struct HybridRiceAnalysis {
        let riceBitCount: Int
        let hybridPlan: HybridRicePlan?
    }

    private struct ChannelSetInput {
        let planes: [[Int32]]
        let speakerMask: UInt64
        let residualChannelMask: UInt64
        let primary: Bool
        let hierarchical: Bool
        let downmixScaleCodes: [Int]
        let downmixCoefficientCodes: [Int]
        let decorrelationEnabled: Bool
        let originalOrder: [Int]
        let decorrelationCoefficients: [Int32]
        let adaptivePredictionOrders: [Int]
        let adaptiveReflectionCoefficientIndices: [[Int32]]
        let fixedPredictionOrders: [Int]
        // LSB planes stay in decoded/original channel order even when the MSB
        // entropy planes use a different pairwise-decorrelation order.
        let scalableLSBWidths: [Int]
        let scalableLSBPlanes: [[Int32]]
    }

    private let codingMode: XLLCodingMode
    /// DTS:X delivery invariant: the Core-residual hierarchy must keep the
    /// official constant matrix (coefficient code 473) and the all-zero
    /// primary residual mask on every frame, exactly as the reference corpus
    /// does. The encoder-boundary source guard makes both hold by
    /// construction, so under enforcement an escape is reported as a
    /// diagnosable encode defect instead of being serialized as syntax a
    /// terminal has never been shown to parse.
    private let enforcesOfficialHierarchyGrammar: Bool

    init(
        codingMode: XLLCodingMode = .research,
        enforcesOfficialHierarchyGrammar: Bool = false
    ) {
        self.codingMode = codingMode
        self.enforcesOfficialHierarchyGrammar = enforcesOfficialHierarchyGrammar
    }

    func encode(
        frame pcm: PCMBuffer,
        useSevenOneHierarchy: Bool = false,
        coreReconstruction: PCMBuffer? = nil,
        coreAssociationPolicy: XLLCoreAssociationPolicy = .fullPrimaryChannels,
        privateExtension: Data = Data(),
        privateExtensionProvider: ((XLLSegmentationPlan) throws -> Data)? = nil,
        forcedSegmentCount: Int? = nil
    ) throws -> XLLEncodedFrame {
        guard pcm.sampleCount == XLLSyntax.frameSampleCount else {
            throw DTSError.unsupported(
                "XLL frame must contain exactly \(XLLSyntax.frameSampleCount) samples per channel"
            )
        }
        guard pcm.format.sampleRate == 48_000, pcm.format.bitDepth == 24 else {
            throw DTSError.unsupported("XLL encoder supports only 48 kHz, 24-bit integer PCM")
        }
        guard privateExtension.isEmpty || privateExtensionProvider == nil else {
            throw DTSError.invalidArgument(
                "XLL private extension data and provider are mutually exclusive"
            )
        }

        let channelSets = try makeChannelSets(
            pcm: pcm,
            useSevenOneHierarchy: useSevenOneHierarchy,
            coreReconstruction: coreReconstruction,
            coreAssociationPolicy: coreAssociationPolicy
        )
        guard channelSets.allSatisfy({ channelSet in
            channelSet.planes.allSatisfy { plane in
                plane.allSatisfy { (-8_388_608...8_388_607).contains(Int($0)) }
            }
        }) else {
            throw DTSError.valueOutOfRange(
                field: "XLL coded sample",
                value: "outside declared signed 24-bit storage"
            )
        }
        let segmentationCandidates: [(count: Int, samples: Int)]
        if let forcedSegmentCount {
            guard [2, 4, 8].contains(forcedSegmentCount) else {
                throw DTSError.invalidArgument(
                    "XLL forced segment count must be 2, 4, or 8"
                )
            }
            segmentationCandidates = [
                (count: forcedSegmentCount,
                 samples: XLLSyntax.frameSampleCount / forcedSegmentCount)
            ]
        } else {
            switch codingMode {
            case .research:
                segmentationCandidates = [
                    (count: 2, samples: 256),
                    (count: 4, samples: 128),
                    (count: 8, samples: 64)
                ]
            case .terminalConservative:
                // Official DTS:X uses both 2x256 and 4x128 partitions, including
                // the four-segment compact form for the first silent source frame.
                // Both forms remain independently parameterized below; transform
                // and entropy-state features remain disabled for terminal output.
                segmentationCandidates = [
                    (count: 2, samples: 256),
                    (count: 4, samples: 128)
                ]
            case .terminalOrderedConservative:
                segmentationCandidates = [
                    (count: 2, samples: 256),
                    (count: 4, samples: 128)
                ]
            case .terminalLegacyLinear:
                segmentationCandidates = [
                    (count: 2, samples: 256),
                    (count: 4, samples: 128),
                    (count: 8, samples: 64)
                ]
            case .terminalPredictive:
                segmentationCandidates = [
                    (count: 2, samples: 256),
                    (count: 4, samples: 128)
                ]
            case .terminalRice:
                segmentationCandidates = [(count: 2, samples: 256)]
            case .terminalOfficialRice:
                // The official corpus uses 4x128 only around the frame-indexed
                // silent-start transition, which reaches this encoder through
                // ``forcedSegmentCount``. Every freely searched delivery frame
                // in the references is 2x256, so the compression-cost search
                // must not be allowed to discover the other partitions.
                segmentationCandidates = [(count: 2, samples: 256)]
            }
        }
        // Modes are selected independently for every channel.  The previous
        // implementation forced one Rice/linear allocation over all channels;
        // that is legal, but produces unnecessarily large XLL segments and
        // puts avoidable pressure on a hardware decoder's extension buffer.
        var modes: [[[EntropyMode]]] = []
        var segments: [[Data]] = []
        var segmentCount = 0
        var segmentSampleCount = 0
        var bestSegmentationByteCount = Int.max
        for candidate in segmentationCandidates {
            let candidateModes = channelSets.map {
                selectEntropyModes(
                    dtsPlanes: $0.planes,
                    adaptivePredictionOrders: $0.adaptivePredictionOrders,
                    segmentCount: candidate.count,
                    segmentSampleCount: candidate.samples
                )
            }
            var candidateSegments = Array(
                repeating: Array(repeating: Data(), count: channelSets.count),
                count: candidate.count
            )
            for segment in 0..<candidate.count {
                for channelSet in channelSets.indices {
                    candidateSegments[segment][channelSet] = try encodeSegment(
                        index: segment,
                        segmentSampleCount: candidate.samples,
                        dtsPlanes: channelSets[channelSet].planes,
                        modes: candidateModes[channelSet][segment],
                        previousModes: segment > 0 ? candidateModes[channelSet][segment - 1] : nil,
                        adaptivePredictionOrders: channelSets[channelSet].adaptivePredictionOrders,
                        scalableLSBWidths: channelSets[channelSet].scalableLSBWidths,
                        scalableLSBPlanes: channelSets[channelSet].scalableLSBPlanes
                    )
                }
            }
            let maximumSegmentByteCount = candidateSegments
                .flatMap { $0 }
                .map(\.count)
                .max() ?? 0
            let requiredSegmentBits = requiredUnsignedBitCount(
                maximumValue: max(0, maximumSegmentByteCount - 1)
            )
            if requiredSegmentBits <= 13 || candidate.count == 8 {
                let segmentSizeBitCount = max(7, requiredSegmentBits)
                let navigationByteCount = (
                    candidate.count * channelSets.count * segmentSizeBitCount + 7
                ) / 8 + 2
                let candidateByteCount = candidateSegments
                    .flatMap { $0 }
                    .reduce(0) { $0 + $1.count }
                    + navigationByteCount
                if candidateByteCount < bestSegmentationByteCount {
                    bestSegmentationByteCount = candidateByteCount
                    modes = candidateModes
                    segments = candidateSegments
                    segmentCount = candidate.count
                    segmentSampleCount = candidate.samples
                }
            }
        }
        guard !modes.isEmpty, segmentCount * segmentSampleCount == XLLSyntax.frameSampleCount else {
            throw DTSError.malformed("XLL segmentation search did not close")
        }
        let allSegments = segments.flatMap { $0 }
        guard allSegments.allSatisfy({ $0.count < (1 << XLLSyntax.segmentSizeBitCount) }) else {
            throw DTSError.valueOutOfRange(
                field: "XLL segment size",
                value: String(allSegments.map(\.count).max() ?? 0)
            )
        }
        var segmentSizeBitCount = max(
            7,
            requiredUnsignedBitCount(maximumValue: (allSegments.map(\.count).max() ?? 1) - 1)
        )

        let scalableLSBs = useSevenOneHierarchy
        var navigation = try encodeNavigation(
            segmentByteCounts: segments.map { $0.map(\.count) },
            segmentSizeBitCount: segmentSizeBitCount
        )
        var segmentationPlan = try XLLSegmentationPlan(
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            segmentSizeBitCount: segmentSizeBitCount,
            navigationByteCount: navigation.count,
            segmentEntropyByteCounts: segments.map { $0.map(\.count) }
        )
        let resolvedPrivateExtension = try privateExtensionProvider?(segmentationPlan)
            ?? privateExtension
        try validatePrivateExtension(resolvedPrivateExtension)
        if !resolvedPrivateExtension.isEmpty {
            let privateAST = try DTSXPrivateFrameAST.parse(resolvedPrivateExtension[...])
            var privateNavigation = try? privateAST.parseNavigation(segmentCount: segmentCount)
            if privateNavigation == nil {
                let decoded = try DTSXPrivateFrameDecoder.decode(
                    privateAST,
                    segmentCount: segmentCount,
                    segmentSampleCount: segmentSampleCount
                )
                if decoded.noNavigationZeroSideInfo == nil {
                    privateNavigation = try? privateAST.parseNavigation(
                        segmentCount: segmentCount,
                        matching: decoded
                    )
                }
                guard privateNavigation != nil
                        || decoded.codedPlanes.allSatisfy({ $0.allSatisfy({ $0 == 0 }) }) else {
                    throw DTSError.malformed("active XLL-X frame has no qualified navigation")
                }
            }
            if let privateNavigation {
                let expectedWidth = max(8, segmentSizeBitCount)
                guard privateNavigation.bitWidth >= expectedWidth else {
                    throw DTSError.malformed(
                        "XLL-X NAVI width \(privateNavigation.bitWidth) is smaller than "
                            + "the enclosing XLL width \(expectedWidth)"
                    )
                }
                // The private provider encodes once, using the larger of its
                // segment requirement and the provisional public width. Finalize
                // the public header/NAVI/LSB sizes with that shared width before
                // computing any frame offsets or sizes. Inferring a private
                // width locally can round-trip while real playback reads the
                // wrong segment boundaries and produces full-scale height PCM.
                if privateNavigation.bitWidth > expectedWidth {
                    segmentSizeBitCount = privateNavigation.bitWidth
                    guard segmentSizeBitCount <= XLLSyntax.segmentSizeBitCount else {
                        throw DTSError.valueOutOfRange(
                            field: "shared XLL/XLL-X navigation width",
                            value: String(segmentSizeBitCount)
                        )
                    }
                    navigation = try encodeNavigation(
                        segmentByteCounts: segments.map { $0.map(\.count) },
                        segmentSizeBitCount: segmentSizeBitCount
                    )
                    segmentationPlan = try XLLSegmentationPlan(
                        segmentCount: segmentCount,
                        segmentSampleCount: segmentSampleCount,
                        segmentSizeBitCount: segmentSizeBitCount,
                        navigationByteCount: navigation.count,
                        segmentEntropyByteCounts: segments.map { $0.map(\.count) }
                    )
                }
                _ = try privateAST.parseNavigation(
                    segmentCount: segmentCount,
                    sharedSegmentSizeBitCount: segmentSizeBitCount
                )
            }
        }
        let channelHeaders = try channelSets.map {
            try encodeChannelSetHeader(
                input: $0,
                channelMaskBitCount: pcm.format.layout.xllSpeakerMaskBitCount,
                segmentSizeBitCount: segmentSizeBitCount,
                segmentSampleCount: segmentSampleCount,
                scalableLSBs: scalableLSBs
            )
        }
        var frameSizeBitCount = 7
        var frameByteCount = 0
        while true {
            let commonHeaderByteCount = try encodeCommonHeader(
                frameByteCount: 1,
                frameSizeBitCount: frameSizeBitCount,
                segmentSizeBitCount: segmentSizeBitCount,
                segmentCount: segmentCount,
                segmentSampleCount: segmentSampleCount,
                channelMaskBitCount: pcm.format.layout.xllSpeakerMaskBitCount,
                channelSetCount: channelSets.count,
                scalableLSBs: scalableLSBs
            ).count
            let channelHeaderByteCount = channelHeaders.reduce(0) { $0 + $1.count }
            let segmentByteCount = allSegments.reduce(0) { $0 + $1.count }
            let unalignedPublicFrameByteCount = commonHeaderByteCount
                + channelHeaderByteCount
                + navigation.count
                + segmentByteCount
            let privateDataStart = (unalignedPublicFrameByteCount + 3) & ~3
            frameByteCount = privateDataStart + resolvedPrivateExtension.count
            let required = max(7, requiredUnsignedBitCount(maximumValue: frameByteCount - 1))
            guard required <= XLLSyntax.frameSizeBitCount else {
                throw DTSError.valueOutOfRange(
                    field: "XLL frame-size bit count",
                    value: String(required)
                )
            }
            if required == frameSizeBitCount { break }
            frameSizeBitCount = required
        }
        let commonHeader = try encodeCommonHeader(
            frameByteCount: frameByteCount,
            frameSizeBitCount: frameSizeBitCount,
            segmentSizeBitCount: segmentSizeBitCount,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            channelMaskBitCount: pcm.format.layout.xllSpeakerMaskBitCount,
            channelSetCount: channelSets.count,
            scalableLSBs: scalableLSBs
        )

        var frame = BitWriter(reservingCapacity: frameByteCount)
        try frame.write(bytes: commonHeader, field: "xll.commonHeader")
        for (index, header) in channelHeaders.enumerated() {
            try frame.write(bytes: header, field: "xll.channelSetHeader[\(index)]")
        }
        try frame.write(bytes: navigation, field: "xll.navigation")
        for segment in 0..<segmentCount {
            for channelSet in channelSets.indices {
                try frame.write(
                    bytes: segments[segment][channelSet],
                    field: "xll.segment[\(segment)].channelSet[\(channelSet)]"
                )
            }
        }
        try frame.alignTo(byteMultiple: 4)
        if !resolvedPrivateExtension.isEmpty {
            try frame.write(bytes: resolvedPrivateExtension, field: "xll.privateExtension")
        }
        guard frame.byteCount == frameByteCount else {
            throw DTSError.malformed("XLL frame size calculation did not close")
        }

        let info = XLLFrameInfo(
            byteCount: frameByteCount,
            sampleCount: XLLSyntax.frameSampleCount,
            segmentCount: segmentCount,
            segmentByteCounts: allSegments.map(\.count),
            format: pcm.format,
            segmentationPlan: segmentationPlan
        )
        return XLLEncodedFrame(data: frame.data(), info: info)
    }

    private func validatePrivateExtension(_ privateExtension: Data) throws {
        guard !privateExtension.isEmpty else { return }
        guard privateExtension.count.isMultiple(of: 4),
              privateExtension.count >= 4,
              privateExtension[0] == 0x02,
              privateExtension[1] == 0x00,
              privateExtension[2] == 0x08,
              privateExtension[3] == 0x50 else {
            throw DTSError.malformed(
                "XLL private extension must be one aligned XLL-X frame"
            )
        }
        _ = try DTSXPrivateFrameAST.parse(privateExtension[...])
    }

    private func makeChannelSets(
        pcm: PCMBuffer,
        useSevenOneHierarchy: Bool,
        coreReconstruction: PCMBuffer?,
        coreAssociationPolicy: XLLCoreAssociationPolicy
    ) throws -> [ChannelSetInput] {
        if useSevenOneHierarchy {
            guard pcm.format.layout == .sevenOne else {
                throw DTSError.invalidArgument("the two-channel-set XLL hierarchy requires 7.1 PCM")
            }
            guard let coreReconstruction,
                  coreReconstruction.format.sampleRate == pcm.format.sampleRate,
                  coreReconstruction.format.bitDepth == pcm.format.bitDepth,
                  coreReconstruction.format.layout == .fiveOneSide,
                  coreReconstruction.sampleCount == pcm.sampleCount else {
                throw DTSError.invalidArgument(
                    "the two-channel-set Core residual requires one aligned 5.1 Core reconstruction frame"
                )
            }

            // A full-channel DTS:X delivery must not carry the 7.1-to-5.1
            // hierarchy matrix.  That matrix is meaningful only when primary
            // channels are reconstructed from Core; retaining it beside a full
            // primary set leaves hardware free to apply the rear contribution
            // twice.  Keep the two-set layout, but encode the eight speaker
            // signals directly and omit downmix side information entirely.
            if coreAssociationPolicy == .fullPrimaryChannels {
                return applyingPrediction(to: directSevenOneChannelSets(pcm: pcm))
            }

            // The recovered 7.1 syntax uses a 6+2 hierarchy. The Core carries
            // an equal-power 7.1-to-5.1 fold, while the hierarchical matrix
            // reconstructs the original side/rear split. This form is reserved
            // for the explicit Core-residual research policy below.
            let scaleCode = 473
            let zeroCoefficientCode = 256
            let surroundCoefficientCode = 473
            let inverseScale = try XLLSyntax.inverseDownmixScaleQ16(code: scaleCode)
            let coreOrder = [2, 0, 1, 3, 4, 5]
            let selectedLeftCoefficient = try selectHierarchyCoefficientCode(
                base: pcm.planes[6],
                rear: pcm.planes[4],
                core: coreReconstruction.planes[4],
                inverseScale: inverseScale,
                defaultCode: surroundCoefficientCode,
                coreAssociationPolicy: coreAssociationPolicy
            )
            let selectedRightCoefficient = try selectHierarchyCoefficientCode(
                base: pcm.planes[7],
                rear: pcm.planes[5],
                core: coreReconstruction.planes[5],
                inverseScale: inverseScale,
                defaultCode: surroundCoefficientCode,
                coreAssociationPolicy: coreAssociationPolicy
            )
            if enforcesOfficialHierarchyGrammar,
               selectedLeftCoefficient != surroundCoefficientCode
                || selectedRightCoefficient != surroundCoefficientCode {
                throw DTSError.malformed(
                    "XLL hierarchy coefficient escaped the official constant matrix "
                        + "(left \(selectedLeftCoefficient), right \(selectedRightCoefficient), "
                        + "expected \(surroundCoefficientCode)): the 7.1.4 source reached the "
                        + "delivery encoder without composite-headroom guarding"
                )
            }
            let leftUndoCoefficient = try XLLSyntax.undoDownmixCoefficientQ15(
                scaleCode: scaleCode,
                coefficientCode: selectedLeftCoefficient
            )
            let rightUndoCoefficient = try XLLSyntax.undoDownmixCoefficientQ15(
                scaleCode: scaleCode,
                coefficientCode: selectedRightCoefficient
            )
            var primaryResidual = Array(
                repeating: Array(repeating: Int32(0), count: pcm.sampleCount),
                count: 6
            )
            var primaryFull = primaryResidual
            for sample in 0..<pcm.sampleCount {
                let leftRearContribution = (
                    Int64(pcm.planes[4][sample]) * Int64(leftUndoCoefficient) + 16_384
                ) >> 15
                let rightRearContribution = (
                    Int64(pcm.planes[5][sample]) * Int64(rightUndoCoefficient) + 16_384
                ) >> 15
                primaryFull[0][sample] = pcm.planes[2][sample]
                primaryFull[1][sample] = pcm.planes[0][sample]
                primaryFull[2][sample] = pcm.planes[1][sample]
                primaryFull[3][sample] = pcm.planes[3][sample]
                primaryFull[4][sample] = Int32(
                    Int64(pcm.planes[6][sample]) + leftRearContribution
                )
                primaryFull[5][sample] = Int32(
                    Int64(pcm.planes[7][sample]) + rightRearContribution
                )
                for channel in 0..<6 {
                    let core = coreReconstruction.planes[coreOrder[channel]][sample]
                    let scaledCoreUnclipped = (Int64(core) * Int64(inverseScale) + 32_768) >> 16
                    let scaledCore = min(
                        Int64(8_388_607),
                        max(Int64(-8_388_608), scaledCoreUnclipped)
                    )
                    let residual = Int64(primaryFull[channel][sample]) - scaledCore
                    guard residual >= Int64(Int32.min), residual <= Int64(Int32.max) else {
                        throw DTSError.valueOutOfRange(
                            field: "XLL Core residual[\(channel)][\(sample)]",
                            value: String(residual)
                        )
                    }
                    primaryResidual[channel][sample] = Int32(residual)
                }
            }

            // nResidualChEncode bit 1 means a full XLL channel. DTS:X reference
            // streams keep the primary mask at zero and reconstruct it from
            // Core plus residual; the secondary rear set remains full-channel.
            let residualChannelMask: UInt64
            let primary: [[Int32]]
            switch coreAssociationPolicy {
            case .fullPrimaryChannels:
                residualChannelMask = 0x3f
                primary = primaryFull
            case .coreResidual:
                var selectedMask: UInt64 = 0
                var selected = primaryResidual
                for channel in selected.indices {
                    let residualFits24 = primaryResidual[channel].allSatisfy {
                        (-8_388_608...8_388_607).contains(Int($0))
                    }
                    let fullFits24 = primaryFull[channel].allSatisfy {
                        (-8_388_608...8_388_607).contains(Int($0))
                    }
                    if !residualFits24, fullFits24 {
                        selectedMask |= UInt64(1) << UInt64(channel)
                        selected[channel] = primaryFull[channel]
                    }
                }
                if enforcesOfficialHierarchyGrammar, selectedMask != 0 {
                    throw DTSError.malformed(
                        "XLL primary residual mask escaped the corpus-constant 0x00 "
                            + "(selected 0x\(String(selectedMask, radix: 16))): the 7.1.4 "
                            + "source reached the delivery encoder without "
                            + "composite-headroom guarding"
                    )
                }
                residualChannelMask = selectedMask
                primary = selected
            }

            let primaryOrder = [1, 0, 3, 2, 5, 4]
            let rearOrder = [1, 0]
            let primaryPlanes = primaryOrder.map { primary[$0] }
            let rearPlanes = rearOrder.map { [pcm.planes[4], pcm.planes[5]][$0] }

            return applyingPrediction(to: [
                ChannelSetInput(
                    planes: primaryPlanes,
                    speakerMask: 0x627,
                    residualChannelMask: residualChannelMask,
                    primary: true,
                    hierarchical: true,
                    downmixScaleCodes: [],
                    downmixCoefficientCodes: [],
                    decorrelationEnabled: true,
                    originalOrder: primaryOrder,
                    decorrelationCoefficients: Array(repeating: 0, count: 3),
                    adaptivePredictionOrders: Array(repeating: 0, count: 6),
                    adaptiveReflectionCoefficientIndices: Array(repeating: [], count: 6),
                    fixedPredictionOrders: Array(repeating: 0, count: 6),
                    scalableLSBWidths: Array(repeating: 0, count: 6),
                    scalableLSBPlanes: Array(
                        repeating: Array(repeating: 0, count: pcm.sampleCount),
                        count: 6
                    )
                ),
                ChannelSetInput(
                    planes: rearPlanes,
                    speakerMask: 0x180,
                    residualChannelMask: 0x03,
                    primary: false,
                    hierarchical: true,
                    downmixScaleCodes: Array(repeating: scaleCode, count: 6),
                    downmixCoefficientCodes: [
                        zeroCoefficientCode, zeroCoefficientCode,
                        zeroCoefficientCode, zeroCoefficientCode,
                        zeroCoefficientCode, zeroCoefficientCode,
                        zeroCoefficientCode, zeroCoefficientCode,
                        selectedLeftCoefficient, zeroCoefficientCode,
                        zeroCoefficientCode, selectedRightCoefficient
                    ],
                    decorrelationEnabled: true,
                    originalOrder: rearOrder,
                    decorrelationCoefficients: [0],
                    adaptivePredictionOrders: [0, 0],
                    adaptiveReflectionCoefficientIndices: [[], []],
                    fixedPredictionOrders: [0, 0],
                    scalableLSBWidths: [0, 0],
                    scalableLSBPlanes: Array(
                        repeating: Array(repeating: 0, count: pcm.sampleCount),
                        count: 2
                    )
                )
            ])
        }
        let planes = try pcm.reorderedPlanes(pcm.format.layout.waveToDTSPlaneOrder)
        return applyingPrediction(to: [ChannelSetInput(
            planes: planes,
            speakerMask: UInt64(pcm.format.layout.xllSpeakerMask),
            residualChannelMask: UInt64((1 << pcm.format.layout.channelCount) - 1),
            primary: true,
            hierarchical: false,
            downmixScaleCodes: [],
            downmixCoefficientCodes: [],
            decorrelationEnabled: false,
            originalOrder: Array(0..<pcm.format.layout.channelCount),
            decorrelationCoefficients: Array(
                repeating: 0,
                count: pcm.format.layout.channelCount / 2
            ),
            adaptivePredictionOrders: Array(
                repeating: 0,
                count: pcm.format.layout.channelCount
            ),
            adaptiveReflectionCoefficientIndices: Array(
                repeating: [],
                count: pcm.format.layout.channelCount
            ),
            fixedPredictionOrders: Array(
                repeating: 0,
                count: pcm.format.layout.channelCount
            ),
            scalableLSBWidths: Array(repeating: 0, count: pcm.format.layout.channelCount),
            scalableLSBPlanes: Array(
                repeating: Array(repeating: 0, count: pcm.sampleCount),
                count: pcm.format.layout.channelCount
            )
        )])
    }

    private func directSevenOneChannelSets(pcm: PCMBuffer) -> [ChannelSetInput] {
        // Keep conservative delivery in native speaker-mask order. No pairwise
        // decorrelation is performed here, so emitting an identity transform
        // with a non-identity original-order map only exercises an unnecessary
        // decoder path on a terminal. The secondary set carries Lrs/Rrs
        // independently; no primary value contains a rear contribution.
        let primary = [
            pcm.planes[2],
            pcm.planes[0],
            pcm.planes[1],
            pcm.planes[3],
            pcm.planes[6],
            pcm.planes[7]
        ]
        let rearPlanes = [pcm.planes[4], pcm.planes[5]]

        return [
            ChannelSetInput(
                planes: primary,
                speakerMask: 0x627,
                residualChannelMask: 0x3f,
                primary: true,
                hierarchical: true,
                downmixScaleCodes: [],
                downmixCoefficientCodes: [],
                decorrelationEnabled: false,
                originalOrder: [],
                decorrelationCoefficients: [],
                adaptivePredictionOrders: Array(repeating: 0, count: 6),
                adaptiveReflectionCoefficientIndices: Array(repeating: [], count: 6),
                fixedPredictionOrders: Array(repeating: 0, count: 6),
                scalableLSBWidths: Array(repeating: 0, count: 6),
                scalableLSBPlanes: Array(
                    repeating: Array(repeating: 0, count: pcm.sampleCount),
                    count: 6
                )
            ),
            ChannelSetInput(
                planes: rearPlanes,
                speakerMask: 0x180,
                residualChannelMask: 0x03,
                primary: false,
                hierarchical: true,
                downmixScaleCodes: [],
                downmixCoefficientCodes: [],
                decorrelationEnabled: false,
                originalOrder: [],
                decorrelationCoefficients: [],
                adaptivePredictionOrders: [0, 0],
                adaptiveReflectionCoefficientIndices: [[], []],
                fixedPredictionOrders: [0, 0],
                scalableLSBWidths: [0, 0],
                scalableLSBPlanes: Array(
                    repeating: Array(repeating: 0, count: pcm.sampleCount),
                    count: 2
                )
            )
        ]
    }

    private func applyingPrediction(to inputs: [ChannelSetInput]) -> [ChannelSetInput] {
        if codingMode == .terminalOrderedConservative
            || codingMode == .terminalLegacyLinear {
            // The channel-set constructors already place the planes in the
            // coded order declared by `originalOrder`. Coefficients and all
            // predictor orders are zero, so retaining the declaration changes
            // syntax only and the decoder reconstructs the same direct PCM.
            return inputs
        }
        if codingMode == .terminalConservative
            || codingMode == .terminalRice
            || codingMode == .terminalOfficialRice {
            // Terminal delivery keeps the channel-set syntax explicit and
            // independently invertible.  Do not ask a hardware decoder to
            // reproduce a locally selected prediction/decorrelation transform
            // before the terminal corpus has certified those choices.
            return inputs.map { input in
                var directPlanes = input.planes
                if input.decorrelationEnabled {
                    // Existing channel-set constructors arrange planes in the
                    // coded order declared by `originalOrder`.  With the
                    // transform omitted, restore the decoder's natural
                    // speaker order before clearing that declaration.
                    for codedChannel in input.planes.indices {
                        directPlanes[input.originalOrder[codedChannel]] = input.planes[codedChannel]
                    }
                }
                return ChannelSetInput(
                    planes: directPlanes,
                    speakerMask: input.speakerMask,
                    residualChannelMask: input.residualChannelMask,
                    primary: input.primary,
                    hierarchical: input.hierarchical,
                    downmixScaleCodes: input.downmixScaleCodes,
                    downmixCoefficientCodes: input.downmixCoefficientCodes,
                    decorrelationEnabled: false,
                    originalOrder: Array(0..<directPlanes.count),
                    decorrelationCoefficients: Array(
                        repeating: 0,
                        count: directPlanes.count / 2
                    ),
                    adaptivePredictionOrders: Array(
                        repeating: 0,
                        count: directPlanes.count
                    ),
                    adaptiveReflectionCoefficientIndices: Array(
                        repeating: [],
                        count: directPlanes.count
                    ),
                    fixedPredictionOrders: Array(
                        repeating: 0,
                        count: directPlanes.count
                    ),
                    scalableLSBWidths: input.scalableLSBWidths,
                    scalableLSBPlanes: input.scalableLSBPlanes
                )
            }
        }
        if codingMode == .terminalPredictive {
            return inputs.map { input in
                var predictedPlanes: [[Int32]] = []
                var adaptiveOrders: [Int] = []
                var reflectionIndices: [[Int32]] = []
                var fixedOrders: [Int] = []
                predictedPlanes.reserveCapacity(input.planes.count)
                adaptiveOrders.reserveCapacity(input.planes.count)
                reflectionIndices.reserveCapacity(input.planes.count)
                fixedOrders.reserveCapacity(input.planes.count)
                for plane in input.planes {
                    let selected = selectPrediction(plane)
                    predictedPlanes.append(selected.residuals)
                    adaptiveOrders.append(selected.adaptiveOrder)
                    reflectionIndices.append(selected.reflectionIndices)
                    fixedOrders.append(selected.fixedOrder)
                }
                return ChannelSetInput(
                    planes: predictedPlanes,
                    speakerMask: input.speakerMask,
                    residualChannelMask: input.residualChannelMask,
                    primary: input.primary,
                    hierarchical: input.hierarchical,
                    downmixScaleCodes: input.downmixScaleCodes,
                    downmixCoefficientCodes: input.downmixCoefficientCodes,
                    decorrelationEnabled: input.decorrelationEnabled,
                    originalOrder: input.originalOrder,
                    decorrelationCoefficients: input.decorrelationCoefficients,
                    adaptivePredictionOrders: adaptiveOrders,
                    adaptiveReflectionCoefficientIndices: reflectionIndices,
                    fixedPredictionOrders: fixedOrders,
                    scalableLSBWidths: input.scalableLSBWidths,
                    scalableLSBPlanes: input.scalableLSBPlanes
                )
            }
        }
        return inputs.map { input in
            let decorrelated = selectPairwiseDecorrelation(input)
            var predictedPlanes: [[Int32]] = []
            var adaptiveOrders: [Int] = []
            var reflectionIndices: [[Int32]] = []
            var orders: [Int] = []
            predictedPlanes.reserveCapacity(input.planes.count)
            adaptiveOrders.reserveCapacity(input.planes.count)
            reflectionIndices.reserveCapacity(input.planes.count)
            orders.reserveCapacity(input.planes.count)

            for plane in decorrelated.planes {
                let selected = selectPrediction(plane)
                predictedPlanes.append(selected.residuals)
                adaptiveOrders.append(selected.adaptiveOrder)
                reflectionIndices.append(selected.reflectionIndices)
                orders.append(selected.fixedOrder)
            }

            return ChannelSetInput(
                planes: predictedPlanes,
                speakerMask: decorrelated.speakerMask,
                residualChannelMask: decorrelated.residualChannelMask,
                primary: decorrelated.primary,
                hierarchical: decorrelated.hierarchical,
                downmixScaleCodes: decorrelated.downmixScaleCodes,
                downmixCoefficientCodes: decorrelated.downmixCoefficientCodes,
                decorrelationEnabled: decorrelated.decorrelationEnabled,
                originalOrder: decorrelated.originalOrder,
                decorrelationCoefficients: decorrelated.decorrelationCoefficients,
                adaptivePredictionOrders: adaptiveOrders,
                adaptiveReflectionCoefficientIndices: reflectionIndices,
                fixedPredictionOrders: orders,
                scalableLSBWidths: decorrelated.scalableLSBWidths,
                scalableLSBPlanes: decorrelated.scalableLSBPlanes
            )
        }
    }

    private func selectPrediction(_ plane: [Int32]) -> (
        residuals: [Int32],
        adaptiveOrder: Int,
        reflectionIndices: [Int32],
        fixedOrder: Int
    ) {
        var bestPlane = plane
        var bestFixedOrder = 0
        var bestAdaptiveOrder = 0
        var bestReflectionIndices: [Int32] = []
        var bestBits = estimatedEntropyBits(plane) + 2
        for order in 1...3 {
            guard let candidate = fixedPredictionResiduals(plane, order: order) else {
                continue
            }
            let bits = estimatedEntropyBits(candidate) + 2
            if bits < bestBits {
                bestBits = bits
                bestFixedOrder = order
                bestAdaptiveOrder = 0
                bestReflectionIndices = []
                bestPlane = candidate
            }
        }
        if let reflectionCandidates = levinsonReflectionCandidates(plane) {
            for (offset, indices) in reflectionCandidates.enumerated() {
                let order = offset + 1
                guard let candidate = adaptivePredictionResiduals(
                    plane,
                    reflectionIndices: indices
                ) else { continue }
                let bits = estimatedEntropyBits(candidate) + indices.count * 8
                if bits < bestBits {
                    bestBits = bits
                    bestFixedOrder = 0
                    bestAdaptiveOrder = order
                    bestReflectionIndices = indices
                    bestPlane = candidate
                }
            }
        }
        return (
            residuals: bestPlane,
            adaptiveOrder: bestAdaptiveOrder,
            reflectionIndices: bestReflectionIndices,
            fixedOrder: bestFixedOrder
        )
    }

    /// Choose a signed Q3 pair coefficient from the legal seven-bit table.
    /// The decoder reconstructs `destination += source * coefficient / 8`, so
    /// the encoder searches the inverse transform and scores the actual Rice /
    /// linear payload rather than relying on a correlation threshold.
    private func selectPairwiseDecorrelation(_ input: ChannelSetInput) -> ChannelSetInput {
        guard input.decorrelationEnabled,
              input.planes.count >= 2,
              input.planes.count.isMultiple(of: 2),
              input.decorrelationCoefficients.count == input.planes.count / 2 else {
            return input
        }

        var planes = input.planes
        var coefficients = Array(repeating: Int32(0), count: planes.count / 2)
        for pair in coefficients.indices {
            let source = pair * 2
            let destination = source + 1
            let sourcePlane = input.planes[source]
            let destinationPlane = input.planes[destination]
            let sourceScore = estimatedEntropyBits(sourcePlane)
            var bestCoefficient: Int32 = 0
            var bestScore = sourceScore + estimatedEntropyBits(destinationPlane)
            var transformed = Array(repeating: Int32(0), count: destinationPlane.count)
            for candidate in Int32(-64)...Int32(63) {
                if candidate == 0 { continue }
                var isRepresentable = true
                for sample in destinationPlane.indices {
                    let delta = (Int64(sourcePlane[sample]) * Int64(candidate) + 4) >> 3
                    let value = Int64(destinationPlane[sample]) - delta
                    guard (-8_388_608...8_388_607).contains(value) else {
                        isRepresentable = false
                        break
                    }
                    transformed[sample] = Int32(value)
                }
                guard isRepresentable else { continue }
                let score = sourceScore + estimatedEntropyBits(transformed)
                    + 8 // bPWChDecorrCoeff + signed seven-bit coefficient
                if score < bestScore {
                    bestScore = score
                    bestCoefficient = candidate
                }
            }
            coefficients[pair] = bestCoefficient
            if bestCoefficient != 0 {
                for sample in destinationPlane.indices {
                    let delta = (Int64(sourcePlane[sample]) * Int64(bestCoefficient) + 4) >> 3
                    planes[destination][sample] = Int32(
                        truncatingIfNeeded: Int64(destinationPlane[sample]) - delta
                    )
                }
            }
        }
        return ChannelSetInput(
            planes: planes,
            speakerMask: input.speakerMask,
            residualChannelMask: input.residualChannelMask,
            primary: input.primary,
            hierarchical: input.hierarchical,
            downmixScaleCodes: input.downmixScaleCodes,
            downmixCoefficientCodes: input.downmixCoefficientCodes,
            decorrelationEnabled: input.decorrelationEnabled,
            originalOrder: input.originalOrder,
            decorrelationCoefficients: coefficients,
            adaptivePredictionOrders: input.adaptivePredictionOrders,
            adaptiveReflectionCoefficientIndices: input.adaptiveReflectionCoefficientIndices,
            fixedPredictionOrders: input.fixedPredictionOrders,
            scalableLSBWidths: input.scalableLSBWidths,
            scalableLSBPlanes: input.scalableLSBPlanes
        )
    }

    private func fixedPredictionResiduals(_ plane: [Int32], order: Int) -> [Int32]? {
        var result = plane
        for _ in 0..<order {
            var differenced = Array(repeating: Int32(0), count: result.count)
            var previous = Int64(0)
            for sample in result.indices {
                let current = Int64(result[sample])
                let value = current - previous
                guard (-8_388_608...8_388_607).contains(value) else { return nil }
                differenced[sample] = Int32(value)
                previous = current
            }
            result = differenced
        }
        return result
    }

    private func levinsonReflectionCandidates(_ plane: [Int32]) -> [[Int32]]? {
        let maximumOrder = min(15, plane.count - 1)
        guard maximumOrder > 0 else { return nil }
        var autocorrelation = Array(repeating: 0.0, count: maximumOrder + 1)
        for lag in 0...maximumOrder {
            var sum = 0.0
            for sample in lag..<plane.count {
                sum += Double(plane[sample]) * Double(plane[sample - lag])
            }
            autocorrelation[lag] = sum
        }
        guard autocorrelation[0].isFinite, autocorrelation[0] > 0 else { return nil }

        var direct = [1.0]
        var error = autocorrelation[0]
        var quantized: [Int32] = []
        var candidates: [[Int32]] = []
        candidates.reserveCapacity(maximumOrder)
        for order in 1...maximumOrder {
            var numerator = autocorrelation[order]
            if order > 1 {
                for coefficient in 1..<order {
                    numerator += direct[coefficient] * autocorrelation[order - coefficient]
                }
            }
            guard error.isFinite, error > 0 else { break }
            let reflection = -numerator / error
            guard reflection.isFinite, abs(reflection) < 1 else { break }
            let index = quantizedReflectionIndex(reflection)
            quantized.append(index)
            candidates.append(quantized)

            var updated = Array(repeating: 0.0, count: order + 1)
            updated[0] = 1
            if order > 1 {
                for coefficient in 1..<order {
                    updated[coefficient] = direct[coefficient]
                        + reflection * direct[order - coefficient]
                }
            }
            updated[order] = reflection
            direct = updated
            error *= max(1e-12, 1 - reflection * reflection)
        }
        return candidates.isEmpty ? nil : candidates
    }

    private func quantizedReflectionIndex(_ coefficient: Double) -> Int32 {
        let magnitude = min(0.999_984_741_210_937_5, abs(coefficient))
        let target = magnitude * 65_536.0
        var low = 0
        var high = XLLSyntax.reflectionCoefficients.count - 1
        while low < high {
            let middle = (low + high) / 2
            if Double(XLLSyntax.reflectionCoefficients[middle]) < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let upper = low
        let lower = max(0, upper - 1)
        let magnitudeIndex = abs(Double(XLLSyntax.reflectionCoefficients[upper]) - target)
            < abs(Double(XLLSyntax.reflectionCoefficients[lower]) - target)
            ? upper : lower
        return coefficient < 0 ? -Int32(magnitudeIndex) : Int32(magnitudeIndex)
    }

    private func adaptivePredictionResiduals(
        _ plane: [Int32],
        reflectionIndices: [Int32]
    ) -> [Int32]? {
        let order = reflectionIndices.count
        guard order > 0, plane.count > order else { return nil }
        let direct = directPredictionCoefficients(reflectionIndices)
        var result = plane
        for sample in order..<plane.count {
            var accumulator: Int64 = 0
            for coefficient in 0..<order {
                accumulator += Int64(plane[sample - order + coefficient])
                    * Int64(direct[order - coefficient - 1])
            }
            let prediction = clip24(roundShift(accumulator, by: 16))
            let residual = Int64(plane[sample]) + Int64(prediction)
            guard (-8_388_608...8_388_607).contains(residual) else { return nil }
            result[sample] = Int32(residual)
        }
        return result
    }

    private func directPredictionCoefficients(_ indices: [Int32]) -> [Int32] {
        var direct = Array(repeating: Int32(0), count: indices.count)
        for index in indices.indices {
            let signedIndex = indices[index]
            let raw = Int32(XLLSyntax.reflectionCoefficients[Int(abs(signedIndex))])
            let coefficient = signedIndex < 0 ? -raw : raw
            for pairIndex in 0..<((index + 1) / 2) {
                let opposite = index - pairIndex - 1
                let first = direct[pairIndex]
                let second = direct[opposite]
                direct[pairIndex] = first &+ multiplyQ16(coefficient, second)
                direct[opposite] = second &+ multiplyQ16(coefficient, first)
            }
            direct[index] = coefficient
        }
        return direct
    }

    @inline(__always)
    private func multiplyQ16(_ first: Int32, _ second: Int32) -> Int32 {
        Int32(truncatingIfNeeded: roundShift(Int64(first) * Int64(second), by: 16))
    }

    @inline(__always)
    private func roundShift(_ value: Int64, by shift: Int) -> Int64 {
        shift > 0 ? (value + (Int64(1) << (shift - 1))) >> shift : value
    }

    @inline(__always)
    private func clip24(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }

    private func estimatedEntropyBits(_ plane: [Int32]) -> Int {
        var total = 0
        for segment in 0..<XLLSyntax.segmentCount {
            let start = segment * XLLSyntax.segmentSampleCount
            let end = start + XLLSyntax.segmentSampleCount
            let samples = plane[start..<end]
            let linearWidth = minimumLinearBitCount(samples)
            var bestBits = linearWidth <= XLLSyntax.linearSampleBitCount
                ? linearWidth * samples.count
                : Int.max
            let locationBitWidth = XLLSyntax.segmentSampleCount.trailingZeroBitCount
            for parameter in 0..<XLLSyntax.linearSampleBitCount {
                let analysis = analyzeHybridRice(
                    samples,
                    parameter: parameter,
                    locationBitWidth: locationBitWidth
                )
                bestBits = min(bestBits, analysis.riceBitCount)
                if let hybrid = analysis.hybridPlan {
                    bestBits = min(bestBits, hybrid.bitCount)
                }
            }
            guard total <= Int.max - bestBits else { return Int.max }
            total += bestBits
        }
        return total
    }

    private func selectHierarchyCoefficientCode(
        base: [Int32],
        rear: [Int32],
        core: [Int32],
        inverseScale: Int32,
        defaultCode: Int,
        coreAssociationPolicy: XLLCoreAssociationPolicy
    ) throws -> Int {
        guard base.count == rear.count, rear.count == core.count else {
            throw DTSError.malformed("XLL hierarchy coefficient inputs are not sample-aligned")
        }
        func measurements(code: Int) throws -> (
            targetFits: Bool,
            residualFits: Bool,
            maximumTarget: Int64,
            maximumResidual: Int64
        ) {
            let coefficient = try XLLSyntax.undoDownmixCoefficientQ15(
                scaleCode: 473,
                coefficientCode: code
            )
            var targetFits = true
            var residualFits = true
            var maximumTarget: Int64 = 0
            var maximumResidual: Int64 = 0
            for sample in base.indices {
                let contribution = (
                    Int64(rear[sample]) * Int64(coefficient) + 16_384
                ) >> 15
                let target = Int64(base[sample]) + contribution
                let scaledCoreUnclipped = (
                    Int64(core[sample]) * Int64(inverseScale) + 32_768
                ) >> 16
                let scaledCore = min(
                    Int64(8_388_607),
                    max(Int64(-8_388_608), scaledCoreUnclipped)
                )
                let residual = target - scaledCore
                if target < -8_388_608 || target > 8_388_607 {
                    targetFits = false
                }
                if residual < -8_388_608 || residual > 8_388_607 {
                    residualFits = false
                }
                maximumTarget = max(maximumTarget, abs(target))
                maximumResidual = max(maximumResidual, abs(residual))
            }
            return (targetFits, residualFits, maximumTarget, maximumResidual)
        }

        let defaultMeasurements = try measurements(code: defaultCode)
        switch coreAssociationPolicy {
        case .fullPrimaryChannels:
            if defaultMeasurements.targetFits { return defaultCode }
        case .coreResidual:
            if defaultMeasurements.targetFits,
               defaultMeasurements.residualFits,
               defaultMeasurements.maximumResidual <= 8_000_000 {
                return defaultCode
            }
        }

        // Codes 0...217 represent the negative table and 256...473 the
        // positive table. Search only on exceptional high-level frames.
        let candidates = Array(0...217) + Array(256...473)
        var bestResidual: (code: Int, maximum: Int64, distance: Int)?
        var bestFull: (code: Int, maximum: Int64, distance: Int)?
        for code in candidates {
            let value = try measurements(code: code)
            guard value.targetFits else { continue }
            let distance = abs(code - defaultCode)
            if bestFull == nil
                || value.maximumTarget < bestFull!.maximum
                || (value.maximumTarget == bestFull!.maximum
                    && distance < bestFull!.distance) {
                bestFull = (code, value.maximumTarget, distance)
            }
            if value.residualFits,
               bestResidual == nil
                    || value.maximumResidual < bestResidual!.maximum
                    || (value.maximumResidual == bestResidual!.maximum
                        && distance < bestResidual!.distance) {
                bestResidual = (code, value.maximumResidual, distance)
            }
        }
        if coreAssociationPolicy == .coreResidual, let bestResidual {
            return bestResidual.code
        }
        if let bestFull { return bestFull.code }
        throw DTSError.malformed("XLL hierarchy has no representable full-channel matrix")
    }

    private func encodeCommonHeader(
        frameByteCount: Int,
        frameSizeBitCount: Int,
        segmentSizeBitCount: Int,
        segmentCount: Int,
        segmentSampleCount: Int,
        channelMaskBitCount: Int,
        channelSetCount: Int,
        scalableLSBs: Bool
    ) throws -> Data {
        guard frameSizeBitCount > 0, frameSizeBitCount <= XLLSyntax.frameSizeBitCount,
              segmentSizeBitCount > 0, segmentSizeBitCount <= XLLSyntax.segmentSizeBitCount,
              frameByteCount > 0, frameByteCount <= (1 << frameSizeBitCount) else {
            throw DTSError.valueOutOfRange(field: "nLLFrameSize", value: String(frameByteCount))
        }
        guard (1...16).contains(channelSetCount) else {
            throw DTSError.valueOutOfRange(
                field: "nNumChSetsInFrame",
                value: String(channelSetCount)
            )
        }
        guard [2, 4, 8].contains(segmentCount),
              segmentCount * segmentSampleCount == XLLSyntax.frameSampleCount else {
            throw DTSError.valueOutOfRange(
                field: "XLL segmentation",
                value: "\(segmentCount)x\(segmentSampleCount)"
            )
        }
        var writer = BitWriter()
        try writer.write(XLLSyntax.syncWord, bitCount: 32, field: "SYNCXLL")
        try writer.write(0, bitCount: 4, field: "nVersionMinus1")
        let headerSizeOffset = writer.bitCount
        try writer.write(0, bitCount: 8, field: "nHeaderSizeMinus1")
        try writer.write(
            UInt64(frameSizeBitCount - 1),
            bitCount: 5,
            field: "nBits4FrameFsizeMinus1"
        )
        try writer.write(
            UInt64(frameByteCount - 1),
            bitCount: frameSizeBitCount,
            field: "nLLFrameSizeMinus1"
        )
        try writer.write(
            UInt64(channelSetCount - 1),
            bitCount: 4,
            field: "nNumChSetsInFrameMinus1"
        )
        try writer.write(
            UInt64(requiredUnsignedBitCount(maximumValue: segmentCount) - 1),
            bitCount: 4,
            field: "nSegmentsInFrameLog2"
        )
        try writer.write(
            UInt64(requiredUnsignedBitCount(maximumValue: segmentSampleCount) - 1),
            bitCount: 4,
            field: "nSmplInSegLog2"
        )
        try writer.write(
            UInt64(segmentSizeBitCount - 1),
            bitCount: 5,
            field: "nBits4SSizeMinus1"
        )
        try writer.write(0, bitCount: 2, field: "nBandDataCRCEn")
        try writer.write(scalableLSBs ? 1 : 0, bitCount: 1, field: "bScalableLSBs")
        try writer.write(
            UInt64(channelMaskBitCount - 1),
            bitCount: 5,
            field: "nBits4ChMaskMinus1"
        )
        if scalableLSBs {
            try writer.write(0, bitCount: 4, field: "nFixedLSBWidth")
        }
        writer.alignToByte()
        let headerByteCount = writer.byteCount + 2
        try writer.patch(
            at: headerSizeOffset,
            value: UInt64(headerByteCount - 1),
            bitCount: 8,
            field: "nHeaderSizeMinus1"
        )
        try DTSCRC16.appendChecksum(to: &writer, protectedByteOffset: 4, component: "XLL common header")
        guard writer.byteCount == headerByteCount else {
            throw DTSError.malformed("XLL common-header size did not close")
        }
        return writer.data()
    }

    private func encodeChannelSetHeader(
        input: ChannelSetInput,
        channelMaskBitCount: Int,
        segmentSizeBitCount: Int,
        segmentSampleCount: Int,
        scalableLSBs: Bool
    ) throws -> Data {
        let channels = input.planes.count
        var writer = BitWriter()
        let sizeOffset = writer.bitCount
        try writer.write(0, bitCount: 10, field: "nChSetHeaderSizeMinus1")
        try writer.write(UInt64(channels - 1), bitCount: 4, field: "nChSetLLChannelMinus1")
        try writer.write(input.residualChannelMask, bitCount: channels, field: "nResidualChEncode")
        try writer.write(23, bitCount: 5, field: "nBitResolutionMinus1")
        try writer.write(23, bitCount: 5, field: "nBitWidthMinus1")
        try writer.write(UInt64(XLLSyntax.samplingFrequencyIndex48k), bitCount: 4, field: "sFreqIndex")
        try writer.write(0, bitCount: 2, field: "nFsInterpolate")
        try writer.write(0, bitCount: 2, field: "nReplacementSet")

        // bOne2OneMapChannels2Speakers is true in the enclosing asset descriptor.
        try writer.write(input.primary ? 1 : 0, bitCount: 1, field: "bPrimaryChSet")
        let hasDownmix = !input.downmixCoefficientCodes.isEmpty
        try writer.write(hasDownmix ? 1 : 0, bitCount: 1, field: "bDownmixCoeffCodeEmbedded")
        if hasDownmix {
            try writer.write(1, bitCount: 1, field: "bDownmixEmbedded")
            if input.primary {
                try writer.write(0, bitCount: 3, field: "nLLDownmixType")
            }
        }
        try writer.write(input.hierarchical ? 1 : 0, bitCount: 1, field: "bHierChSet")
        if hasDownmix {
            guard !input.primary,
                  input.downmixScaleCodes.count * channels == input.downmixCoefficientCodes.count else {
                throw DTSError.malformed("XLL hierarchical downmix matrix dimensions do not close")
            }
            for lowerChannel in input.downmixScaleCodes.indices {
                try writer.write(
                    UInt64(input.downmixScaleCodes[lowerChannel]),
                    bitCount: 9,
                    field: "DownmixScale[\(lowerChannel)]"
                )
                for outputChannel in 0..<channels {
                    let index = lowerChannel * channels + outputChannel
                    try writer.write(
                        UInt64(input.downmixCoefficientCodes[index]),
                        bitCount: 9,
                        field: "DownmixCoefficient[\(lowerChannel)][\(outputChannel)]"
                    )
                }
            }
        }
        try writer.write(1, bitCount: 1, field: "bChMaskEnabled")
        try writer.write(
            input.speakerMask,
            bitCount: channelMaskBitCount,
            field: "nChMask"
        )

        guard input.adaptivePredictionOrders.count == channels,
              input.adaptivePredictionOrders.allSatisfy({ (0...15).contains($0) }),
              input.adaptiveReflectionCoefficientIndices.count == channels,
              input.adaptiveReflectionCoefficientIndices.enumerated().allSatisfy({
                  $0.element.count == input.adaptivePredictionOrders[$0.offset]
                      && $0.element.allSatisfy { (-127...127).contains($0) }
              }),
              input.fixedPredictionOrders.count == channels,
              input.fixedPredictionOrders.allSatisfy({ (0...3).contains($0) }) else {
            throw DTSError.malformed("XLL prediction configuration does not match channels")
        }
        try writer.write(input.decorrelationEnabled ? 1 : 0, bitCount: 1, field: "bPWChDecorEnabled")
        if input.decorrelationEnabled, channels > 1 {
            guard input.originalOrder.count == channels,
                  Set(input.originalOrder) == Set(0..<channels),
                  input.decorrelationCoefficients.count == channels / 2 else {
                throw DTSError.malformed("XLL pairwise-decorrelation configuration is incomplete")
            }
            let orderBitCount = max(
                1,
                requiredUnsignedBitCount(maximumValue: channels - 1)
            )
            for channel in 0..<channels {
                try writer.write(
                    UInt64(input.originalOrder[channel]),
                    bitCount: orderBitCount,
                    field: "nOrigChOrder[\(channel)]"
                )
            }
            for pair in input.decorrelationCoefficients.indices {
                let coefficient = input.decorrelationCoefficients[pair]
                try writer.write(
                    coefficient == 0 ? 0 : 1,
                    bitCount: 1,
                    field: "bPWChDecorrCoeff[\(pair)]"
                )
                if coefficient != 0 {
                    try writer.writeSignedZigZag(
                        coefficient,
                        bitCount: 7,
                        field: "nPWChDecorrCoeff[\(pair)]"
                    )
                }
            }
        }
        for channel in 0..<channels {
            try writer.write(
                UInt64(input.adaptivePredictionOrders[channel]),
                bitCount: 4,
                field: "nAdaptPredOrder[\(channel)]"
            )
        }
        for channel in 0..<channels where input.adaptivePredictionOrders[channel] == 0 {
            try writer.write(
                UInt64(input.fixedPredictionOrders[channel]),
                bitCount: 2,
                field: "nFixedPredOrder[\(channel)]"
            )
        }
        for channel in 0..<channels {
            for (coefficient, index) in input.adaptiveReflectionCoefficientIndices[channel].enumerated() {
                try writer.writeSignedZigZag(
                    index,
                    bitCount: 8,
                    field: "nAdaptReflCoeff[\(channel)][\(coefficient)]"
                )
            }
        }
        if scalableLSBs {
            guard input.scalableLSBWidths.count == channels,
                  input.scalableLSBPlanes.count == channels,
                  input.scalableLSBWidths.allSatisfy({ (0...15).contains($0) }),
                  input.scalableLSBPlanes.allSatisfy({ $0.count == XLLSyntax.frameSampleCount }) else {
                throw DTSError.malformed("XLL scalable-LSB configuration does not match channels")
            }
            let lsbSectionByteCount = (
                input.scalableLSBWidths.reduce(0, +) * segmentSampleCount + 7
            ) / 8
            try writer.write(
                UInt64(lsbSectionByteCount),
                bitCount: segmentSizeBitCount,
                field: "nLSBSectionSize"
            )
            for channel in 0..<channels {
                try writer.write(
                    UInt64(input.scalableLSBWidths[channel]),
                    bitCount: 4,
                    field: "nScalableLSBs[\(channel)]"
                )
            }
            for channel in 0..<channels {
                try writer.write(0, bitCount: 4, field: "nBitWidthAdj[\(channel)]")
            }
        }

        writer.alignToByte()
        let headerByteCount = writer.byteCount + 2
        try writer.patch(
            at: sizeOffset,
            value: UInt64(headerByteCount - 1),
            bitCount: 10,
            field: "nChSetHeaderSizeMinus1"
        )
        try DTSCRC16.appendChecksum(to: &writer, protectedByteOffset: 0, component: "XLL channel-set header")
        guard writer.byteCount == headerByteCount else {
            throw DTSError.malformed("XLL channel-set-header size did not close")
        }
        return writer.data()
    }

    private func encodeNavigation(
        segmentByteCounts: [[Int]],
        segmentSizeBitCount: Int
    ) throws -> Data {
        guard [2, 4, 8].contains(segmentByteCounts.count),
              let channelSetCount = segmentByteCounts.first?.count,
              channelSetCount > 0,
              segmentByteCounts.allSatisfy({ $0.count == channelSetCount }) else {
            throw DTSError.malformed("XLL NAVI entry count does not match segment count")
        }
        var writer = BitWriter()
        for segment in segmentByteCounts.indices {
            for channelSet in segmentByteCounts[segment].indices {
                let byteCount = segmentByteCounts[segment][channelSet]
                guard byteCount > 0 else {
                    throw DTSError.valueOutOfRange(
                        field: "NAVI[\(segment)][\(channelSet)]",
                        value: String(byteCount)
                    )
                }
                try writer.write(
                    UInt64(byteCount - 1),
                    bitCount: segmentSizeBitCount,
                    field: "NAVI[\(segment)][\(channelSet)]"
                )
            }
        }
        writer.alignToByte()
        try DTSCRC16.appendChecksum(to: &writer, protectedByteOffset: 0, component: "XLL NAVI")
        return writer.data()
    }

    private func selectEntropyModes(
        dtsPlanes: [[Int32]],
        adaptivePredictionOrders: [Int],
        segmentCount: Int,
        segmentSampleCount: Int
    ) -> [[EntropyMode]] {
        if codingMode == .terminalConservative
            || codingMode == .terminalOrderedConservative
            || codingMode == .terminalLegacyLinear {
            return (0..<segmentCount).map { segment in
                let start = segment * segmentSampleCount
                let end = start + segmentSampleCount
                return dtsPlanes.map { plane in
                    .linear(width: minimumLinearBitCount(plane[start..<end]))
                }
            }
        }
        if codingMode == .terminalRice
            || codingMode == .terminalOfficialRice
            || codingMode == .terminalPredictive {
            // Official delivery bounds every emitted unary quotient at the
            // corpus maximum; the experimental terminal Rice modes keep the
            // historical exact-minimum selection for differential study.
            let boundsUnaryQuotient = codingMode == .terminalOfficialRice
            return (0..<segmentCount).map { segment in
                let start = segment * segmentSampleCount
                let end = start + segmentSampleCount
                return dtsPlanes.map { plane in
                    terminalRiceMode(
                        plane[start..<end],
                        boundingUnaryQuotient: boundsUnaryQuotient
                    )
                }
            }
        }
        let channelPaths = dtsPlanes.enumerated().map { channel, plane in
            selectEntropyModesForPlane(
                plane,
                adaptivePredictionOrder: adaptivePredictionOrders[channel],
                segmentCount: segmentCount,
                segmentSampleCount: segmentSampleCount
            )
        }
        return (0..<segmentCount).map { segment in
            channelPaths.map { $0[segment] }
        }
    }

    private func selectEntropyModesForPlane(
        _ plane: [Int32],
        adaptivePredictionOrder: Int,
        segmentCount: Int,
        segmentSampleCount: Int
    ) -> [EntropyMode] {
        let dtsPlanes = [plane]
        let candidates = (0..<segmentCount).map { index in
            entropyCandidates(
                index: index,
                segmentSampleCount: segmentSampleCount,
                dtsPlanes: dtsPlanes,
                adaptivePredictionOrder: adaptivePredictionOrder
            )
        }

        // Dynamic programming preserves the one-bit state-reuse form across
        // 2/4/8 segments while still allowing a different optimum per segment.
        var costs = candidates[0].map { mode in
            alignedSegmentBitCount(
                payloadBitCount: entropyPayloadBitCount(
                    index: 0,
                    segmentSampleCount: segmentSampleCount,
                    dtsPlanes: dtsPlanes,
                    mode: mode,
                    adaptivePredictionOrder: adaptivePredictionOrder
                ),
                headerBitCount: entropyHeaderBitCount(
                    mode,
                    segment: 0,
                    reusingParameters: false
                )
            )
        }
        var paths = candidates[0].map { [$0] }
        guard segmentCount > 1 else { return paths[0] }
        for segment in 1..<segmentCount {
            var nextCosts = Array(repeating: Int.max, count: candidates[segment].count)
            var nextPaths = Array(repeating: [EntropyMode](), count: candidates[segment].count)
            for (currentIndex, current) in candidates[segment].enumerated() {
                let payload = entropyPayloadBitCount(
                    index: segment,
                    segmentSampleCount: segmentSampleCount,
                    dtsPlanes: dtsPlanes,
                    mode: current,
                    adaptivePredictionOrder: adaptivePredictionOrder
                )
                for (previousIndex, previous) in candidates[segment - 1].enumerated() {
                    let segmentBits = alignedSegmentBitCount(
                        payloadBitCount: payload,
                        headerBitCount: entropyHeaderBitCount(
                            current,
                            segment: segment,
                            reusingParameters: previous == current && canReuse(current)
                        )
                    )
                    guard costs[previousIndex] <= Int.max - segmentBits else { continue }
                    let total = costs[previousIndex] + segmentBits
                    if total < nextCosts[currentIndex] {
                        nextCosts[currentIndex] = total
                        nextPaths[currentIndex] = paths[previousIndex] + [current]
                    }
                }
            }
            costs = nextCosts
            paths = nextPaths
        }
        guard let bestIndex = costs.indices.min(by: { costs[$0] < costs[$1] }),
              !paths[bestIndex].isEmpty else {
            return Array(repeating: .linear(width: 24), count: segmentCount)
        }
        return paths[bestIndex]
    }

    /// Restrict the delivery profile to standard Rice without state reuse,
    /// hybrid exceptions, prediction, or channel transforms. Search the legal
    /// parameter range because active reference XLL frames use ordinary Rice
    /// even when a linear representation would also fit. Delivery
    /// (`boundingUnaryQuotient`) additionally raises the parameter until the
    /// longest emitted unary code fits the official-corpus maximum, exactly
    /// as the private XLL-X layer already does: a terminal bounded reader
    /// that stops at that maximum desyncs on longer runs and turns every
    /// following sample of the segment into full-scale garbage.
    private func terminalRiceMode(
        _ samples: ArraySlice<Int32>,
        boundingUnaryQuotient: Bool
    ) -> EntropyMode {
        // Preserve the compact zero-width form used by the qualified first
        // XLL frame. Active terminal frames use Rice below.
        guard samples.contains(where: { $0 != 0 }) else {
            return .linear(width: 0)
        }
        var selectedParameter = 0
        var selectedBitCount = Int.max
        for parameter in 0..<XLLSyntax.linearSampleBitCount {
            let bitCount = ricePayloadBitCount(samples, parameter: parameter)
            if bitCount < selectedBitCount {
                selectedParameter = parameter
                selectedBitCount = bitCount
            }
        }
        if boundingUnaryQuotient {
            var maximumMapped: UInt64 = 0
            for sample in samples {
                maximumMapped = max(maximumMapped, zigZag(sample))
            }
            while selectedParameter < 31,
                  maximumMapped >> UInt64(selectedParameter)
                    > Self.terminalMaximumUnaryQuotient {
                selectedParameter += 1
            }
        }
        return .rice(parameter: selectedParameter)
    }

    private func entropyCandidates(
        index: Int,
        segmentSampleCount: Int,
        dtsPlanes: [[Int32]],
        adaptivePredictionOrder: Int
    ) -> [EntropyMode] {
        let startSample = index * segmentSampleCount
            + (index == 0 ? adaptivePredictionOrder : 0)
        let endSample = (index + 1) * segmentSampleCount
        let samples = dtsPlanes[0][startSample..<endSample]
        let linearWidth = minimumLinearBitCount(samples)
        let linearAllowed = linearWidth <= XLLSyntax.linearSampleBitCount
        var result: [EntropyMode] = linearAllowed ? [.linear(width: linearWidth)] : []
        let linearBits = linearAllowed
            ? samples.count * linearWidth
            : Int.max
        var bestRice: (parameter: Int, bits: Int)?
        let locationBitWidth = segmentSampleCount.trailingZeroBitCount
        for parameter in 0..<XLLSyntax.linearSampleBitCount {
            let analysis = analyzeHybridRice(
                samples,
                parameter: parameter,
                locationBitWidth: locationBitWidth
            )
            let bits = analysis.riceBitCount
            if bestRice == nil || bits < bestRice!.bits {
                bestRice = (parameter, bits)
            }
            if !linearAllowed || bits < linearBits {
                result.append(.rice(parameter: parameter))
            }
            if let hybrid = selectHybridRiceMode(
                samples,
                parameter: parameter,
                locationBitWidth: locationBitWidth,
                plan: analysis.hybridPlan
            ), !linearAllowed || hybrid.bitCount < linearBits {
                result.append(hybrid.mode)
            }
        }
        if result.isEmpty, let bestRice {
            result.append(.rice(parameter: bestRice.parameter))
        }
        return result
    }

    private func entropyPayloadBitCount(
        index: Int,
        segmentSampleCount: Int,
        dtsPlanes: [[Int32]],
        mode: EntropyMode,
        adaptivePredictionOrder: Int
    ) -> Int {
        let segmentStart = index * segmentSampleCount
        let partACount = index == 0 ? adaptivePredictionOrder : 0
        let partAEnd = segmentStart + partACount
        let segmentEnd = segmentStart + segmentSampleCount
        let plane = dtsPlanes[0]
        let partAMode = entropyMode(
            matching: mode,
            plane: plane,
            sampleRange: segmentStart..<partAEnd
        )
        return entropyPayloadBitCount(
            plane[segmentStart..<partAEnd],
            mode: partAMode,
            locationBitWidth: segmentSampleCount.trailingZeroBitCount
        ) + entropyPayloadBitCount(
            plane[partAEnd..<segmentEnd],
            mode: mode,
            locationBitWidth: segmentSampleCount.trailingZeroBitCount
        )
    }

    private func entropyHeaderBitCount(
        _ mode: EntropyMode,
        segment: Int,
        reusingParameters: Bool
    ) -> Int {
        if reusingParameters { return 1 }
        var bits = segment > 0 ? 1 : 0 // bUseSegStateCodeParm
        bits += 1 // ncSegType
        bits += 1 // bRiceCodeFlag
        switch mode {
        case .linear:
            break
        case .rice:
            bits += 1 // bHybridRiceCode
        case .hybridRice:
            bits += 1 + 5 // bHybridRiceCode + nHybridLinearWidth
        }
        if segment == 0 { bits += 5 } // ABIT0
        bits += 5 // ABIT
        return bits
    }

    private func ricePayloadBitCount(
        _ samples: ArraySlice<Int32>,
        parameter: Int
    ) -> Int {
        var result = 0
        for sample in samples {
            let mapped = zigZag(sample)
            let quotient = mapped >> UInt64(parameter)
            let bits = quotient + 1 + UInt64(parameter)
            guard bits <= UInt64(Int.max - result) else { return Int.max }
            result += Int(bits)
        }
        return result
    }

    private func entropyPayloadBitCount(
        _ samples: ArraySlice<Int32>,
        mode: EntropyMode,
        locationBitWidth: Int
    ) -> Int {
        switch mode {
        case .linear(let width):
            return width * samples.count
        case .rice(let parameter):
            return ricePayloadBitCount(samples, parameter: parameter)
        case .hybridRice(let parameter, let linearWidth, let isolatedSampleOffsets):
            var isolatedIndex = 0
            var bits = locationBitWidth * (isolatedSampleOffsets.count + 1)
            for (offset, sample) in samples.enumerated() {
                if isolatedIndex < isolatedSampleOffsets.count,
                   isolatedSampleOffsets[isolatedIndex] == offset {
                    bits += linearWidth
                    isolatedIndex += 1
                } else {
                    let mapped = zigZag(sample)
                    bits += Int(mapped >> UInt64(parameter)) + 1 + parameter
                }
            }
            return bits
        }
    }

    private func selectHybridRiceMode(
        _ samples: ArraySlice<Int32>,
        parameter: Int,
        locationBitWidth: Int,
        plan: HybridRicePlan?
    ) -> (mode: EntropyMode, bitCount: Int)? {
        guard let plan else { return nil }
        let maximumIsolatedCount = (1 << locationBitWidth) - 1
        var offsets: [Int] = []
        offsets.reserveCapacity(min(samples.count, maximumIsolatedCount + 1))
        var omittedOffset: Int?
        var omittedRiceBitCount = Int.max
        for (offset, sample) in samples.enumerated() {
            let mapped = zigZag(sample)
            let riceBits = Int(mapped >> UInt64(parameter)) + 1 + parameter
            let requiredWidth = max(1, 64 - mapped.leadingZeroBitCount)
            if requiredWidth <= plan.linearWidth,
               riceBits > plan.linearWidth + locationBitWidth {
                offsets.append(offset)
                if riceBits < omittedRiceBitCount
                    || (riceBits == omittedRiceBitCount && offset > (omittedOffset ?? -1)) {
                    omittedRiceBitCount = riceBits
                    omittedOffset = offset
                }
            }
        }
        if offsets.count > maximumIsolatedCount, let omittedOffset {
            offsets.removeAll { $0 == omittedOffset }
        }
        return (
            .hybridRice(
                parameter: parameter,
                linearWidth: plan.linearWidth,
                isolatedSampleOffsets: offsets
            ),
            plan.bitCount
        )
    }

    /// Computes Hybrid Rice cost with fixed-size temporary scratch storage.
    ///
    /// The previous scratch block also retained one Rice cost and one width per
    /// sample. At the supported 64/128/256-sample segment sizes that pushed the
    /// temporary allocation onto the heap for every Rice parameter and became
    /// the encoder's dominant allocation hotspot. Only the 34-entry range
    /// deltas are needed normally. In the single overflow case (all samples
    /// selected but the syntax can signal only N-1), the values are recomputed
    /// once to choose the same omitted sample.
    private func analyzeHybridRice(
        _ samples: ArraySlice<Int32>,
        parameter: Int,
        locationBitWidth: Int
    ) -> HybridRiceAnalysis {
        guard !samples.isEmpty, (1...8).contains(locationBitWidth) else {
            return HybridRiceAnalysis(riceBitCount: 0, hybridPlan: nil)
        }
        let maximumIsolatedCount = (1 << locationBitWidth) - 1
        return withUnsafeTemporaryAllocation(
            of: Int.self,
            capacity: 68
        ) { scratch in
            scratch.initialize(repeating: 0)
            guard let baseAddress = scratch.baseAddress else {
                return HybridRiceAnalysis(riceBitCount: Int.max, hybridPlan: nil)
            }
            let countDelta = UnsafeMutableBufferPointer(
                start: baseAddress,
                count: 34
            )
            let sumDelta = UnsafeMutableBufferPointer(
                start: baseAddress.advanced(by: 34),
                count: 34
            )

            var riceTotal = 0
            for sample in samples {
                let mapped = zigZag(sample)
                let riceBits = Int(mapped >> UInt64(parameter)) + 1 + parameter
                let requiredWidth = max(1, 64 - mapped.leadingZeroBitCount)
                riceTotal += riceBits
                let lowerWidth = requiredWidth
                let upperWidth = min(32, riceBits - locationBitWidth - 1)
                if lowerWidth <= upperWidth {
                    countDelta[lowerWidth] += 1
                    countDelta[upperWidth + 1] -= 1
                    sumDelta[lowerWidth] += riceBits
                    sumDelta[upperWidth + 1] -= riceBits
                }
            }

            var activeCount = 0
            var activeRiceBitSum = 0
            var best: HybridRicePlan?
            for width in 1...32 {
                activeCount += countDelta[width]
                activeRiceBitSum += sumDelta[width]
                guard activeCount > 0 else { continue }
                var saving = activeRiceBitSum
                    - activeCount * (width + locationBitWidth)
                if activeCount > maximumIsolatedCount {
                    var smallestSaving = Int.max
                    for sample in samples {
                        let mapped = zigZag(sample)
                        let riceBits = Int(mapped >> UInt64(parameter))
                            + 1 + parameter
                        let requiredWidth = max(
                            1,
                            64 - mapped.leadingZeroBitCount
                        )
                        if requiredWidth <= width,
                           riceBits > width + locationBitWidth {
                            smallestSaving = min(
                                smallestSaving,
                                riceBits - width - locationBitWidth
                            )
                        }
                    }
                    saving -= smallestSaving
                }
                guard saving > 0 else { continue }
                let candidateBits = riceTotal - saving + locationBitWidth
                if best == nil
                    || candidateBits < best!.bitCount
                    || (candidateBits == best!.bitCount && width < best!.linearWidth) {
                    best = HybridRicePlan(
                        linearWidth: width,
                        bitCount: candidateBits
                    )
                }
            }
            let hybridPlan = best.flatMap {
                $0.bitCount + 5 < riceTotal ? $0 : nil
            }
            return HybridRiceAnalysis(
                riceBitCount: riceTotal,
                hybridPlan: hybridPlan
            )
        }
    }

    private func alignedSegmentBitCount(payloadBitCount: Int, headerBitCount: Int) -> Int {
        guard payloadBitCount <= Int.max - headerBitCount else { return Int.max }
        let bits = payloadBitCount + headerBitCount
        return (bits + 7) & ~7
    }

    private func zigZag(_ value: Int32) -> UInt64 {
        let signed = Int64(value)
        return signed >= 0 ? UInt64(signed) << 1 : UInt64((-signed << 1) - 1)
    }

    private func minimumLinearBitCount(_ samples: ArraySlice<Int32>) -> Int {
        var maximum: UInt64 = 0
        for sample in samples {
            maximum = max(maximum, zigZag(sample))
        }
        guard maximum > 0 else { return 0 }
        // Linear ABIT code zero is reserved for a zero-width all-zero plane;
        // non-zero ABIT values decode as code+1, so width one is represented
        // by the smallest legal non-zero width, two bits.
        return max(2, UInt64.bitWidth - maximum.leadingZeroBitCount)
    }

    private func requiredUnsignedBitCount(maximumValue: Int) -> Int {
        guard maximumValue > 0 else { return 1 }
        return Int.bitWidth - maximumValue.leadingZeroBitCount
    }

    private func canReuse(_ mode: EntropyMode) -> Bool {
        // Encoder Suite restates the zero-width linear allocation for every
        // segment. Some strict decoders also special-case ABIT=0 state, so do
        // not carry that state through bUseSegStateCodeParm.
        if case .linear(width: 0) = mode { return false }
        if case .hybridRice = mode { return false }
        return true
    }

    private func encodeSegment(
        index: Int,
        segmentSampleCount: Int,
        dtsPlanes: [[Int32]],
        modes: [EntropyMode],
        previousModes: [EntropyMode]?,
        adaptivePredictionOrders: [Int],
        scalableLSBWidths: [Int],
        scalableLSBPlanes: [[Int32]]
    ) throws -> Data {
        let startSample = index * segmentSampleCount
        let endSample = startSample + segmentSampleCount
        guard modes.count == dtsPlanes.count,
              adaptivePredictionOrders.count == dtsPlanes.count,
              scalableLSBWidths.count == dtsPlanes.count,
              scalableLSBPlanes.count == dtsPlanes.count,
              scalableLSBPlanes.allSatisfy({ $0.count >= endSample }) else {
            throw DTSError.malformed("XLL segment channel configuration is incomplete")
        }
        let estimatedByteCapacity = max(
            64,
            dtsPlanes.count * segmentSampleCount * 3 + 128
        )
        var writer = BitWriter(reservingCapacity: estimatedByteCapacity)

        // Terminal-conservative output never asks a decoder to retain entropy
        // allocation state. This makes every segment independently decodable
        // and avoids both shared-parameter and state-reuse branches.
        // A terminal experiment must change only the feature under test.  In
        // particular, Rice and predictive delivery modes must not quietly add
        // shared allocation state when all channel parameters happen to
        // coincide.  State reuse and common parameters therefore remain
        // research-only syntax.
        let permitsLegacySharedParameters = codingMode == .research
            || codingMode == .terminalLegacyLinear
        let requiresExplicitParameters = !permitsLegacySharedParameters
        // The recovered reference stream uses explicit allocation state in
        // every observed active delivery segment. Keep state reuse confined to
        // the research profile so a terminal never has to carry local entropy
        // state across a public XLL segment boundary.
        let reuseParameters = permitsLegacySharedParameters
            && index > 0
            && !(index == 1 && adaptivePredictionOrders.contains(where: { $0 > 0 }))
            && previousModes == modes
            && modes.allSatisfy(canReuse)
        var partAModes = modes
        if reuseParameters {
            try writer.write(1, bitCount: 1, field: "bUseSegStateCodeParm")
        } else {
            if index > 0 {
                try writer.write(0, bitCount: 1, field: "bUseSegStateCodeParm")
            }
            // Adaptive prediction's leading samples are a one-time Part A
            // partition in segment zero. Keep those parameters per channel so
            // each predictor order maps to the exact number of raw seed samples.
            let hasAdaptivePartA = index == 0
                && adaptivePredictionOrders.contains(where: { $0 > 0 })
            let commonParameters = !requiresExplicitParameters
                && !hasAdaptivePartA
                && !modes.contains(where: {
                    if case .hybridRice = $0 { return true }
                    return false
                })
                && modes.dropFirst().allSatisfy { $0 == modes[0] }
            try writer.write(commonParameters ? 1 : 0, bitCount: 1, field: "ncSegType")
            let parameterModes = commonParameters ? [modes[0]] : modes
            for (parameterIndex, mode) in parameterModes.enumerated() {
                let rice: Bool
                switch mode {
                case .linear: rice = false
                case .rice, .hybridRice: rice = true
                }
                try writer.write(
                    rice ? 1 : 0,
                    bitCount: 1,
                    field: "bRiceCodeFlag[\(parameterIndex)]"
                )
                if !commonParameters, rice {
                    if case .hybridRice(_, let linearWidth, _) = mode {
                        try writer.write(1, bitCount: 1, field: "bHybridRiceCode[\(parameterIndex)]")
                        try writer.write(
                            UInt64(linearWidth - 1),
                            bitCount: 5,
                            field: "nHybridLinearWidth[\(parameterIndex)]"
                        )
                    } else {
                        try writer.write(0, bitCount: 1, field: "bHybridRiceCode[\(parameterIndex)]")
                    }
                }
            }
            for (parameterIndex, mode) in parameterModes.enumerated() {
                if index == 0 {
                    let channel = commonParameters ? 0 : parameterIndex
                    let partASampleCount = commonParameters
                        ? adaptivePredictionOrders.max() ?? 0
                        : adaptivePredictionOrders[channel]
                    let partAMode = entropyMode(
                        matching: mode,
                        plane: dtsPlanes[channel],
                        sampleRange: 0..<partASampleCount
                    )
                    if commonParameters {
                        for channelIndex in partAModes.indices {
                            partAModes[channelIndex] = partAMode
                        }
                    } else {
                        partAModes[channel] = partAMode
                    }
                    try writeEntropyAllocation(
                        partAMode,
                        to: &writer,
                        field: "ABIT0[\(parameterIndex)]"
                    )
                }
                try writeEntropyAllocation(
                    mode,
                    to: &writer,
                    field: "ABIT[\(parameterIndex)]"
                )
            }
        }

        for (channel, plane) in dtsPlanes.enumerated() {
            let mode = modes[channel]
            let partASampleCount = index == 0 ? adaptivePredictionOrders[channel] : 0
            for sample in startSample..<(startSample + partASampleCount) {
                try writeEntropySample(
                    plane[sample],
                    mode: partAModes[channel],
                    to: &writer,
                    field: "segment[\(index)].channel[\(channel)].partA[\(sample)]"
                )
            }
            let partBStart = startSample + partASampleCount
            switch mode {
            case .linear, .rice:
                for sample in partBStart..<endSample {
                    try writeEntropySample(
                        plane[sample],
                        mode: mode,
                        to: &writer,
                        field: "segment[\(index)].channel[\(channel)].sample[\(sample)]"
                    )
                }
            case .hybridRice(let parameter, let linearWidth, let isolatedSampleOffsets):
                let locationBitWidth = segmentSampleCount.trailingZeroBitCount
                let maximumCount = (1 << locationBitWidth) - 1
                guard isolatedSampleOffsets.count <= maximumCount,
                      isolatedSampleOffsets == isolatedSampleOffsets.sorted(),
                      isolatedSampleOffsets.allSatisfy({
                          (0..<(endSample - partBStart)).contains($0)
                      }) else {
                    throw DTSError.malformed("XLL Hybrid Rice locations are invalid")
                }
                try writer.write(
                    UInt64(isolatedSampleOffsets.count),
                    bitCount: locationBitWidth,
                    field: "nIsolatedSamples[\(index)][\(channel)]"
                )
                for offset in isolatedSampleOffsets {
                    try writer.write(
                        UInt64(offset),
                        bitCount: locationBitWidth,
                        field: "nIsolatedSampleLocation[\(index)][\(channel)]"
                    )
                }
                var isolatedIndex = 0
                for sample in partBStart..<endSample {
                    let offset = sample - partBStart
                    if isolatedIndex < isolatedSampleOffsets.count,
                       isolatedSampleOffsets[isolatedIndex] == offset {
                        try writer.writeSignedZigZag(
                            plane[sample],
                            bitCount: linearWidth,
                            field: "XLL Hybrid Rice linear sample[\(index)][\(channel)][\(offset)]"
                        )
                        isolatedIndex += 1
                    } else {
                        try writeEntropySample(
                            plane[sample],
                            mode: .rice(parameter: parameter),
                            to: &writer,
                            field: "XLL Hybrid Rice sample[\(index)][\(channel)][\(offset)]"
                        )
                    }
                }
            }
        }
        writer.alignToByte()
        let lsbStartByteCount = writer.byteCount
        for channel in dtsPlanes.indices {
            let width = scalableLSBWidths[channel]
            guard (0...15).contains(width) else {
                throw DTSError.valueOutOfRange(
                    field: "nScalableLSBs[\(channel)]",
                    value: String(width)
                )
            }
            guard width > 0 else { continue }
            let maximum = (UInt64(1) << UInt64(width)) - 1
            for sample in startSample..<endSample {
                let value = scalableLSBPlanes[channel][sample]
                guard value >= 0, UInt64(value) <= maximum else {
                    throw DTSError.valueOutOfRange(
                        field: "XLL scalable LSB[\(channel)][\(sample)]",
                        value: String(value)
                    )
                }
                try writer.write(
                    UInt64(value),
                    bitCount: width,
                    field: "XLL scalable LSB[\(channel)][\(sample)]"
                )
            }
        }
        writer.alignToByte()
        let expectedLSBByteCount = (scalableLSBWidths.reduce(0, +) * segmentSampleCount + 7) / 8
        guard writer.byteCount - lsbStartByteCount == expectedLSBByteCount else {
            throw DTSError.malformed("XLL scalable-LSB section size did not close")
        }
        return writer.data()
    }

    private func entropyMode(
        matching mode: EntropyMode,
        plane: [Int32],
        sampleRange: Range<Int>
    ) -> EntropyMode {
        guard !sampleRange.isEmpty else {
            switch mode {
            case .linear: return .linear(width: 0)
            case .rice, .hybridRice: return .rice(parameter: 0)
            }
        }
        switch mode {
        case .linear:
            var maximum: UInt64 = 0
            for sample in sampleRange {
                maximum = max(maximum, zigZag(plane[sample]))
            }
            let width = maximum == 0
                ? 0
                : max(2, UInt64.bitWidth - maximum.leadingZeroBitCount)
            return .linear(width: width)
        case .rice, .hybridRice:
            var best = (parameter: 0, bits: Int.max)
            for parameter in 0..<XLLSyntax.linearSampleBitCount {
                var bits = 0
                for sample in sampleRange {
                    let mapped = zigZag(plane[sample])
                    let count = (mapped >> UInt64(parameter)) + 1 + UInt64(parameter)
                    guard count <= UInt64(Int.max - bits) else {
                        bits = Int.max
                        break
                    }
                    bits += Int(count)
                }
                if bits < best.bits { best = (parameter, bits) }
            }
            return .rice(parameter: best.parameter)
        }
    }

    @inline(__always)
    private func writeEntropyAllocation(
        _ mode: EntropyMode,
        to writer: inout BitWriter,
        field: @autoclosure () -> String
    ) throws {
        let allocation: Int
        switch mode {
        case let .linear(width): allocation = width == 0 ? 0 : width - 1
        case let .rice(parameter), let .hybridRice(parameter, _, _): allocation = parameter
        }
        try writer.write(UInt64(allocation), bitCount: 5, field: field())
    }

    @inline(__always)
    private func writeEntropySample(
        _ sample: Int32,
        mode: EntropyMode,
        to writer: inout BitWriter,
        field: @autoclosure () -> String
    ) throws {
        switch mode {
        case let .linear(width):
            if width > 0 {
                try writer.writeSignedZigZag(
                    sample,
                    bitCount: width,
                    field: field()
                )
            }
        case let .rice(parameter), let .hybridRice(parameter, _, _):
            let mapped = zigZag(sample)
            let quotient = mapped >> UInt64(parameter)
            guard quotient <= UInt64(Int.max) else {
                throw DTSError.valueOutOfRange(
                    field: field(),
                    value: String(quotient)
                )
            }
            try writer.writeUnary(
                Int(quotient),
                field: "\(field()).riceUnary"
            )
            if parameter > 0 {
                let remainder = mapped & ((UInt64(1) << UInt64(parameter)) - 1)
                try writer.write(
                    remainder,
                    bitCount: parameter,
                    field: "\(field()).riceRemainder"
                )
            }
        }
    }
}
