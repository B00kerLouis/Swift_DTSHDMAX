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
        forcedXLLSegmentCount: Int? = nil
    ) {
        self.format = format
        self.profile = profile
        self.deterministic = deterministic
        self.tailPolicy = tailPolicy
        self.xllCodingMode = xllCodingMode
        self.coreAssociationPolicy = coreAssociationPolicy
        self.compactXLLPriming = compactXLLPriming
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
        let totalFrameCount = sourceFrameCount + primingFrameCount
        let xllEncoder = XLLEncoder(codingMode: configuration.xllCodingMode)
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
                // The two Core-priming access units are the first two access
                // units a terminal ever sees, so they must declare the same
                // channel-set configuration as the rest of the stream. The
                // compact zero-XLL form is eight bytes smaller, but it reaches
                // that size by enabling pairwise decorrelation with a
                // non-identity original-channel order and by sharing entropy
                // parameters across channels — two declarations the delivery
                // profile deliberately never emits. A decoder that latches its
                // channel configuration when it first synchronizes then has to
                // reconfigure at the third access unit. Keep the compact form
                // available to public-XLL differential controls only.
                let frameXLLEncoder = configuration.compactXLLPriming
                    && item.isPriming
                    && configuration.xllCodingMode != .research
                    ? XLLEncoder(codingMode: .research)
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
                let privatePreferredSegmentCount: Int?
                if case .session(let session) = privateXLLXSource {
                    privatePreferredSegmentCount = session
                        .terminalPreferredPublicSegmentCount(at: item.frameIndex)
                } else {
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
                // Delivery pins the mid-stream partition instead of letting a
                // per-frame cost search flip it. Unlike a forced count this
                // still falls back to the ordinary search for any frame the
                // preferred partition cannot express.
                let preferredSegmentCount = forcedSegmentCount == nil
                    ? privatePreferredSegmentCount
                    : nil
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
                    forcedSegmentCount: forcedSegmentCount,
                    preferredSegmentCount: preferredSegmentCount
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
                    try coreFrame(from: pcm, accessUnitIndex: frameIndex)
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
        accessUnitIndex: Int
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
                    planes[outputChannel][frameSample] = pcm.planes[outputChannel][sourceSample]
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
