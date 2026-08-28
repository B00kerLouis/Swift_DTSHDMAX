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
///
/// The parent's materials protocol names uploads with a UTC stamp
/// (`tbh_<STAMP>.dtshd`, stamp `YYYYMMDDTHHMMZ`, e.g. `20260828T0124Z`)
/// beside an `UPLOAD_MANIFEST_<STAMP>.txt`. The gate accepts either the
/// legacy exact names or any stamped variant, resolves each role to the
/// newest stamp present, and reports the resolved file so census playbooks
/// can quote one concrete path.
public struct DTSXReferenceStreamEntryStatus: Sendable, Equatable, Codable {
    /// Canonical (legacy) requested name for the role.
    public let fileName: String
    /// Stamped naming pattern also accepted for this role.
    public let stampedPattern: String
    public let role: String
    public let isRequired: Bool
    public let isPresent: Bool
    /// The actual directory entry satisfying this role (legacy or stamped).
    public let resolvedFileName: String?
    /// Parsed `YYYYMMDDTHHMMZ` stamp when the resolved file is stamped.
    public let stamp: String?
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

    /// (legacy fileName, role, required) for the encodes Louis named. The
    /// optional official perfect TBH is reported but does not block
    /// completion. The TBH Atmos/IAB master is required for the pop-window
    /// investigation: only it carries the object automation that the two
    /// flagged timecode windows render, so render-path evidence is blocked
    /// until it (or a documented timecode-window extract) lands. The stamped
    /// upload manifest is reported when present but never blocks: the
    /// binaries are what unblock byte-exact work.
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
        ),
        (
            "UPLOAD_MANIFEST.txt",
            "stamped upload manifest (reported, never blocking)",
            false
        )
    ]

    public static func verify(directory: URL) throws -> DTSXReferenceStreamGateReport {
        let root = directory.standardizedFileURL
        let directoryEntries = ((try? FileManager.default.contentsOfDirectory(
            atPath: root.path
        )) ?? []).sorted()

        var entries: [DTSXReferenceStreamEntryStatus] = []
        var missingRequired: [String] = []
        var resolvedNames = Set<String>()
        for (fileName, role, isRequired) in expectedEntries {
            let pattern = stampedPattern(forLegacyName: fileName)
            guard let resolved = resolveRole(
                legacyName: fileName,
                in: directoryEntries
            ) else {
                entries.append(DTSXReferenceStreamEntryStatus(
                    fileName: fileName,
                    stampedPattern: pattern,
                    role: role,
                    isRequired: isRequired,
                    isPresent: false,
                    resolvedFileName: nil,
                    stamp: nil,
                    byteCount: nil,
                    sha256: nil,
                    matchesCanonicalPerfectNaturesFury: nil
                ))
                if isRequired { missingRequired.append(fileName) }
                continue
            }
            resolvedNames.insert(resolved.fileName)
            let url = root.appendingPathComponent(resolved.fileName)
            let hash = try SHA256Hasher.hash(fileAt: url)
            entries.append(DTSXReferenceStreamEntryStatus(
                fileName: fileName,
                stampedPattern: pattern,
                role: role,
                isRequired: isRequired,
                isPresent: true,
                resolvedFileName: resolved.fileName,
                stamp: resolved.stamp,
                byteCount: try fileByteCount(url),
                sha256: hash,
                matchesCanonicalPerfectNaturesFury:
                    hash == canonicalPerfectNaturesFuryDTSHDSHA256
            ))
        }

        let additional = directoryEntries
            .filter {
                $0.lowercased().hasSuffix(".dtshd") && !resolvedNames.contains($0)
            }
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

    /// `tbh.dtshd` → `tbh_<STAMP>.dtshd`; extensionless names gain `_<STAMP>`
    /// before their last dot when present.
    private static func stampedPattern(forLegacyName name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "\(name)_<STAMP>" }
        return "\(name[..<dot])_<STAMP>\(name[dot...])"
    }

    /// Resolves one role against the directory listing: the newest stamped
    /// variant wins; the legacy exact name is the fallback. Stamps use the
    /// parent's fixed-width `YYYYMMDDTHHMMZ` UTC convention, so the newest
    /// stamp is the lexicographically greatest.
    private static func resolveRole(
        legacyName: String,
        in directoryEntries: [String]
    ) -> (fileName: String, stamp: String?)? {
        let stem: Substring
        let suffix: Substring
        if let dot = legacyName.lastIndex(of: ".") {
            stem = legacyName[..<dot]
            suffix = legacyName[dot...]
        } else {
            stem = legacyName[...]
            suffix = ""
        }
        var newest: (fileName: String, stamp: String)?
        for candidate in directoryEntries {
            guard candidate.count == legacyName.count + 15,
                  candidate.hasPrefix("\(stem)_"),
                  candidate.hasSuffix(suffix) else { continue }
            let stampStart = candidate.index(candidate.startIndex, offsetBy: stem.count + 1)
            let stampEnd = candidate.index(candidate.endIndex, offsetBy: -suffix.count)
            let stamp = String(candidate[stampStart..<stampEnd])
            guard isValidStamp(stamp) else { continue }
            if newest == nil || stamp > newest!.stamp {
                newest = (candidate, stamp)
            }
        }
        if let newest { return (newest.fileName, newest.stamp) }
        if directoryEntries.contains(legacyName) { return (legacyName, nil) }
        return nil
    }

    /// `YYYYMMDDTHHMMZ`, e.g. `20260828T0124Z`.
    private static func isValidStamp(_ stamp: String) -> Bool {
        let characters = Array(stamp.utf8)
        guard characters.count == 14,
              characters[8] == UInt8(ascii: "T"),
              characters[13] == UInt8(ascii: "Z") else { return false }
        let digits = characters[0..<8] + characters[9..<13]
        return digits.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
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
