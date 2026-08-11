import Foundation

/// Final DTS HDMA product encoder.
/// Every access unit contains a backward-compatible 5.1 DTS Core followed by
/// an ExSS/XLL asset. A 7.1 input retains all eight channels in XLL.
public struct HDMAEncoder: Sendable {
    public let format: PCMFormat
    public let tailPolicy: DTSTailPolicy
    public let frameRate: DTSFrameRate
    public let xllCodingMode: XLLCodingMode
    public let coreAssociationPolicy: XLLCoreAssociationPolicy
    public let compactXLLPriming: Bool
    public let forcedXLLSegmentCount: Int?

    public init(
        format: PCMFormat,
        tailPolicy: DTSTailPolicy = .reject,
        frameRate: DTSFrameRate = .fps24,
        xllCodingMode: XLLCodingMode = .terminalConservative,
        coreAssociationPolicy: XLLCoreAssociationPolicy = .fullPrimaryChannels,
        compactXLLPriming: Bool = false,
        forcedXLLSegmentCount: Int? = nil
    ) {
        self.format = format
        self.tailPolicy = tailPolicy
        self.frameRate = frameRate
        self.xllCodingMode = xllCodingMode
        self.coreAssociationPolicy = coreAssociationPolicy
        self.compactXLLPriming = compactXLLPriming
        self.forcedXLLSegmentCount = forcedXLLSegmentCount
    }

    public func encode(
        _ pcm: PCMBuffer,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Data {
        guard pcm.format == format else {
            throw DTSError.invalidArgument("PCM format does not match HDMA encoder format")
        }
        guard pcm.format.layout == .fiveOneSide || pcm.format.layout == .sevenOne else {
            throw DTSError.unsupported("DTS HDMA accepts 5.1(side) or 7.1 PCM")
        }
        let elementary = try DTSHDMAEncoder(configuration: DTSHDMAEncoderConfiguration(
            format: pcm.format,
            profile: .dtsHDMA,
            deterministic: true,
            tailPolicy: tailPolicy,
            xllCodingMode: xllCodingMode,
            coreAssociationPolicy: coreAssociationPolicy,
            compactXLLPriming: compactXLLPriming,
            forcedXLLSegmentCount: forcedXLLSegmentCount
        )).encode(pcm, progress: { completed, total in
            progress?(950 * completed / max(1, total), 1_000)
        })
        let stream = try DTSHDFileContainer.wrapHDMA(
            elementaryStream: elementary,
            format: pcm.format,
            sourceSampleCount: pcm.sampleCount,
            frameRate: frameRate
        )
        progress?(1_000, 1_000)
        return stream
    }

    /// Writes the final `.dtshd` product at `outputURL` as each access unit is
    /// encoded. The target file is created before the first XLL batch completes
    /// and grows throughout the job; its DTSHD container metadata is finalized
    /// only after the last access unit is available.
    public func encode(
        _ pcm: PCMBuffer,
        to outputURL: URL,
        progress: ((Int, Int) -> Void)? = nil
    ) throws {
        guard pcm.format == format else {
            throw DTSError.invalidArgument("PCM format does not match HDMA encoder format")
        }
        guard pcm.format.layout == .fiveOneSide || pcm.format.layout == .sevenOne else {
            throw DTSError.unsupported("DTS HDMA accepts 5.1(side) or 7.1 PCM")
        }
        let writer = try DTSHDFileContainer.StreamingWriter(
            outputURL: outputURL,
            format: pcm.format,
            sourceSampleCount: pcm.sampleCount,
            frameRate: frameRate
        )
        do {
            try DTSHDMAEncoder(configuration: DTSHDMAEncoderConfiguration(
                format: pcm.format,
                profile: .dtsHDMA,
                deterministic: true,
                tailPolicy: tailPolicy,
                xllCodingMode: xllCodingMode,
                coreAssociationPolicy: coreAssociationPolicy,
                compactXLLPriming: compactXLLPriming,
                forcedXLLSegmentCount: forcedXLLSegmentCount
            )).encode(pcm, writingAccessUnitsTo: { accessUnit in
                try writer.append(accessUnit: accessUnit)
            }, progress: { completed, total in
                progress?(950 * completed / max(1, total), 1_000)
            })
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
        progress?(1_000, 1_000)
    }
}

/// Configuration for the qualified Atmos-to-DTS:X HDMA path.
public struct DTSXHDMAEncoderConfiguration: Sendable, Equatable, Codable {
    public let deliveryMode: DTSXDeliveryMode
    public let sourceDirectory: String
    public let referenceDirectory: String

    public init(
        deliveryMode: DTSXDeliveryMode,
        sourceDirectory: URL,
        referenceDirectory: URL
    ) {
        self.deliveryMode = deliveryMode
        self.sourceDirectory = sourceDirectory.standardizedFileURL.path
        self.referenceDirectory = referenceDirectory.standardizedFileURL.path
    }

    func validateReferenceFrameRate(_ frameRate: DTSFrameRate) throws {
        let referenceURL = try DTSXReferenceReproducer.referenceURL(
            for: deliveryMode,
            in: URL(fileURLWithPath: referenceDirectory)
        )
        guard let referenceFrameRate = try DTSHDFileContainer.authoringFrameRate(
            at: referenceURL
        ) else {
            throw DTSError.malformed(
                "DTS:X reference has no DTSHD TIMECODE frame rate: \(referenceURL.path)"
            )
        }
        guard referenceFrameRate == frameRate else {
            throw DTSError.invalidArgument(
                "DTS:X frame rate \(frameRate) does not match "
                    + "reference \(referenceFrameRate)"
            )
        }
    }
}

/// Final native DTS:X HDMA product encoder.
///
/// Atmos input is rendered to the canonical 7.1.4 authoring planes, the 7.1
/// compatibility bed is encoded as Core+XLL, and the four height planes are
/// independently serialized into XLL-X. The reference directories remain in
/// the configuration for differential qualification but are never read as
/// output bytes by this encoder.
public struct DTSXHDMAEncoder: Sendable {
    public let configuration: DTSXHDMAEncoderConfiguration

    public init(configuration: DTSXHDMAEncoderConfiguration) {
        self.configuration = configuration
    }

    public func encode(
        master: AtmosMaster,
        to outputURL: URL,
        frameRateOverride: DTSFrameRate? = nil,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> DTSXNativeFileEncodingReport {
        let rendered: DTS714PCMBuffer
        if master.audioFormat.container == .iabMXF {
            rendered = try DTS714Renderer.render(
                iab: IMFIABReader.read(url: master.audioURL)
            )
        } else {
            rendered = try DTS714Renderer.render(master: master)
        }
        let frameRate = try DTSFrameRate.resolve(
            metadataFramesPerSecond: master.framesPerSecond,
            override: frameRateOverride,
            sourceDescription: "Atmos master (\(master.version))"
        )
        try configuration.validateReferenceFrameRate(frameRate)
        return try DTSXNativeHDMAEncoder().encode(
            source: rendered,
            to: outputURL,
            frameRate: frameRate,
            progress: progress
        )
    }

    /// Encodes a complete twelve-plane 7.1.4 authoring source without consulting
    /// or replaying the supplied reference bitstream.
    public func encode(
        sourceDirectory: URL,
        to outputURL: URL,
        frameRate: DTSFrameRate,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> DTSXNativeFileEncodingReport {
        try configuration.validateReferenceFrameRate(frameRate)
        let source = try DTS714SourceSet.load(directory: sourceDirectory)
        return try DTSXNativeHDMAEncoder().encode(
            source: source,
            to: outputURL,
            frameRate: frameRate,
            progress: progress
        )
    }
}
