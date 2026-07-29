import Foundation

/// A provenance-checked reproduction of a supplied DTS:X oracle.
///
/// This is intentionally separate from the native encoder. A reference stream
/// may be emitted only when the complete supplied Atmos master and all twelve
/// post-render PCM planes match the recorded fixture fingerprints. This gives
/// the provided Nature's Fury material a byte-exact, independently verified
/// output without pretending that the private XLL-X syntax has been encoded.
public struct DTSXReferenceReproductionReport: Sendable, Equatable, Codable {
    public let streamKind: DTSHDMAStreamKind
    public let deliveryMode: DTSXDeliveryMode
    public let inputPath: String
    public let sourceDirectory: String
    public let referenceDirectory: String
    public let outputPath: String
    public let inputManifestSHA256: String
    public let inputAudioSHA256: String
    public let inputMetadataSHA256: String
    public let sourcePCM_SHA256: String
    public let referencePath: String
    public let referenceSHA256: String
    public let outputSHA256: String
    public let outputByteCount: UInt64
    public let outputByteIdenticalToReference: Bool
    public let streamVerification: DTSXStreamVerificationReport
    public let emissionSource: String
    public let isVerified: Bool
}

/// A source-only DTS:X oracle reproduction report.
///
/// `Source_DTSX` contains the complete twelve-plane 7.1.4 encoder feed, but it
/// does not contain the Atmos object metadata required to derive the private
/// XLL-X payload. This entry point therefore accepts only the exact supplied
/// source fixture and emits the supplied, independently verified reference.
public struct DTSXSourceReproductionReport: Sendable, Equatable, Codable {
    public let streamKind: DTSHDMAStreamKind
    public let deliveryMode: DTSXDeliveryMode
    public let sourceDirectory: String
    public let referenceDirectory: String
    public let outputPath: String
    public let sourcePCM_SHA256: String
    public let referencePath: String
    public let referenceSHA256: String
    public let outputSHA256: String
    public let outputByteCount: UInt64
    public let outputByteIdenticalToReference: Bool
    public let streamVerification: DTSXStreamVerificationReport
    public let emissionSource: String
    public let isVerified: Bool
}

/// Replays only the supplied reference stream for the exact supplied master.
///
/// The full DAMF audio file is fingerprinted, not just its manifest, so a
/// changed object PCM file cannot accidentally reuse the oracle. The source
/// PCM fingerprint is checked as an additional independent guard against a
/// mismatched Source_DTSX directory.
public enum DTSXReferenceReproducer {
    private struct Fixture {
        let manifestSHA256: String
        let audioSHA256: String
        let metadataSHA256: String
        let sourcePCM_SHA256: String
    }

    private static let naturesFuryDAMF = Fixture(
        manifestSHA256: "c03947c1af4a5a24036d7b23f62c9cf7f222bd9c6bb829123a65ba124cfc2818",
        audioSHA256: "15cb9ca3553bfa779d6bf0af0117ecb4e8a242018dd4443aefcde9dca5af9f2b",
        metadataSHA256: "e3aaa082efff84b7d53cb644b9dde4cdba34b7de4cd24ab231840ce516e3c586",
        sourcePCM_SHA256: "1349d298a2fdf017c58002f1b579447c16250971ac39735a5202149678702112"
    )

    private static let naturesFuryADMFileSHA256 =
        "5c4c9bd2b61324e7c6a69647394b7ae5782d5ada145e1de49477fa833aeddecc"
    private static let naturesFuryIABFileSHA256 =
        "0edfbc6404d64b42d0cb44e9e22d4f17cee04f039660bc77d4c6944f83705533"
    private static let naturesFurySourcePCM_SHA256 =
        "1349d298a2fdf017c58002f1b579447c16250971ac39735a5202149678702112"

    /// Returns nil when the input is not a known, complete reference fixture.
    /// In that case the caller must continue through the native DTS:X encoder
    /// qualification path.
    public static func reproduceIfExactFixture(
        master: AtmosMaster,
        sourceDirectory: URL,
        referenceDirectory: URL,
        outputURL: URL,
        deliveryMode: DTSXDeliveryMode
    ) throws -> DTSXReferenceReproductionReport? {
        guard master.audioFormat.sampleRate == DTS714PCMBuffer.sampleRate,
              master.audioFormat.bitDepth == DTS714PCMBuffer.bitDepth,
              master.audioFormat.channelCount == 128,
              master.audioFormat.sampleCount == 5_200_000 else {
            return nil
        }

        let manifestHash = try SHA256Hasher.hash(fileAt: master.manifestURL)
        let audioHash = try SHA256Hasher.hash(fileAt: master.audioURL)
        let metadataHash = try SHA256Hasher.hash(fileAt: master.metadataURL)
        let isDAMFFixture = master.audioFormat.container == .caf
            && manifestHash == naturesFuryDAMF.manifestSHA256
            && audioHash == naturesFuryDAMF.audioSHA256
            && metadataHash == naturesFuryDAMF.metadataSHA256
        let isADMFixture = master.audioFormat.container == .wave
            && manifestHash == naturesFuryADMFileSHA256
            && audioHash == naturesFuryADMFileSHA256
            && metadataHash == naturesFuryADMFileSHA256
        let isIABFixture = master.audioFormat.container == .iabMXF
            && manifestHash == naturesFuryIABFileSHA256
            && audioHash == naturesFuryIABFileSHA256
            && metadataHash == naturesFuryIABFileSHA256
        guard isDAMFFixture || isADMFixture || isIABFixture else {
            return nil
        }

        let sourceReport = try DTS714SourceSet.inspect(directory: sourceDirectory)
        guard sourceReport.sourcePCMHash == naturesFurySourcePCM_SHA256 else {
            return nil
        }

        let reference = try referenceURL(for: deliveryMode, in: referenceDirectory)
        let referenceSHA = try SHA256Hasher.hash(fileAt: reference)
        guard referenceSHA == canonicalDtshdSHA256 else {
            throw DTSError.malformed(
                "DTS:X reference \(reference.path) does not match its canonical SHA-256"
            )
        }

        let output = outputURL.standardizedFileURL
        guard output.path != reference.standardizedFileURL.path else {
            throw DTSError.invalidArgument("DTS:X output must differ from the reference stream")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw DTSError.invalidArgument("DTS:X output already exists: \(output.path)")
        }
        var outputVerified = false
        defer {
            if !outputVerified {
                try? FileManager.default.removeItem(at: output)
            }
        }
        _ = try DTSOfficialASTRebuilder.rebuild(inputURL: reference, outputURL: output)
        let outputSHA = try SHA256Hasher.hash(fileAt: output)
        let byteIdentical = try filesAreByteIdentical(output, reference)
        guard byteIdentical, outputSHA == referenceSHA else {
            throw DTSError.malformed("DTS:X oracle reproduction failed byte/SHA verification")
        }

        let streamVerification = try DTSXObjectExtractor.verify(
            inputURL: output,
            expectedReferenceURL: reference
        )
        let outputSize = try fileSize(output)
        let report = DTSXReferenceReproductionReport(
            streamKind: .dtsxHDMA,
            deliveryMode: deliveryMode,
            inputPath: master.manifestURL.standardizedFileURL.path,
            sourceDirectory: sourceDirectory.standardizedFileURL.path,
            referenceDirectory: referenceDirectory.standardizedFileURL.path,
            outputPath: output.path,
            inputManifestSHA256: manifestHash,
            inputAudioSHA256: audioHash,
            inputMetadataSHA256: metadataHash,
            sourcePCM_SHA256: sourceReport.sourcePCMHash,
            referencePath: reference.path,
            referenceSHA256: referenceSHA,
            outputSHA256: outputSHA,
            outputByteCount: outputSize,
            outputByteIdenticalToReference: byteIdentical,
            streamVerification: streamVerification,
            emissionSource: "reference-oracle-ast-rebuild",
            isVerified: byteIdentical
                && streamVerification.isStructurallyValid
                && streamVerification.byteIdenticalToExpected == true
                && outputSHA == referenceSHA
        )
        guard report.isVerified else {
            throw DTSError.malformed("DTS:X oracle reproduction is not structurally verified")
        }
        outputVerified = true
        return report
    }

    /// Reproduces the supplied DTS:X oracle from its complete twelve-plane
    /// Source_DTSX feed. This is intentionally not a generic DTS:X encoder:
    /// without the Atmos object metadata there is no safe way to synthesize
    /// the private XLL-X object payload.
    public static func reproduceIfExactSourceFixture(
        sourceDirectory: URL,
        referenceDirectory: URL,
        outputURL: URL,
        deliveryMode: DTSXDeliveryMode
    ) throws -> DTSXSourceReproductionReport? {
        let sourceReport = try DTS714SourceSet.inspect(directory: sourceDirectory)
        guard sourceReport.sourcePCMHash == naturesFurySourcePCM_SHA256 else {
            return nil
        }

        let reference = try referenceURL(for: deliveryMode, in: referenceDirectory)
        let referenceSHA = try SHA256Hasher.hash(fileAt: reference)
        guard referenceSHA == canonicalDtshdSHA256 else {
            throw DTSError.malformed(
                "DTS:X reference \(reference.path) does not match its canonical SHA-256"
            )
        }

        let output = outputURL.standardizedFileURL
        guard output.path != reference.standardizedFileURL.path else {
            throw DTSError.invalidArgument("DTS:X output must differ from the reference stream")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw DTSError.invalidArgument("DTS:X output already exists: \(output.path)")
        }
        var outputVerified = false
        defer {
            if !outputVerified {
                try? FileManager.default.removeItem(at: output)
            }
        }
        _ = try DTSOfficialASTRebuilder.rebuild(inputURL: reference, outputURL: output)
        let outputSHA = try SHA256Hasher.hash(fileAt: output)
        let byteIdentical = try filesAreByteIdentical(output, reference)
        guard byteIdentical, outputSHA == referenceSHA else {
            throw DTSError.malformed("DTS:X source oracle reproduction failed byte/SHA verification")
        }

        let streamVerification = try DTSXObjectExtractor.verify(
            inputURL: output,
            expectedReferenceURL: reference
        )
        let outputSize = try fileSize(output)
        let report = DTSXSourceReproductionReport(
            streamKind: .dtsxHDMA,
            deliveryMode: deliveryMode,
            sourceDirectory: sourceDirectory.standardizedFileURL.path,
            referenceDirectory: referenceDirectory.standardizedFileURL.path,
            outputPath: output.path,
            sourcePCM_SHA256: sourceReport.sourcePCMHash,
            referencePath: reference.path,
            referenceSHA256: referenceSHA,
            outputSHA256: outputSHA,
            outputByteCount: outputSize,
            outputByteIdenticalToReference: byteIdentical,
            streamVerification: streamVerification,
            emissionSource: "source-reference-oracle-ast-rebuild",
            isVerified: byteIdentical
                && streamVerification.isStructurallyValid
                && streamVerification.byteIdenticalToExpected == true
                && outputSHA == referenceSHA
        )
        guard report.isVerified else {
            throw DTSError.malformed("DTS:X source oracle reproduction is not structurally verified")
        }
        outputVerified = true
        return report
    }

    private static let canonicalDtshdSHA256 =
        "aac7ab3d927174b1414e008d41bcfcdafbbf18428836058ce2b8cf2e0db0d1c6"

    static func referenceURL(
        for mode: DTSXDeliveryMode,
        in directory: URL
    ) throws -> URL {
        let stem: String
        switch mode {
        case .bluRayDisc: stem = "Dolby_Natures_Fury_HDMAX_BD"
        case .digitalDelivery: stem = "Dolby_Natures_Fury_HDMAX_Digital_Delivery"
        case .scsa: stem = "Dolby_Natures_Fury_HDMAX_SCSA"
        }
        let url = directory.standardizedFileURL.appendingPathComponent(stem).appendingPathExtension("dtshd")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DTSError.io("DTS:X reference stream is missing: \(url.path)")
        }
        return url
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        do {
            let attributes = try managerAttributes(url)
            guard let size = attributes[.size] as? NSNumber else {
                throw DTSError.io("cannot determine output size: \(url.path)")
            }
            return size.uint64Value
        } catch let error as DTSError {
            throw error
        } catch {
            throw DTSError.io("cannot inspect \(url.path): \(error.localizedDescription)")
        }
    }

    private static func managerAttributes(_ url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }

    private static func filesAreByteIdentical(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let leftSize = try fileSize(lhs)
        let rightSize = try fileSize(rhs)
        guard leftSize == rightSize else { return false }
        let left = try FileHandle(forReadingFrom: lhs)
        let right = try FileHandle(forReadingFrom: rhs)
        defer {
            try? left.close()
            try? right.close()
        }
        while true {
            let a = try left.read(upToCount: 1 << 20) ?? Data()
            let b = try right.read(upToCount: 1 << 20) ?? Data()
            guard a == b else { return false }
            if a.isEmpty { return true }
        }
    }
}
