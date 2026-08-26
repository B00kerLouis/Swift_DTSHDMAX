import Foundation

public enum DTSHDMAProfile: String, Sendable, Codable {
    /// Internal XLL algorithm-validation stream without a backward-compatible Core.
    /// This is never a final deliverable product.
    case xllStandalone
    /// Final DTS HDMA product: 5.1 DTS Core followed by the full XLL asset.
    case dtsHDMA

    /// The externally visible elementary-stream product represented by this
    /// profile. DTS:X is intentionally not returned here: its object payload
    /// is carried by the private XLL-X extension and has a separate encoder.
    public var streamKind: DTSHDMAStreamKind {
        switch self {
        case .xllStandalone: .xllStandalone
        case .dtsHDMA: .dtsHDMA
        }
    }
}

public enum DTSHDMAProduct: String, Sendable, Codable, Equatable {
    case dtsHDMA = "DTS HDMA"
    case dtsxHDMA = "DTS:X HDMA"
}

/// Stream classification includes one internal XLL diagnostic form and the
/// only two final products exposed by this project.
public enum DTSHDMAStreamKind: String, Sendable, Codable, Equatable {
    case xllStandalone = "XLL-Standalone"
    case dtsHDMA = "DTS HDMA"
    case dtsxHDMA = "DTS:X HDMA"

    public var product: DTSHDMAProduct? {
        switch self {
        case .xllStandalone: nil
        case .dtsHDMA: .dtsHDMA
        case .dtsxHDMA: .dtsxHDMA
        }
    }
}

public enum DTSTailPolicy: String, Sendable, Codable {
    case reject
    case zeroPad
}

public struct DTSHDMAEncoderConfiguration: Sendable, Equatable, Codable {
    public let format: PCMFormat
    public let profile: DTSHDMAProfile
    public let deterministic: Bool
    public let tailPolicy: DTSTailPolicy
    public let xllCodingMode: XLLCodingMode
    public let coreAssociationPolicy: XLLCoreAssociationPolicy
    /// Uses the compact, independently decoded zero-residual grammar for the
    /// two Core priming frames. This is exposed for public-XLL differential
    /// controls; ordinary HDMA keeps its existing explicit-zero default.
    public let compactXLLPriming: Bool
    /// DTS:X delivery invariant: every emitted Core-residual hierarchy frame
    /// must keep the official constant matrix (scale/coefficient code 473)
    /// and the all-zero primary residual mask the reference corpus always
    /// uses. With the encoder-boundary source guard active these invariants
    /// hold by construction, so a violation is a diagnosable defect (an
    /// unguarded overload reached the XLL layer) rather than syntax that
    /// silently ships. Differential/research configurations leave this off.
    public let officialHierarchyGrammarEnforced: Bool
    /// Test-only override for public XLL segmentation. Production uses the
    /// encoder's per-frame search when this is nil.
    public let forcedXLLSegmentCount: Int?

    public init(
        format: PCMFormat,
        profile: DTSHDMAProfile = .dtsHDMA,
        deterministic: Bool = true,
        tailPolicy: DTSTailPolicy = .reject,
        xllCodingMode: XLLCodingMode = .terminalConservative,
        coreAssociationPolicy: XLLCoreAssociationPolicy = .fullPrimaryChannels,
        compactXLLPriming: Bool = false,
        officialHierarchyGrammarEnforced: Bool = false,
        forcedXLLSegmentCount: Int? = nil
    ) {
        self.format = format
        self.profile = profile
        self.deterministic = deterministic
        self.tailPolicy = tailPolicy
        self.xllCodingMode = xllCodingMode
        self.coreAssociationPolicy = coreAssociationPolicy
        self.compactXLLPriming = compactXLLPriming
        self.officialHierarchyGrammarEnforced = officialHierarchyGrammarEnforced
        self.forcedXLLSegmentCount = forcedXLLSegmentCount
    }
}

public struct DTSHDMADTSXEncodedStream: Sendable {
    public let stream: Data
    public let privateStream: DTSXPrivateEncodedStream
    public let segmentationPlans: [XLLSegmentationPlan]
}

public struct DTSHDMAEncoder: Sendable {
    public let configuration: DTSHDMAEncoderConfiguration

    private struct FrameWorkItem: Sendable {
        let frameIndex: Int
        let frame: PCMBuffer
        let decodedCore: PCMBuffer?
        let coreBytes: Data?
        let isPriming: Bool
    }

    private enum PrivateXLLXSource: Sendable {
        case frames([Data])
        case session(DTSXPrivateStreamEncodingSession)

        var frameCount: Int {
            switch self {
            case .frames(let frames): frames.count
            case .session(let session): session.frameCount
            }
        }
    }

    private struct EncodedAccessUnit: Sendable {
        let data: Data
        let segmentationPlan: XLLSegmentationPlan
    }

    private struct InternalEncodedResult: Sendable {
        let stream: Data?
        let privateStream: DTSXPrivateEncodedStream?
        let segmentationPlans: [XLLSegmentationPlan]
    }

    public init(configuration: DTSHDMAEncoderConfiguration) {
        self.configuration = configuration
    }

    public func encode(
        _ pcm: PCMBuffer,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Data {
        guard let stream = try encodeInternal(
            pcm,
            privateXLLXSource: nil,
            progress: progress
        ).stream else {
            throw DTSError.malformed("in-memory DTS HDMA encoding produced no stream")
        }
        return stream
    }

    /// Emits each completed Core+ExSS access unit immediately. The callback is
    /// invoked on the serial output path, after the parallel XLL batch has been
    /// assembled, so callers can append directly to one output file safely.
    public func encode(
        _ pcm: PCMBuffer,
        writingAccessUnitsTo output: @escaping (Data) throws -> Void,
        progress: ((Int, Int) -> Void)? = nil
    ) throws {
        _ = try encodeInternal(
            pcm,
            privateXLLXSource: nil,
            accessUnitOutput: output,
            progress: progress
        )
    }

    /// Encodes the public Core+XLL compatibility bed while placing one native
    /// XLL-X frame at the aligned private-data boundary of every XLL frame.
    /// The private frames must already include the two 512-sample priming AUs
    /// and any final zero-padded AU required by the public bed timeline.
    public func encode(
        _ pcm: PCMBuffer,
        privateXLLXFrames: [Data],
        coreAssociationPolicy: XLLCoreAssociationPolicy = .fullPrimaryChannels,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Data {
        guard let stream = try encodeInternal(
            pcm,
            privateXLLXSource: .frames(privateXLLXFrames),
            privateCoreAssociationPolicy: coreAssociationPolicy,
            progress: progress
        ).stream else {
            throw DTSError.malformed("in-memory DTS:X compatibility encoding produced no stream")
        }
        return stream
    }

    /// Couples every private XLL-X frame to the final dynamic segmentation of
    /// its enclosing public XLL frame and returns the report for the bytes that
    /// were actually embedded.
    public func encode(
        _ pcm: PCMBuffer,
        privateXLLXSession: DTSXPrivateStreamEncodingSession,
        coreAssociationPolicy: XLLCoreAssociationPolicy = .fullPrimaryChannels,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> DTSHDMADTSXEncodedStream {
        let result = try encodeInternal(
            pcm,
            privateXLLXSource: .session(privateXLLXSession),
            privateCoreAssociationPolicy: coreAssociationPolicy,
            progress: progress
        )
        guard let privateStream = result.privateStream else {
            throw DTSError.malformed("DTS:X encoding did not finalize its private stream")
        }
        return DTSHDMADTSXEncodedStream(
            stream: try requiredInMemoryStream(result.stream),
            privateStream: privateStream,
            segmentationPlans: result.segmentationPlans
        )
    }

    /// Streaming counterpart of the DTS:X coupling path. The XLL-X session is
    /// still finalized after the final public access unit, while the enclosing
    /// DTS-HD access units are delivered as they are encoded.
    public func encode(
        _ pcm: PCMBuffer,
        privateXLLXSession: DTSXPrivateStreamEncodingSession,
        coreAssociationPolicy: XLLCoreAssociationPolicy = .fullPrimaryChannels,
        writingAccessUnitsTo output: @escaping (Data) throws -> Void,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> DTSXPrivateEncodedStream {
        let result = try encodeInternal(
            pcm,
            privateXLLXSource: .session(privateXLLXSession),
            privateCoreAssociationPolicy: coreAssociationPolicy,
            accessUnitOutput: output,
            progress: progress
        )
        guard let privateStream = result.privateStream else {
            throw DTSError.malformed("DTS:X streaming encode did not finalize its private stream")
        }
        return privateStream
    }

    private func encodeInternal(
        _ pcm: PCMBuffer,
        privateXLLXSource: PrivateXLLXSource?,
        privateCoreAssociationPolicy: XLLCoreAssociationPolicy = .coreResidual,
        accessUnitOutput: ((Data) throws -> Void)? = nil,
        progress: ((Int, Int) -> Void)?
    ) throws -> InternalEncodedResult {
        let progressTotal = 1_000
        progress?(0, progressTotal)
        guard pcm.format == configuration.format else {
            throw DTSError.invalidArgument("PCM format does not match encoder configuration")
        }
        guard pcm.sampleCount > 0 else {
            throw DTSError.invalidArgument("PCM sample count must be positive")
        }
        let needsTailPadding = !pcm.sampleCount.isMultiple(of: XLLSyntax.frameSampleCount)
        if needsTailPadding, configuration.tailPolicy != .zeroPad {
            throw DTSError.unsupported(
                "PCM sample count must be a positive multiple of \(XLLSyntax.frameSampleCount); explicit end padding is required"
            )
        }

        let sourceFrameCount = (
            pcm.sampleCount + XLLSyntax.frameSampleCount - 1
        ) / XLLSyntax.frameSampleCount
        let primingFrameCount = configuration.profile == .dtsHDMA
            ? XLLSyntax.coreCompatiblePrimingSampleCount / XLLSyntax.frameSampleCount
            : 0
        // The Core-residual XLL hierarchy declares one constant DownmixScale
        // (code 473, -3.0103 dB) for every reconstructed channel, exactly as
        // the official DTS:X corpus does. That declaration is a promise about
        // the Core content itself: Core = primary x (1/sqrt(2)) on all six
        // channels. The reference decoder relies on it twice.
        //
        // 1. First-frame startup: the reference decoder forces lossy
        //    recovery output on the first XLL frame it filters (and on any
        //    seek re-entry). It zeroes every XLL band and plays
        //    clip23(Core x sqrt(2)) alone on each Core-mapped channel. With
        //    an unscaled Core, an active first frame is boosted +3 dB into
        //    hard clipping - the tbh-class "first frame unplayable" failure -
        //    while a silent start (Nature's Fury) is unaffected.
        // 2. Steady-state residual combination computes the same
        //    clip23(Core x sqrt(2)) intermediate. Official streams keep it
        //    inside the signed 24-bit range by construction; an unscaled
        //    Core drives it past full scale at every loud onset, leaving
        //    reconstruction dependent on terminal saturation behavior.
        //
        // The surround pair already satisfies the promise (its equal-power
        // 7.1-to-5.1 fold is the declared scale); the four pass-through
        // channels must carry the identical fold. Ordinary HDMA delivery
        // (full-primary XLL, no hierarchy matrix) keeps its unscaled Core.
        let effectiveCoreAssociationPolicy = privateXLLXSource == nil
            ? configuration.coreAssociationPolicy
            : privateCoreAssociationPolicy
        let coreCarriesDeclaredDownmixScale = configuration.profile == .dtsHDMA
            && pcm.format.layout == .sevenOne
            && effectiveCoreAssociationPolicy == .coreResidual
        let totalFrameCount = sourceFrameCount + primingFrameCount
        let xllEncoder = XLLEncoder(
            codingMode: configuration.xllCodingMode,
            enforcesOfficialHierarchyGrammar: configuration.officialHierarchyGrammarEnforced
        )
        let exssWriter = ExSSWriter()
        let exssAssetDescriptorProfile: ExSSAssetDescriptorProfile = privateXLLXSource == nil
            ? .standardHDMA
            : .dtsxXLLX
        progress?(150, progressTotal)
        if let privateXLLXSource {
            guard configuration.profile == .dtsHDMA else {
                throw DTSError.invalidArgument(
                    "XLL-X private frames require the Core-compatible DTS HDMA profile"
                )
            }
            guard privateXLLXSource.frameCount == totalFrameCount else {
                throw DTSError.malformed(
                    "XLL-X private frame count \(privateXLLXSource.frameCount) does not match \(totalFrameCount) access units"
                )
            }
        }
        var coreDecoder = DTSCoreDecoder()
        let silentFrame = try PCMBuffer(
            format: pcm.format,
            planes: Array(
                repeating: Array(repeating: 0, count: XLLSyntax.frameSampleCount),
                count: pcm.format.layout.channelCount
            )
        )
        let silentCoreFrame: PCMBuffer? = try configuration.profile == .dtsHDMA
            ? PCMBuffer(
                format: PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .fiveOneSide),
                planes: Array(
                    repeating: Array(repeating: 0, count: XLLSyntax.frameSampleCount),
                    count: DTSChannelLayout.fiveOneSide.channelCount
                )
            )
            : nil
        var coreEncoderSession: DTSCoreEncoderSession? = configuration.profile == .dtsHDMA
            ? DTSCoreEncoderSession()
            : nil
        if configuration.profile == .dtsHDMA, pcm.format.layout == .stereo {
            throw DTSError.unsupported("DTS HDMA requires 5.1(side) or 7.1 PCM")
        }

        // Core QMF/ADPCM/LFE history is advanced serially. XLL and ExSS work is
        // parallelized in bounded batches, so a feature-length encode no longer
        // retains the padded PCM, complete Core stream, every decoded frame and
        // every encoded access unit at the same time.
        let parallelWorkerCount = DTSParallel.workerCount(for: totalFrameCount)
        let batchCapacity = max(1, parallelWorkerCount * 2)
        var pendingWorkItems: [FrameWorkItem] = []
        pendingWorkItems.reserveCapacity(batchCapacity)
        var stream = accessUnitOutput == nil ? Data() : nil
        var segmentationPlans: [XLLSegmentationPlan] = []
        segmentationPlans.reserveCapacity(totalFrameCount)
        var completedAccessUnitCount = 0

        func encodeBatch(_ workItems: [FrameWorkItem]) throws -> [EncodedAccessUnit] {
            let completedBeforeBatch = completedAccessUnitCount
            return try DTSParallel.map(
                count: workItems.count,
                workerCount: parallelWorkerCount,
                progress: { completed, _ in
                    progress?(
                        150 + (
                            830 * (completedBeforeBatch + completed)
                            / max(1, totalFrameCount)
                        ),
                        progressTotal
                    )
                }
            ) { index in
                let item = workItems[index]
                // The first 1,024 samples are decoder priming and are discarded by
                // the declared XLL initial decoding delay. Encoder Suite writes
                // zero XLL planes for these access units instead of spending bits
                // cancelling the Core filter warm-up. Keep decoding the Core to
                // advance its state, but serialize the canonical zero residual.
                let xllCoreReconstruction = item.isPriming
                    ? silentCoreFrame
                    : item.decodedCore
                // Priming declarations must match the delivery channel-set
                // configuration. The research-only compact zero form saves
                // eight bytes but declares pairwise decorrelation with a
                // permuted original channel order and shared entropy
                // parameters - a channel-set configuration no later delivery
                // access unit repeats. Terminals latch that first
                // configuration and reconfigure when the first source AU
                // arrives with different declarations, so hot-start
                // programmes (tbh class) lose their first audible frames
                // ("first frames unplayable until AU3") while silent starts
                // (Nature's Fury) mask the window. Ordinary HDMA - reported
                // OK on hardware - always primed with its delivery encoder;
                // DTS:X now does the same. The compact research form remains
                // available only as the explicit `compactXLLPriming`
                // differential control.
                let frameXLLEncoder = configuration.compactXLLPriming
                    && item.isPriming
                    && configuration.xllCodingMode != .research
                    ? XLLEncoder(
                        codingMode: .research,
                        enforcesOfficialHierarchyGrammar:
                            configuration.officialHierarchyGrammarEnforced
                    )
                    : xllEncoder
                // Pre-encoded private-frame callers cannot expose their source
                // activity, so retain their legacy 4x128 startup contract.
                // Native sessions decide this from the aligned height PCM:
                // Nature's Fury-style silent startup uses 4x128, while an
                // active startup follows the public encoder's cost search.
                let legacyFrameStartupSegmentCount: Int?
                if case .frames = privateXLLXSource,
                   configuration.xllCodingMode != .research,
                   item.frameIndex >= primingFrameCount,
                   item.frameIndex < primingFrameCount + 2 {
                    legacyFrameStartupSegmentCount = 4
                } else {
                    legacyFrameStartupSegmentCount = nil
                }
                var privatePreferredSegmentCount: Int?
                if case .session(let session) = privateXLLXSource {
                    privatePreferredSegmentCount = session
                        .terminalPreferredPublicSegmentCount(at: item.frameIndex)
                }
                // The 4x128 form is the observed Nature's Fury silent-start
                // grammar, and the references pair it only with fully silent
                // access units. The private session can see only the height
                // planes, so a tbh-class start - active bed under silent
                // heights - would otherwise be forced into a partition the
                // corpus never pairs with active content, and the terminal
                // cannot read those first active frames. Gate the startup
                // force on the public compatibility bed as well; an active
                // bed start follows the ordinary 2x256 delivery search.
                if privatePreferredSegmentCount == 4,
                   item.frame.planes.contains(where: { plane in
                       plane.contains(where: { $0 != 0 })
                   }) {
                    privatePreferredSegmentCount = nil
                }
                let nativeSessionStartupSegmentCount = item.frameIndex >= primingFrameCount
                    && item.frameIndex < primingFrameCount + 2
                    ? privatePreferredSegmentCount : nil
                // This is intentionally configuration-gated rather than a
                // delivery default. It lets a reference investigation hold the
                // public/private XLL-X timeline constant while comparing
                // 2x256, 4x128, or 8x64 syntax.
                let forcedSegmentCount = legacyFrameStartupSegmentCount
                    ?? nativeSessionStartupSegmentCount
                    ?? configuration.forcedXLLSegmentCount
                    ?? privatePreferredSegmentCount
                let xll = try frameXLLEncoder.encode(
                    frame: item.frame,
                    useSevenOneHierarchy: configuration.profile == .dtsHDMA
                        && item.frame.format.layout == .sevenOne,
                    coreReconstruction: xllCoreReconstruction,
                    // DTS:X uses the Core-residual hierarchy observed in the
                    // references. Ordinary HDMA without XLL-X keeps its existing
                    // full-primary policy.
                    coreAssociationPolicy: privateXLLXSource == nil
                        ? configuration.coreAssociationPolicy
                        : privateCoreAssociationPolicy,
                    privateExtensionProvider: privateXLLXSource.map { privateSource in
                        { segmentationPlan in
                            switch privateSource {
                            case .frames(let frames):
                                let frame = frames[item.frameIndex]
                                let ast = try DTSXPrivateFrameAST.parse(frame[...])
                                _ = try DTSXPrivateFrameDecoder.decode(
                                    ast,
                                    segmentCount: segmentationPlan.segmentCount,
                                    segmentSampleCount: segmentationPlan.segmentSampleCount
                                )
                                return frame
                            case .session(let session):
                                return try session.encodeFrame(
                                    at: item.frameIndex,
                                    segmentationPlan: segmentationPlan
                                )
                            }
                        }
                    },
                    forcedSegmentCount: forcedSegmentCount
                )
                guard let segmentationPlan = xll.info.segmentationPlan else {
                    throw DTSError.malformed("encoded public XLL frame has no segmentation plan")
                }
                if let coreBytes = item.coreBytes {
                    var accessUnit = Data()
                    accessUnit.append(coreBytes)
                    accessUnit.append(try exssWriter.wrap(
                        xllFrame: xll,
                        backwardCompatibleCore: true,
                        assetDescriptorProfile: exssAssetDescriptorProfile
                    ))
                    return EncodedAccessUnit(
                        data: accessUnit,
                        segmentationPlan: segmentationPlan
                    )
                }
                return EncodedAccessUnit(
                    data: try exssWriter.wrap(xllFrame: xll),
                    segmentationPlan: segmentationPlan
                )
            }
        }

        for frameIndex in 0..<totalFrameCount {
            let isPriming = frameIndex < primingFrameCount
            let frame = isPriming
                ? silentFrame
                : try sourceFrame(
                    from: pcm,
                    sourceFrameIndex: frameIndex - primingFrameCount
                )
            let coreBytes: Data?
            if coreEncoderSession != nil {
                coreBytes = try coreEncoderSession!.encode(
                    try coreFrame(
                        from: pcm,
                        accessUnitIndex: frameIndex,
                        applyingDeclaredDownmixScale: coreCarriesDeclaredDownmixScale
                    )
                )
            } else {
                coreBytes = nil
            }
            let decodedCore = try coreBytes.map { try coreDecoder.decode(frame: $0) }
            pendingWorkItems.append(FrameWorkItem(
                frameIndex: frameIndex,
                frame: frame,
                decodedCore: decodedCore,
                coreBytes: coreBytes,
                isPriming: isPriming
            ))

            if pendingWorkItems.count == batchCapacity || frameIndex + 1 == totalFrameCount {
                let accessUnits = try encodeBatch(pendingWorkItems)
                for accessUnit in accessUnits {
                    if let accessUnitOutput {
                        try accessUnitOutput(accessUnit.data)
                    } else {
                        stream!.append(accessUnit.data)
                    }
                    segmentationPlans.append(accessUnit.segmentationPlan)
                }
                completedAccessUnitCount += accessUnits.count
                pendingWorkItems.removeAll(keepingCapacity: true)
            }
        }
        let privateStream: DTSXPrivateEncodedStream?
        if case .session(let session) = privateXLLXSource {
            privateStream = try session.finalize(parallelWorkerCount: parallelWorkerCount)
        } else {
            privateStream = nil
        }
        progress?(progressTotal, progressTotal)
        return InternalEncodedResult(
            stream: stream,
            privateStream: privateStream,
            segmentationPlans: segmentationPlans
        )
    }

    private func requiredInMemoryStream(_ stream: Data?) throws -> Data {
        guard let stream else {
            throw DTSError.malformed("in-memory DTS HDMA encoding produced no stream")
        }
        return stream
    }

    private func sourceFrame(
        from pcm: PCMBuffer,
        sourceFrameIndex: Int
    ) throws -> PCMBuffer {
        let start = sourceFrameIndex * XLLSyntax.frameSampleCount
        let availableCount = min(XLLSyntax.frameSampleCount, pcm.sampleCount - start)
        guard start >= 0, availableCount > 0 else {
            throw DTSError.valueOutOfRange(
                field: "HDMA source frame",
                value: String(sourceFrameIndex)
            )
        }
        if availableCount == XLLSyntax.frameSampleCount {
            return try pcm.frame(at: start, count: XLLSyntax.frameSampleCount)
        }
        let planes = pcm.planes.map { plane in
            Array(plane[start..<(start + availableCount)])
                + Array(repeating: Int32(0), count: XLLSyntax.frameSampleCount - availableCount)
        }
        return try PCMBuffer(format: pcm.format, planes: planes)
    }

    private func coreFrame(
        from pcm: PCMBuffer,
        accessUnitIndex: Int,
        applyingDeclaredDownmixScale: Bool = false
    ) throws -> PCMBuffer {
        let coreFormat = try PCMFormat(
            sampleRate: pcm.format.sampleRate,
            bitDepth: pcm.format.bitDepth,
            layout: .fiveOneSide
        )
        var planes = Array(
            repeating: Array(repeating: Int32(0), count: XLLSyntax.frameSampleCount),
            count: DTSChannelLayout.fiveOneSide.channelCount
        )
        let globalStart = accessUnitIndex * XLLSyntax.frameSampleCount
        for outputChannel in planes.indices {
            // The 64x LFE interpolator delays by 256 samples; the QMF full-band
            // path delays by 512. These per-path pre-rolls reproduce the former
            // whole-buffer layout without retaining it.
            let corePathDelay = outputChannel == 3 ? 256 : XLLSyntax.frameSampleCount
            let preRoll = XLLSyntax.coreCompatiblePrimingSampleCount - corePathDelay
            for frameSample in 0..<XLLSyntax.frameSampleCount {
                let sourceSample = globalStart + frameSample - preRoll
                guard pcm.planes[0].indices.contains(sourceSample) else { continue }
                switch outputChannel {
                case 0, 1, 2, 3:
                    // With the Core-residual hierarchy the declared constant
                    // DownmixScale (473) covers all six Core channels, so the
                    // pass-through channels must carry the same -3.0103 dB
                    // fold as the surround pair, using the identical Q30
                    // constant and rounding. The reference decoder plays
                    // clip23(Core x sqrt(2)) directly during first-frame
                    // recovery; an unscaled Core turns any active start into
                    // a +3 dB hard-clipped burst.
                    planes[outputChannel][frameSample] = applyingDeclaredDownmixScale
                        ? DTSBedRenderer.equalPowerSum(pcm.planes[outputChannel][sourceSample], 0)
                        : pcm.planes[outputChannel][sourceSample]
                case 4:
                    planes[outputChannel][frameSample] = pcm.format.layout == .sevenOne
                        ? DTSBedRenderer.equalPowerSum(
                            pcm.planes[4][sourceSample],
                            pcm.planes[6][sourceSample]
                        )
                        : pcm.planes[4][sourceSample]
                case 5:
                    planes[outputChannel][frameSample] = pcm.format.layout == .sevenOne
                        ? DTSBedRenderer.equalPowerSum(
                            pcm.planes[5][sourceSample],
                            pcm.planes[7][sourceSample]
                        )
                        : pcm.planes[5][sourceSample]
                default:
                    preconditionFailure("unexpected Core channel")
                }
            }
        }
        return try PCMBuffer(format: coreFormat, planes: planes)
    }
}
