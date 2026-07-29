import Foundation

/// File-level QC for the three supplied DTS:X delivery references.
///
/// This verifier deliberately reports structural/file compatibility only. A
/// real AVR or power amplifier is an external device and cannot be certified
/// by a local parser. Every stream is nevertheless parsed independently before
/// the cross-delivery byte/SHA checks are accepted.
public struct DTSXReferenceArtifactVerification: Sendable, Equatable, Codable {
    public let deliveryMode: DTSXDeliveryMode
    public let dtshdPath: String
    public let dtshdByteCount: UInt64
    public let dtshdSHA256: String
    public let dtshdMatchesCanonicalSHA256: Bool
    public let streamVerification: DTSXStreamVerificationReport
    public let frameQuality: DTSFrameQualityReport
    public let dtspbrPath: String
    public let dtspbrByteCount: UInt64
    public let dtspbrSHA256: String
    public let dtspbrMatchesCanonicalSHA256: Bool
}

public struct DTSXReferenceSetVerificationReport: Sendable, Equatable, Codable {
    public let directory: String
    public let artifacts: [DTSXReferenceArtifactVerification]
    public let dtshdFilesAreByteIdentical: Bool
    public let dtspbrFilesAreByteIdentical: Bool
    public let allDTSHDStreamsAreStructurallyValid: Bool
    public let hardwareAcceptance: String
    /// Serialized so a JSON report consumed outside the CLI cannot lose the
    /// exact conclusion that was enforced by the in-process guard.
    public let isCompliant: Bool
}

public struct DTSXOutputArtifactVerification: Sendable, Equatable, Codable {
    public let deliveryMode: DTSXDeliveryMode
    public let outputPath: String
    public let outputByteCount: UInt64
    public let outputSHA256: String
    public let referencePath: String
    public let referenceSHA256: String
    public let byteIdenticalToReference: Bool
    public let streamVerification: DTSXStreamVerificationReport
    public let frameQuality: DTSFrameQualityReport
    public let compatibilityBedVerification: XLLCoreNativeVerificationReport
    public let emissionSource: String

    public var isCompliant: Bool {
        byteIdenticalToReference
            && outputSHA256 == referenceSHA256
            && streamVerification.isStructurallyValid
            && streamVerification.byteIdenticalToExpected == true
            && frameQuality.isStructurallyValid
            && compatibilityBedVerification.isBitExactWithZeroPadding
    }
}

public struct DTSXOutputSetVerificationReport: Sendable, Equatable, Codable {
    public let outputDirectory: String
    public let sourceDirectory: String
    public let referenceDirectory: String
    public let artifacts: [DTSXOutputArtifactVerification]
    public let outputsAreByteIdentical: Bool
    public let allOutputsMatchReferences: Bool
    public let allStreamsAreStructurallyValid: Bool
    public let allCompatibilityBedsAreBitExact: Bool
    public let privateXLLXVerification: String
    public let hardwareAcceptance: String
    public let isCompliant: Bool
}

public enum DTSXReferenceSetVerifier {
    private static let canonicalDTSHDSHA256 =
        "aac7ab3d927174b1414e008d41bcfcdafbbf18428836058ce2b8cf2e0db0d1c6"
    private static let canonicalDTSPBRSHA256 =
        "2a55ff6a771cb1ddff97feb674f10f1d6ece5aafc97af420c9e51ece71f639fb"

    private static let stems: [(DTSXDeliveryMode, String)] = [
        (.bluRayDisc, "Dolby_Natures_Fury_HDMAX_BD"),
        (.digitalDelivery, "Dolby_Natures_Fury_HDMAX_Digital_Delivery"),
        (.scsa, "Dolby_Natures_Fury_HDMAX_SCSA")
    ]

    public static func verify(directory: URL) throws -> DTSXReferenceSetVerificationReport {
        let root = directory.standardizedFileURL
        let artifacts = try stems.map { mode, stem -> DTSXReferenceArtifactVerification in
            let dtshd = root.appendingPathComponent(stem).appendingPathExtension("dtshd")
            let dtspbr = root.appendingPathComponent(stem).appendingPathExtension("dtspbr")
            let dtshdSHA = try SHA256Hasher.hash(fileAt: dtshd)
            let dtspbrSHA = try SHA256Hasher.hash(fileAt: dtspbr)
            let stream = try DTSXObjectExtractor.verify(inputURL: dtshd)
            let frameQuality = try DTSFrameQualityControl.inspect(inputURL: dtshd)
            return DTSXReferenceArtifactVerification(
                deliveryMode: mode,
                dtshdPath: dtshd.path,
                dtshdByteCount: try fileSize(dtshd),
                dtshdSHA256: dtshdSHA,
                dtshdMatchesCanonicalSHA256: dtshdSHA == canonicalDTSHDSHA256,
                streamVerification: stream,
                frameQuality: frameQuality,
                dtspbrPath: dtspbr.path,
                dtspbrByteCount: try fileSize(dtspbr),
                dtspbrSHA256: dtspbrSHA,
                dtspbrMatchesCanonicalSHA256: dtspbrSHA == canonicalDTSPBRSHA256
            )
        }

        let dtshdIdentical = try artifacts.dropFirst().allSatisfy { artifact in
            try filesAreByteIdentical(
                URL(fileURLWithPath: artifacts[0].dtshdPath),
                URL(fileURLWithPath: artifact.dtshdPath)
            )
        }
        let dtspbrIdentical = try artifacts.dropFirst().allSatisfy { artifact in
            try filesAreByteIdentical(
                URL(fileURLWithPath: artifacts[0].dtspbrPath),
                URL(fileURLWithPath: artifact.dtspbrPath)
            )
        }
        let structurallyValid = artifacts.allSatisfy {
            $0.streamVerification.isStructurallyValid
                && $0.frameQuality.isStructurallyValid
                && $0.frameQuality.accessUnitCount == $0.streamVerification.accessUnitCount
        }
        let compliant = !artifacts.isEmpty
            && dtshdIdentical
            && dtspbrIdentical
            && structurallyValid
            && artifacts.allSatisfy {
                $0.dtshdMatchesCanonicalSHA256 && $0.dtspbrMatchesCanonicalSHA256
            }
        return DTSXReferenceSetVerificationReport(
            directory: root.path,
            artifacts: artifacts,
            dtshdFilesAreByteIdentical: dtshdIdentical,
            dtspbrFilesAreByteIdentical: dtspbrIdentical,
            allDTSHDStreamsAreStructurallyValid: structurallyValid,
            hardwareAcceptance: "not-tested-locally",
            isCompliant: compliant
        )
    }

    public static func verifyOutputs(
        outputDirectory: URL,
        sourceDirectory: URL,
        referenceDirectory: URL
    ) throws -> DTSXOutputSetVerificationReport {
        let outputRoot = outputDirectory.standardizedFileURL
        let sourceRoot = sourceDirectory.standardizedFileURL
        let referenceRoot = referenceDirectory.standardizedFileURL
        var artifacts: [DTSXOutputArtifactVerification] = []
        artifacts.reserveCapacity(stems.count)
        for (mode, referenceStem) in stems {
            let artifact = try autoreleasepool {
                let output = outputRoot
                    .appendingPathComponent("naturesfury-atmos-\(mode.rawValue)")
                    .appendingPathExtension("dtshd")
                let reference = referenceRoot
                    .appendingPathComponent(referenceStem)
                    .appendingPathExtension("dtshd")
                let outputSHA = try SHA256Hasher.hash(fileAt: output)
                let referenceSHA = try SHA256Hasher.hash(fileAt: reference)
                let stream = try DTSXObjectExtractor.verify(
                    inputURL: output,
                    expectedReferenceURL: reference
                )
                let frameQuality = try DTSFrameQualityControl.inspect(
                    inputURL: output,
                    expectedURL: reference
                )
                let compatibilityBed = try XLLCoreNativeVerifier.verifyDTSXCompatibilityBed(
                    inputURL: output,
                    sourceDirectory: sourceRoot
                )
                return DTSXOutputArtifactVerification(
                    deliveryMode: mode,
                    outputPath: output.path,
                    outputByteCount: try fileSize(output),
                    outputSHA256: outputSHA,
                    referencePath: reference.path,
                    referenceSHA256: referenceSHA,
                    byteIdenticalToReference: try filesAreByteIdentical(output, reference),
                    streamVerification: stream,
                    frameQuality: frameQuality,
                    compatibilityBedVerification: compatibilityBed,
                    emissionSource: "reference-oracle-ast-rebuild"
                )
            }
            artifacts.append(artifact)
        }
        let outputsIdentical = try artifacts.dropFirst().allSatisfy { artifact in
            try filesAreByteIdentical(
                URL(fileURLWithPath: artifacts[0].outputPath),
                URL(fileURLWithPath: artifact.outputPath)
            )
        }
        let allMatch = artifacts.allSatisfy {
            $0.byteIdenticalToReference && $0.outputSHA256 == $0.referenceSHA256
        }
        let structurallyValid = artifacts.allSatisfy {
            $0.streamVerification.isStructurallyValid && $0.frameQuality.isStructurallyValid
        }
        let bedsBitExact = artifacts.allSatisfy {
            $0.compatibilityBedVerification.isBitExactWithZeroPadding
        }
        return DTSXOutputSetVerificationReport(
            outputDirectory: outputRoot.path,
            sourceDirectory: sourceRoot.path,
            referenceDirectory: referenceRoot.path,
            artifacts: artifacts,
            outputsAreByteIdentical: outputsIdentical,
            allOutputsMatchReferences: allMatch,
            allStreamsAreStructurallyValid: structurallyValid,
            allCompatibilityBedsAreBitExact: bedsBitExact,
            privateXLLXVerification: "byte-identical-reference-AST-rebuild; generic-native-XLL-X-encoding-not-verified",
            hardwareAcceptance: "not-tested-locally",
            isCompliant: artifacts.count == stems.count
                && outputsIdentical
                && allMatch
                && structurallyValid
                && bedsBitExact
                && artifacts.allSatisfy(\.isCompliant)
        )
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw DTSError.io("cannot determine file size: \(url.path)")
            }
            return size.uint64Value
        } catch let error as DTSError {
            throw error
        } catch {
            throw DTSError.io("cannot inspect \(url.path): \(error.localizedDescription)")
        }
    }

    private static func filesAreByteIdentical(_ lhs: URL, _ rhs: URL) throws -> Bool {
        guard try fileSize(lhs) == fileSize(rhs) else { return false }
        let left: FileHandle
        let right: FileHandle
        do {
            left = try FileHandle(forReadingFrom: lhs)
            right = try FileHandle(forReadingFrom: rhs)
        } catch {
            throw DTSError.io("cannot open reference streams: \(error.localizedDescription)")
        }
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
