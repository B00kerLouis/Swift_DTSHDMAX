import Foundation

public struct PCMHashReport: Sendable, Equatable, Codable {
    public let canonicalEncoding: String
    public let format: PCMFormat
    public let sampleCount: Int
    public let sha256: String
}

public enum PCMHasher {
    public static let canonicalEncoding = "s24le interleaved PCM in WAVE channel order"

    public static func report(_ pcm: PCMBuffer) throws -> PCMHashReport {
        PCMHashReport(
            canonicalEncoding: canonicalEncoding,
            format: pcm.format,
            sampleCount: pcm.sampleCount,
            sha256: try sha256(pcm)
        )
    }

    public static func sha256(_ pcm: PCMBuffer, frames: Range<Int>? = nil) throws -> String {
        let range = frames ?? 0..<pcm.sampleCount
        guard range.lowerBound >= 0, range.upperBound <= pcm.sampleCount else {
            throw DTSError.valueOutOfRange(
                field: "PCM hash frame range",
                value: "\(range.lowerBound)..<\(range.upperBound)"
            )
        }

        var hasher = SHA256Hasher()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(1 << 16)
        for frame in range {
            for channel in pcm.planes.indices {
                let sample = UInt32(bitPattern: pcm.planes[channel][frame]) & 0x00ff_ffff
                bytes.append(UInt8(sample & 0xff))
                bytes.append(UInt8((sample >> 8) & 0xff))
                bytes.append(UInt8((sample >> 16) & 0xff))
            }
            if bytes.count >= 1 << 16 {
                hasher.update(bytes)
                bytes.removeAll(keepingCapacity: true)
            }
        }
        hasher.update(bytes)
        return hasher.finalizeHex()
    }
}

public struct DTSHDMAVerificationReport: Sendable, Equatable, Codable {
    public let profile: DTSHDMAProfile
    public let streamKind: DTSHDMAStreamKind
    public let product: DTSHDMAProduct?
    public let frameRate: DTSFrameRate?
    public let format: PCMFormat
    public let canonicalPCMEncoding: String
    public let inputSampleCount: Int
    public let decodedSampleCount: Int
    public let encodedByteCount: Int
    public let streamSHA256: String
    public let inputPCMSHA256: String
    public let decodedPrefixPCMSHA256: String
    public let decodedPaddedPCMSHA256: String
    public let comparison: PCMPaddedComparison
    public let streamStructure: DTSHDMAStreamStructureReport
    public let productContainer: DTSHDProductContainerReport?
    public let frameQuality: DTSFrameQualityReport
    public let xllPBR: XLLPBRVerificationReport
    public let isBitExact: Bool
}

public struct DTSHDMAVerificationResult: Sendable, Equatable {
    public let stream: Data
    public let decodedPCM: PCMBuffer
    public let report: DTSHDMAVerificationReport
}

public enum DTSHDMAVerifier {
    public static func verify(
        _ pcm: PCMBuffer,
        profile: DTSHDMAProfile = .dtsHDMA,
        tailPolicy: DTSTailPolicy = .zeroPad,
        frameRate: DTSFrameRate = .fps24
    ) throws -> DTSHDMAVerificationResult {
        let configuration = DTSHDMAEncoderConfiguration(
            format: pcm.format,
            profile: profile,
            tailPolicy: tailPolicy
        )
        let elementaryStream = try DTSHDMAEncoder(configuration: configuration).encode(pcm)
        let decoded = try DTSHDMADecoder().decode(elementaryStream, as: profile.streamKind)
        let streamStructure = try DTSHDMAStreamStructureVerifier.verify(
            elementaryStream,
            expectedStreamKind: profile.streamKind
        )
        let comparison = try PCMComparator.compareWithZeroPadding(
            expected: pcm,
            paddedActual: decoded
        )
        let inputHash = try PCMHasher.sha256(pcm)
        let decodedPrefixHash = try PCMHasher.sha256(decoded, frames: 0..<pcm.sampleCount)
        let stream: Data
        switch profile {
        case .dtsHDMA:
            stream = try DTSHDFileContainer.wrapHDMA(
                elementaryStream: elementaryStream,
                format: pcm.format,
                sourceSampleCount: pcm.sampleCount,
                frameRate: frameRate
            )
        case .xllStandalone:
            stream = elementaryStream
        }
        let productContainer = profile == .dtsHDMA
            ? try DTSHDProductContainerVerifier.verify(stream)
            : nil
        let quality = try qualityReports(for: stream)
        let report = DTSHDMAVerificationReport(
            profile: profile,
            streamKind: profile.streamKind,
            product: profile.streamKind.product,
            frameRate: profile == .dtsHDMA ? frameRate : nil,
            format: pcm.format,
            canonicalPCMEncoding: PCMHasher.canonicalEncoding,
            inputSampleCount: pcm.sampleCount,
            decodedSampleCount: decoded.sampleCount,
            encodedByteCount: stream.count,
            streamSHA256: SHA256Hasher.hash(stream),
            inputPCMSHA256: inputHash,
            decodedPrefixPCMSHA256: decodedPrefixHash,
            decodedPaddedPCMSHA256: try PCMHasher.sha256(decoded),
            comparison: comparison,
            streamStructure: streamStructure,
            productContainer: productContainer,
            frameQuality: quality.frame,
            xllPBR: quality.xll,
            isBitExact: comparison.isBitExact
                && inputHash == decodedPrefixHash
                && streamStructure.isValid
                && productContainer?.isValid != false
                && quality.frame.isStructurallyValid
                && quality.xll.allFramesParsed
                && quality.xll.fieldWidthsMatchStrictProfile
        )
        guard report.isBitExact else {
            throw DTSError.malformed("HDMA verification did not reproduce the canonical input PCM")
        }
        return DTSHDMAVerificationResult(stream: stream, decodedPCM: decoded, report: report)
    }

    private static func qualityReports(
        for stream: Data
    ) throws -> (frame: DTSFrameQualityReport, xll: XLLPBRVerificationReport) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-dtshd-qc-\(UUID().uuidString).dtshd")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try stream.write(to: url, options: .atomic)
        } catch {
            throw DTSError.io("cannot stage generated DTS-HD stream for frame QC: \(error.localizedDescription)")
        }
        return try (
            DTSFrameQualityControl.inspect(inputURL: url),
            XLLPBRVerifier.verify(inputURL: url)
        )
    }
}
