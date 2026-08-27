import Foundation

/// Presence/identity gate for the cloud-staged reference encodes.
///
/// Cloud agents cannot read Louis's Mac; the byte-level pop reinvestigation
/// is blocked until the encode-debug streams land under
/// `cloud-fixtures/reference-streams/` on the materials branch. Skipping the
/// comparison silently has repeatedly produced "green" runs that proved
/// nothing, so this gate makes the missing binaries an explicit red result:
/// the CLI command exits nonzero with `PARENT_UPLOAD_REQUIRED` until every
/// required file is present, and verifies SHA-256 identity (including the
/// canonical perfect Nature's Fury delivery hash) the moment one lands.
public struct DTSXReferenceStreamEntryStatus: Sendable, Equatable, Codable {
    public let fileName: String
    public let role: String
    public let isRequired: Bool
    public let isPresent: Bool
    public let byteCount: UInt64?
    public let sha256: String?
    /// True when this file is byte-identical to the canonical perfect
    /// Nature's Fury delivery stream published in `DTSXReferenceSetVerifier`.
    public let matchesCanonicalPerfectNaturesFury: Bool?
}

public struct DTSXReferenceStreamGateReport: Sendable, Equatable, Codable {
    public let directory: String
    public let canonicalPerfectNaturesFuryDTSHDSHA256: String
    public let entries: [DTSXReferenceStreamEntryStatus]
    /// Any further `.dtshd` files present in the directory beyond the
    /// requested set - listed so uploads under unexpected names are found.
    public let additionalDTSHDFileNames: [String]
    public let missingRequiredFileNames: [String]
    /// `PARENT_UPLOAD_REQUIRED` while any required encode is missing;
    /// `COMPLETE` once every required file is present.
    public let uploadStatus: String
    public let isComplete: Bool
}

public enum DTSXReferenceStreamGate {
    /// SHA-256 of the byte-identical BD / Digital Delivery / SCSA perfect
    /// Nature's Fury elementary stream (see `DTSXReferenceSetVerifier` and
    /// the perfect-stream grammar README on the materials branch).
    public static let canonicalPerfectNaturesFuryDTSHDSHA256 =
        "aac7ab3d927174b1414e008d41bcfcdafbbf18428836058ce2b8cf2e0db0d1c6"
    public static let defaultDirectoryPath = "cloud-fixtures/reference-streams"
    public static let parentUploadRequiredStatus = "PARENT_UPLOAD_REQUIRED"
    public static let completeStatus = "COMPLETE"

    /// (fileName, role, required) for the encodes Louis named. The optional
    /// official perfect TBH is reported but does not block completion. The
    /// TBH Atmos/IAB master is required for the pop-window investigation:
    /// only it carries the object automation that the two flagged timecode
    /// windows render, so render-path evidence is blocked until it (or a
    /// documented timecode-window extract) lands.
    private static let expectedEntries: [(String, String, Bool)] = [
        (
            "tbh.dtshd",
            "encode-debug TBH (Mac Downloads software encode under test)",
            true
        ),
        (
            "Dolby_NaturesFury.dtshd",
            "encode-debug / perfect Nature's Fury (Mac Downloads)",
            true
        ),
        (
            "QWER_TBH_IAB.mxf",
            "TBH Atmos/IAB master for the pop-window render investigation "
                + "(full MXF or a documented extract covering both flagged "
                + "timecode windows with margin)",
            true
        ),
        (
            "TBH_offical.dtshd",
            "official perfect TBH (optional)",
            false
        )
    ]

    public static func verify(directory: URL) throws -> DTSXReferenceStreamGateReport {
        let root = directory.standardizedFileURL
        var entries: [DTSXReferenceStreamEntryStatus] = []
        var missingRequired: [String] = []
        for (fileName, role, isRequired) in expectedEntries {
            let url = root.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                entries.append(DTSXReferenceStreamEntryStatus(
                    fileName: fileName,
                    role: role,
                    isRequired: isRequired,
                    isPresent: false,
                    byteCount: nil,
                    sha256: nil,
                    matchesCanonicalPerfectNaturesFury: nil
                ))
                if isRequired { missingRequired.append(fileName) }
                continue
            }
            let hash = try SHA256Hasher.hash(fileAt: url)
            entries.append(DTSXReferenceStreamEntryStatus(
                fileName: fileName,
                role: role,
                isRequired: isRequired,
                isPresent: true,
                byteCount: try fileByteCount(url),
                sha256: hash,
                matchesCanonicalPerfectNaturesFury:
                    hash == canonicalPerfectNaturesFuryDTSHDSHA256
            ))
        }

        let expectedNames = Set(expectedEntries.map(\.0))
        let additional = ((try? FileManager.default.contentsOfDirectory(
            atPath: root.path
        )) ?? [])
            .filter { $0.lowercased().hasSuffix(".dtshd") && !expectedNames.contains($0) }
            .sorted()

        let isComplete = missingRequired.isEmpty
        return DTSXReferenceStreamGateReport(
            directory: root.path,
            canonicalPerfectNaturesFuryDTSHDSHA256:
                canonicalPerfectNaturesFuryDTSHDSHA256,
            entries: entries,
            additionalDTSHDFileNames: additional,
            missingRequiredFileNames: missingRequired,
            uploadStatus: isComplete ? completeStatus : parentUploadRequiredStatus,
            isComplete: isComplete
        )
    }

    private static func fileByteCount(_ url: URL) throws -> UInt64 {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw DTSError.io(
                "cannot stat \(url.path): \(error.localizedDescription)"
            )
        }
        guard let byteCount = attributes[.size] as? NSNumber else {
            throw DTSError.io("cannot determine \(url.path) size")
        }
        return byteCount.uint64Value
    }
}
