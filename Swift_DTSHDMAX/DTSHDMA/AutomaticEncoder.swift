import Foundation

public enum DTSDetectedInput: String, Sendable, Codable {
    case fiveOnePCM = "5.1PCM"
    case sevenOnePCM = "7.1PCM"
    case imaxPCM = "12.1PCM"
    case atmosMaster = "AtmosMaster"
}

public enum DTSEncodedProduct: String, Sendable, Codable {
    case dtsHDMA = "DTS HDMA"
    case dtsxHDMA = "DTS:X HDMA"
    case dtsxIMAX = "DTS:X IMAX HDMA"
}

public enum DTSObjectMetadataDisposition: String, Sendable, Codable {
    case notApplicable
    case renderedToSevenOneBed
    case renderedToSevenOneFour
    case renderedToIMAX
}

public struct DTSAutomaticVerificationReport: Sendable, Equatable, Codable {
    public let hdma: DTSHDMAVerificationReport?
    public let dtsx: DTSXNativeEncodingReport?
    public let dtsxStructure: DTSXStreamVerificationReport?

    public var streamKind: DTSHDMAStreamKind {
        hdma?.streamKind ?? dtsx!.streamKind
    }

    public var product: DTSHDMAProduct? { streamKind.product }

    public var isBitExact: Bool {
        if let hdma { return hdma.isBitExact }
        guard let dtsx else { return false }
        return dtsx.isInternallyBitExact
            && dtsxStructure?.isStructurallyValid == true
            && dtsxStructure?.privateFrameCount == dtsx.accessUnitCount
    }

    public init(hdma: DTSHDMAVerificationReport) {
        self.hdma = hdma
        dtsx = nil
        dtsxStructure = nil
    }

    public init(
        dtsx: DTSXNativeEncodingReport,
        structure: DTSXStreamVerificationReport
    ) {
        hdma = nil
        self.dtsx = dtsx
        dtsxStructure = structure
    }
}

public struct DTSAutomaticEncodeReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let resolvedInputPath: String
    public let outputPath: String
    public let detectedInput: DTSDetectedInput
    public let encodedProduct: DTSEncodedProduct
    public let frameRate: DTSFrameRate
    public let encodeMode: DTSEncodeMode
    public let dtsxVision: DTSXVision?
    public let objectMetadataDisposition: DTSObjectMetadataDisposition
    public let atmosBedChannelCount: Int?
    public let atmosObjectCount: Int?
    public let deliveryArtifacts: DTSHDMADeliveryArtifactReport
    /// Whole-stream decode/QC is available through explicit verify commands.
    /// Product encoding does not activate it implicitly.
    public let validationPerformed: Bool
    public let verification: DTSAutomaticVerificationReport?
}

public enum DTSAutomaticEncoder {
    private enum EncodingSource {
        case hdma(PCMBuffer)
        case dtsx(rendered: DTS714PCMBuffer, compatibilityBed: PCMBuffer)
        case imax(rendered: DTSIMAXPCMBuffer, compatibilityBed: PCMBuffer)
    }

    private struct LoadedSource {
        let resolvedInputURL: URL
        let detectedInput: DTSDetectedInput
        let encodedProduct: DTSEncodedProduct
        let objectMetadataDisposition: DTSObjectMetadataDisposition
        let atmosBedChannelCount: Int?
        let atmosObjectCount: Int?
        let frameRate: DTSFrameRate
        let source: EncodingSource
        let deliveryInput: DTSHDMADeliveryInput
    }

    /// Preserve the existing typed entry point and its default 7.1.4 path.
    public static func encode(
        inputURL: URL, outputURL: URL, frameRateOverride: DTSFrameRate? = nil,
        encodeMode: DTSEncodeMode = .auto, progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> DTSAutomaticEncodeReport {
        try encode(inputURL: inputURL, outputURL: outputURL, frameRateOverride: frameRateOverride,
                   encodeMode: encodeMode, dtsxVision: .sevenOneFour, progress: progress)
    }

    public static func encode(
        inputURL: URL,
        outputURL: URL,
        frameRateOverride: DTSFrameRate? = nil,
        encodeMode: DTSEncodeMode = .auto,
        dtsxVision: DTSXVision,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> DTSAutomaticEncodeReport {
        let progressTotal = Int64(1_000)
        progress?(0, progressTotal)
        let input = inputURL.standardizedFileURL
        let output = outputURL.standardizedFileURL
        guard output.pathExtension.lowercased() == "dtshd" else {
            throw DTSError.invalidArgument("automatic product output must use the .dtshd extension")
        }
        guard input.path != output.path else {
            throw DTSError.invalidArgument("input and output paths must differ")
        }
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw DTSError.io("input does not exist: \(input.path)")
        }

        let source = try loadSource(
            inputURL: input,
            frameRateOverride: frameRateOverride,
            dtsxVision: dtsxVision,
            progress: { completed, total in
                progress?(
                    Int64(250) * completed / max(1, total),
                    progressTotal
                )
            }
        )
        progress?(250, progressTotal)
        let artifacts: DTSHDMADeliveryArtifactReport
        switch source.source {
        case .hdma(let pcm):
            try HDMAEncoder(
                format: pcm.format,
                tailPolicy: .zeroPad,
                frameRate: source.frameRate,
                encodeMode: encodeMode
            ).encode(pcm, to: output, progress: { completed, total in
                progress?(
                    250 + Int64(600 * completed / max(1, total)),
                    progressTotal
                )
            })
            artifacts = try DTSHDMADeliveryArtifactWriter.writeCompleted(
                pcm: pcm,
                input: source.deliveryInput,
                outputURL: output,
                frameRate: source.frameRate
            )
            progress?(980, progressTotal)

        case .dtsx(let rendered, let compatibilityBed):
            _ = try DTSXNativeHDMAEncoder(encodeMode: encodeMode).encode(
                source: rendered,
                to: output,
                frameRate: source.frameRate,
                progress: { completed, total in
                    progress?(
                        250 + Int64(600) * Int64(completed) / Int64(max(1, total)),
                        progressTotal
                    )
                }
            )
            artifacts = try DTSHDMADeliveryArtifactWriter.writeCompleted(
                pcm: compatibilityBed,
                input: source.deliveryInput,
                outputURL: output,
                frameRate: source.frameRate
            )
            progress?(980, progressTotal)
        case .imax(let rendered, let compatibilityBed):
            let encoded = try DTSIMAXNativeHDMAEncoder(encodeMode: encodeMode).encode(
                source: rendered, to: output, frameRate: source.frameRate,
                progress: { completed, total in
                    progress?(250 + Int64(600) * Int64(completed) / Int64(max(1, total)), progressTotal)
                }
            )
            artifacts = try DTSHDMADeliveryArtifactWriter.writeCompleted(
                pcm: compatibilityBed, input: source.deliveryInput, outputURL: output, frameRate: source.frameRate
            )
            guard encoded.privatePCMVerified else { throw DTSError.malformed("IMAX private PCM verification failed") }
            progress?(980, progressTotal)
        }

        let report = DTSAutomaticEncodeReport(
            inputPath: input.path,
            resolvedInputPath: source.resolvedInputURL.path,
            outputPath: output.path,
            detectedInput: source.detectedInput,
            encodedProduct: source.encodedProduct,
            frameRate: source.frameRate,
            encodeMode: encodeMode,
            dtsxVision: dtsxVision,
            objectMetadataDisposition: source.objectMetadataDisposition,
            atmosBedChannelCount: source.atmosBedChannelCount,
            atmosObjectCount: source.atmosObjectCount,
            deliveryArtifacts: artifacts,
            validationPerformed: false,
            verification: nil
        )
        progress?(progressTotal, progressTotal)
        return report
    }

    private static func loadSource(
        inputURL: URL,
        frameRateOverride: DTSFrameRate?,
        dtsxVision: DTSXVision,
        progress: ((Int64, Int64) -> Void)?
    ) throws -> LoadedSource {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
            throw DTSError.io("input does not exist: \(inputURL.path)")
        }

        if !isDirectory.boolValue, try IMFIABReader.hasMXFHeader(inputURL) {
            return try loadAtmos(
                inputURL: inputURL,
                resolvedURL: inputURL,
                frameRateOverride: frameRateOverride,
                dtsxVision: dtsxVision,
                progress: progress
            )
        }

        if !isDirectory.boolValue, try hasWaveHeader(inputURL) {
            if try hasADMMetadata(inputURL) {
                return try loadAtmos(
                    inputURL: inputURL,
                    resolvedURL: inputURL,
                    frameRateOverride: frameRateOverride,
                    dtsxVision: dtsxVision,
                    progress: progress
                )
            }
            if dtsxVision == .imax { return try loadIMAXWave(inputURL: inputURL, frameRateOverride: frameRateOverride) }
            let pcm = try WaveFile.read(from: inputURL)
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: nil,
                override: frameRateOverride,
                sourceDescription: "PCM WAVE"
            )
            switch pcm.format.layout {
            case .fiveOneSide:
                return LoadedSource(
                    resolvedInputURL: inputURL,
                    detectedInput: .fiveOnePCM,
                    encodedProduct: .dtsHDMA,
                    objectMetadataDisposition: .notApplicable,
                    atmosBedChannelCount: nil,
                    atmosObjectCount: nil,
                    frameRate: frameRate,
                    source: .hdma(pcm),
                    deliveryInput: DTSHDMADeliveryInput(
                        inputURL: inputURL,
                        resolvedInputURL: inputURL,
                        detectedInput: .fiveOnePCM,
                        sourceChannelCount: pcm.format.layout.channelCount
                    )
                )
            case .sevenOne:
                return LoadedSource(
                    resolvedInputURL: inputURL,
                    detectedInput: .sevenOnePCM,
                    encodedProduct: .dtsHDMA,
                    objectMetadataDisposition: .notApplicable,
                    atmosBedChannelCount: nil,
                    atmosObjectCount: nil,
                    frameRate: frameRate,
                    source: .hdma(pcm),
                    deliveryInput: DTSHDMADeliveryInput(
                        inputURL: inputURL,
                        resolvedInputURL: inputURL,
                        detectedInput: .sevenOnePCM,
                        sourceChannelCount: pcm.format.layout.channelCount
                    )
                )
            case .stereo:
                throw DTSError.unsupported("automatic HDMA encoding accepts 5.1, 7.1, or an Atmos master")
            }
        }

        let resolved = try AtmosInputReader.resolve(url: inputURL)
        if try hasWaveHeader(resolved), try !hasADMMetadata(resolved) {
            if dtsxVision == .imax { return try loadIMAXWave(inputURL: resolved, frameRateOverride: frameRateOverride) }
            let pcm = try WaveFile.read(from: resolved)
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: nil,
                override: frameRateOverride,
                sourceDescription: "PCM WAVE"
            )
            let detectedInput: DTSDetectedInput
            switch pcm.format.layout {
            case .fiveOneSide: detectedInput = .fiveOnePCM
            case .sevenOne: detectedInput = .sevenOnePCM
            case .stereo:
                throw DTSError.unsupported("automatic HDMA encoding accepts 5.1, 7.1, or an Atmos master")
            }
            return LoadedSource(
                resolvedInputURL: resolved,
                detectedInput: detectedInput,
                encodedProduct: .dtsHDMA,
                objectMetadataDisposition: .notApplicable,
                atmosBedChannelCount: nil,
                atmosObjectCount: nil,
                frameRate: frameRate,
                source: .hdma(pcm),
                deliveryInput: DTSHDMADeliveryInput(
                    inputURL: inputURL,
                    resolvedInputURL: resolved,
                    detectedInput: detectedInput,
                    sourceChannelCount: pcm.format.layout.channelCount
                )
            )
        }
        return try loadAtmos(
            inputURL: inputURL,
            resolvedURL: resolved,
            frameRateOverride: frameRateOverride,
            dtsxVision: dtsxVision,
            progress: progress
        )
    }

    private static func loadAtmos(
        inputURL: URL,
        resolvedURL: URL,
        frameRateOverride: DTSFrameRate?,
        dtsxVision: DTSXVision,
        progress: ((Int64, Int64) -> Void)?
    ) throws -> LoadedSource {
        if dtsxVision == .imax {
            let master: AtmosMaster
            let rendered: DTSIMAXPCMBuffer
            if resolvedURL.pathExtension.lowercased() == "mxf" {
                let iab = try IMFIABReader.read(url: resolvedURL)
                master = iab.master
                rendered = try DTSIMAXRenderer.render(iab: iab, progress: progress)
            } else {
                master = try AtmosInputReader.read(url: resolvedURL)
                rendered = try DTSIMAXRenderer.render(master: master, progress: progress)
            }
            let rate = try DTSFrameRate.resolve(metadataFramesPerSecond: master.framesPerSecond,
                                                override: frameRateOverride, sourceDescription: "Atmos IMAX render")
            return LoadedSource(
                resolvedInputURL: resolvedURL, detectedInput: .atmosMaster, encodedProduct: .dtsxIMAX,
                objectMetadataDisposition: .renderedToIMAX, atmosBedChannelCount: master.bedChannels.count,
                atmosObjectCount: master.objects.count, frameRate: rate,
                source: .imax(rendered: rendered, compatibilityBed: try DTSIMAXCompatibilityBedRenderer.render(rendered)),
                deliveryInput: DTSHDMADeliveryInput(inputURL: inputURL, resolvedInputURL: resolvedURL,
                    detectedInput: .atmosMaster, sourceChannelCount: master.audioFormat.channelCount,
                    atmosBedChannelCount: master.bedChannels.count, atmosObjectCount: master.objects.count, renderedFromAtmos: true, dtsxVision: .imax)
            )
        }
        let master: AtmosMaster
        let rendered: DTS714PCMBuffer
        if resolvedURL.pathExtension.lowercased() == "mxf" {
            let iab = try IMFIABReader.read(url: resolvedURL)
            master = iab.master
            rendered = try DTS714Renderer.render(iab: iab, progress: progress)
        } else {
            master = try AtmosInputReader.read(url: resolvedURL)
            rendered = try DTS714Renderer.render(master: master, progress: progress)
        }
        let frameRate = try DTSFrameRate.resolve(
            metadataFramesPerSecond: master.framesPerSecond,
            override: frameRateOverride,
            sourceDescription: "Atmos master (\(master.version))"
        )
        let compatibilityBed = try DTS714CompatibilityBedRenderer.render(rendered)
        return LoadedSource(
            resolvedInputURL: resolvedURL,
            detectedInput: .atmosMaster,
            encodedProduct: .dtsxHDMA,
            objectMetadataDisposition: .renderedToSevenOneFour,
            atmosBedChannelCount: master.bedChannels.count,
            atmosObjectCount: master.objects.count,
            frameRate: frameRate,
            source: .dtsx(
                rendered: rendered,
                compatibilityBed: compatibilityBed
            ),
            deliveryInput: DTSHDMADeliveryInput(
                inputURL: inputURL,
                resolvedInputURL: resolvedURL,
                detectedInput: .atmosMaster,
                sourceChannelCount: master.audioFormat.channelCount,
                atmosBedChannelCount: master.bedChannels.count,
                atmosObjectCount: master.objects.count,
                renderedFromAtmos: true
            )
        )
    }

    private static func loadIMAXWave(inputURL: URL, frameRateOverride: DTSFrameRate?) throws -> LoadedSource {
        let pcm = try WaveFile.readIMAX(from: inputURL)
        var planes = pcm.planes
        _ = DTS714RenderGuard.apply(to: &planes, imax: true)
        let rendered = try DTSIMAXPCMBuffer(planes: planes)
        let rate = try DTSFrameRate.resolve(metadataFramesPerSecond: nil, override: frameRateOverride, sourceDescription: "IMAX PCM WAVE")
        return LoadedSource(resolvedInputURL: inputURL, detectedInput: .imaxPCM, encodedProduct: .dtsxIMAX,
            objectMetadataDisposition: .notApplicable, atmosBedChannelCount: nil, atmosObjectCount: nil,
            frameRate: rate, source: .imax(rendered: rendered, compatibilityBed: try DTSIMAXCompatibilityBedRenderer.render(rendered)),
            deliveryInput: DTSHDMADeliveryInput(inputURL: inputURL, resolvedInputURL: inputURL, detectedInput: .imaxPCM, sourceChannelCount: 13, dtsxVision: .imax))
    }

    private static func hasWaveHeader(_ url: URL) throws -> Bool {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DTSError.io("cannot open \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 12) ?? Data()
        } catch {
            throw DTSError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
        guard prefix.count == 12 else { return false }
        let container = String(decoding: prefix[0..<4], as: UTF8.self)
        let form = String(decoding: prefix[8..<12], as: UTF8.self)
        return (container == "RIFF" || container == "RF64") && form == "WAVE"
    }

    private static func hasADMMetadata(_ url: URL) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw DTSError.io("cannot inspect \(url.path): \(error.localizedDescription)")
        }
        guard let size = attributes[.size] as? NSNumber else {
            throw DTSError.io("cannot determine input size: \(url.path)")
        }
        let fileByteCount = size.uint64Value
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DTSError.io("cannot open \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        var cursor: UInt64 = 12
        var rf64DataByteCount: UInt64?
        while cursor <= fileByteCount, fileByteCount - cursor >= 8 {
            do { try handle.seek(toOffset: cursor) }
            catch { throw DTSError.io("cannot seek \(url.path): \(error.localizedDescription)") }
            let header: Data
            do { header = try handle.read(upToCount: 8) ?? Data() }
            catch { throw DTSError.io("cannot read WAVE chunk: \(error.localizedDescription)") }
            guard header.count == 8 else { return false }
            let identifier = String(decoding: header[0..<4], as: UTF8.self)
            let declaredSize = UInt64(header[4])
                | (UInt64(header[5]) << 8)
                | (UInt64(header[6]) << 16)
                | (UInt64(header[7]) << 24)
            if identifier == "axml" || identifier == "chna" { return true }

            if identifier == "ds64", declaredSize >= 16 {
                let body: Data
                do { body = try handle.read(upToCount: 16) ?? Data() }
                catch { throw DTSError.io("cannot read RF64 ds64 chunk: \(error.localizedDescription)") }
                guard body.count == 16 else { return false }
                var dataSize: UInt64 = 0
                for index in 0..<8 {
                    dataSize |= UInt64(body[8 + index]) << UInt64(index * 8)
                }
                rf64DataByteCount = dataSize
            }

            let effectiveSize = identifier == "data" && declaredSize == UInt64(UInt32.max)
                ? rf64DataByteCount
                : declaredSize
            guard let effectiveSize else {
                throw DTSError.malformed("RF64 data chunk precedes its ds64 size")
            }
            let paddedSize = effectiveSize + (effectiveSize & 1)
            let (next, overflow) = cursor.addingReportingOverflow(8 + paddedSize)
            guard !overflow, next > cursor, next <= fileByteCount else { return false }
            cursor = next
        }
        return false
    }

}
