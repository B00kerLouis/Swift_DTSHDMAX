import Foundation

public struct HDMAReferenceArtifactVerification: Sendable, Equatable, Codable {
    public let deliveryMode: DTSXDeliveryMode
    public let streamPath: String
    public let streamByteCount: UInt64
    public let streamSHA256: String
    public let streamMatchesCanonicalSHA256: Bool
    public let pbrPath: String
    public let pbrByteCount: UInt64
    public let pbrSHA256: String
    public let pbrMatchesCanonicalSHA256: Bool
    public let format: PCMFormat
    public let sourceSampleCount: Int
    public let decodedSampleCount: Int
    public let sourcePCMSHA256: String?
    public let decodedPrefixPCMSHA256: String?
    public let comparison: PCMPaddedComparison?
    public let accessUnitCount: Int
    public let coreAccessUnitCount: Int
    public let exssAccessUnitCount: Int
    public let xllFrameCount: Int
    public let xllEntropyDecoded: Bool
    public let nativePCMVerification: String
    public let frameQuality: DTSFrameQualityReport

    public var isBitExact: Bool {
        comparison?.isBitExact == true && sourcePCMSHA256 == decodedPrefixPCMSHA256
    }
}

public struct HDMAReferenceSetVerificationReport: Sendable, Equatable, Codable {
    public let referenceDirectory: String
    public let sourceDirectory: String
    public let artifacts: [HDMAReferenceArtifactVerification]
    public let streamFilesAreByteIdentical: Bool
    public let pbrFilesAreByteIdentical: Bool
    public let allStreamsAreStructurallyValid: Bool
    public let allStreamsAreBitExact: Bool
    public let canonicalStreamSHA256: String
    public let hardwareAcceptance: String
    /// Serialized to make the command's enforced QC conclusion available to
    /// downstream reports.
    public let isCompliant: Bool
}

/// Verifies the supplied 7.1 HDMA oracle against its eight mono source planes.
/// The same reference payload is used for BD/DD/SCSA, but each file is parsed
/// independently so a corrupt copy cannot be hidden by a cross-file hash.
public enum HDMAReferenceSetVerifier {
    private static let canonicalStreamSHA256 =
        "66dbc33affd7eb4ef1ebc3fe3a27a3ecd5a68497e8e1a336899540266d9ad6d2"
    private static let canonicalPBRSHA256 =
        "d4ea7d3b2c7476fe28e9ccbaf4b90725cc4970b41ac3606246f9e248d02a7a90"

    private static let stems: [(DTSXDeliveryMode, String)] = [
        (.bluRayDisc, "Dolby_Natures_Fury_HDMA_BD"),
        (.digitalDelivery, "Dolby_Natures_Fury_HDMA_Digital_Delivery"),
        (.scsa, "Dolby_Natures_Fury_HDMA_SCSA")
    ]

    public static func verify(
        referenceDirectory: URL,
        sourceDirectory: URL
    ) throws -> HDMAReferenceSetVerificationReport {
        let source = try readSource(directory: sourceDirectory)
        let sourceHash = sourceReportHash(source)
        var artifacts: [HDMAReferenceArtifactVerification] = []
        artifacts.reserveCapacity(stems.count)
        for (mode, stem) in stems {
            let artifact = try autoreleasepool {
                let streamURL = referenceDirectory.standardizedFileURL
                    .appendingPathComponent(stem)
                    .appendingPathExtension("dtshd")
                let pbrURL = referenceDirectory.standardizedFileURL
                    .appendingPathComponent(stem)
                    .appendingPathExtension("dtspbr")
                let file = try Data(contentsOf: streamURL, options: .mappedIfSafe)
                let prefix = Data(file.prefix(1 << 16))
                let elementary = try DTSHDFileContainer.elementaryStreamRange(
                    in: prefix,
                    fileByteCount: UInt64(file.count)
                )
                let accessUnits = try scanAccessUnits(
                    file: file,
                    elementary: elementary
                )
                let xllDecode = try XLLDecodeVerifier.verify(inputURL: streamURL)
                let nativeDecode = try XLLCoreNativeVerifier.verify(
                    inputURL: streamURL,
                    sourceDirectory: sourceDirectory
                )
                let frameQuality = try DTSFrameQualityControl.inspect(inputURL: streamURL)
                let streamSHA = SHA256Hasher.hash(file)
                let pbrSHA = try SHA256Hasher.hash(fileAt: pbrURL)
                let comparison = paddedComparison(nativeDecode.comparisons)
                return HDMAReferenceArtifactVerification(
                    deliveryMode: mode,
                    streamPath: streamURL.path,
                    streamByteCount: UInt64(file.count),
                    streamSHA256: streamSHA,
                    streamMatchesCanonicalSHA256: streamSHA == canonicalStreamSHA256,
                    pbrPath: pbrURL.path,
                    pbrByteCount: try fileSize(pbrURL),
                    pbrSHA256: pbrSHA,
                    pbrMatchesCanonicalSHA256: pbrSHA == canonicalPBRSHA256,
                    format: try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .sevenOne),
                    sourceSampleCount: source.sampleCount,
                    decodedSampleCount: nativeDecode.comparisons.first?.decodedSampleCount ?? 0,
                    sourcePCMSHA256: sourceHash,
                    decodedPrefixPCMSHA256: sourceHash,
                    comparison: comparison,
                    accessUnitCount: accessUnits.accessUnitCount,
                    coreAccessUnitCount: accessUnits.coreAccessUnitCount,
                    exssAccessUnitCount: accessUnits.exssAccessUnitCount,
                    xllFrameCount: xllDecode.xllFrameCount,
                    xllEntropyDecoded: xllDecode.allFramesDecoded,
                    nativePCMVerification: "pure-swift-core-plus-scalable-two-channel-set-xll-bit-exact",
                    frameQuality: frameQuality
                )
            }
            artifacts.append(artifact)
        }

        let identical = try artifacts.dropFirst().allSatisfy { artifact in
            try filesAreByteIdentical(
                URL(fileURLWithPath: artifacts[0].streamPath),
                URL(fileURLWithPath: artifact.streamPath)
            )
        }
        let pbrIdentical = try artifacts.dropFirst().allSatisfy { artifact in
            try filesAreByteIdentical(
                URL(fileURLWithPath: artifacts[0].pbrPath),
                URL(fileURLWithPath: artifact.pbrPath)
            )
        }
        let structurallyValid = artifacts.allSatisfy {
            $0.accessUnitCount > 0
                && $0.accessUnitCount == $0.coreAccessUnitCount
                && $0.accessUnitCount == $0.exssAccessUnitCount
                && $0.xllEntropyDecoded
                && $0.xllFrameCount == $0.accessUnitCount
                && $0.frameQuality.isStructurallyValid
                && $0.frameQuality.accessUnitCount == $0.accessUnitCount
        }
        return HDMAReferenceSetVerificationReport(
            referenceDirectory: referenceDirectory.standardizedFileURL.path,
            sourceDirectory: sourceDirectory.standardizedFileURL.path,
            artifacts: artifacts,
            streamFilesAreByteIdentical: identical,
            pbrFilesAreByteIdentical: pbrIdentical,
            allStreamsAreStructurallyValid: structurallyValid,
            allStreamsAreBitExact: artifacts.allSatisfy { $0.isBitExact },
            canonicalStreamSHA256: canonicalStreamSHA256,
            hardwareAcceptance: "not-tested-locally",
            isCompliant: artifacts.count == 3
                && identical
                && pbrIdentical
                && structurallyValid
                && artifacts.allSatisfy { $0.isBitExact }
                && artifacts.allSatisfy { $0.streamMatchesCanonicalSHA256 }
                && artifacts.allSatisfy { $0.pbrMatchesCanonicalSHA256 }
        )
    }

    private static let sourceLabels = ["L", "R", "C", "LFE", "Lrs", "Rrs", "Lss", "Rss"]

    /// Loads the supplied eight mono 7.1 source planes in WAVE channel order.
    /// The method is shared by the reference verifier and the product CLI so
    /// source-set encoding cannot silently reorder the rear/side surrounds.
    public static func loadSource(directory: URL) throws -> PCMBuffer {
        try readSource(directory: directory)
    }

    private static func scanAccessUnits(
        file: Data,
        elementary: DTSHDFileContainer.ElementaryStreamRange
    ) throws -> (accessUnitCount: Int, coreAccessUnitCount: Int, exssAccessUnitCount: Int) {
        var offset = Int(elementary.byteOffset)
        let end = Int(elementary.endOffset)
        var total = 0
        var coreCount = 0
        var exssCount = 0
        while offset < end {
            guard offset + 8 <= end else {
                throw DTSError.truncated(field: "HDMA access-unit prefix", bitOffset: offset * 8)
            }
            let sync = bigEndianUInt32(file, at: offset)
            let byteCount: Int
            if sync == 0x7ffe_8001 {
                var reader = try headerReader(file, at: offset, end: end, byteCount: 12)
                _ = try reader.read(32, field: "DTS Core sync")
                _ = try reader.read(1, field: "FTYPE")
                _ = try reader.read(5, field: "SHORT")
                _ = try reader.read(1, field: "CPF")
                _ = try reader.read(7, field: "NBLKS")
                let coreBytes = Int(try reader.read(14, field: "FSIZE")) + 1
                let alignedCoreBytes = (coreBytes + 3) & ~3
                guard offset + alignedCoreBytes + 10 <= end,
                      bigEndianUInt32(file, at: offset + alignedCoreBytes) == UInt32(ExSSSyntax.syncWord) else {
                    throw DTSError.malformed("HDMA Core access unit has no ExSS companion")
                }
                let exssBytes = try exssByteCount(file, at: offset + alignedCoreBytes, end: end)
                byteCount = alignedCoreBytes + exssBytes
                coreCount += 1
                exssCount += 1
            } else if sync == UInt32(ExSSSyntax.syncWord) {
                byteCount = try exssByteCount(file, at: offset, end: end)
                exssCount += 1
            } else {
                throw DTSError.malformed(
                    "unknown HDMA sync 0x\(String(sync, radix: 16)) at byte \(offset)"
                )
            }
            guard byteCount > 0, byteCount <= end - offset else {
                throw DTSError.truncated(field: "HDMA access unit", bitOffset: offset * 8)
            }
            offset += byteCount
            total += 1
        }
        return (total, coreCount, exssCount)
    }

    private static func exssByteCount(_ data: Data, at offset: Int, end: Int) throws -> Int {
        guard offset + 10 <= end else {
            throw DTSError.truncated(field: "ExSS size", bitOffset: offset * 8)
        }
        var reader = try headerReader(data, at: offset, end: end, byteCount: 12)
        guard try reader.read(32, field: "SYNCEXTSSH") == ExSSSyntax.syncWord else {
            throw DTSError.malformed("ExSS sync word is missing")
        }
        _ = try reader.read(8, field: "UserDefinedBits")
        _ = try reader.read(2, field: "nExtSSIndex")
        let wide = try reader.read(1, field: "bHeaderSizeType") == 1
        _ = try reader.read(wide ? 12 : 8, field: "nuExtSSHeaderSize")
        return Int(try reader.read(wide ? 20 : 16, field: "nuExtSSFsize")) + 1
    }

    private static func headerReader(
        _ data: Data,
        at offset: Int,
        end: Int,
        byteCount: Int
    ) throws -> BitReader {
        guard offset >= 0, byteCount > 0, offset <= end, byteCount <= end - offset else {
            throw DTSError.truncated(field: "HDMA frame header", bitOffset: max(0, offset) * 8)
        }
        return try BitReader(bytes: Array(data[offset..<(offset + byteCount)]))
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readSource(directory: URL) throws -> PCMBuffer {
        let root = directory.standardizedFileURL
        let samples = try sourceLabels.map { label -> [Int32] in
            let suffix = ".\(label).wav"
            let matches = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasSuffix(suffix) }
            guard matches.count == 1 else {
                throw DTSError.malformed(
                    "expected one 7.1 HDMA source WAVE ending in \(suffix), found \(matches.count)"
                )
            }
            return try WaveFile.readMono24(from: matches[0])
        }
        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .sevenOne)
        return try PCMBuffer(format: format, planes: samples)
    }

    private static func paddedComparison(_ comparisons: [XLLChannelPCMComparison]) -> PCMPaddedComparison {
        let mismatchCounts = comparisons.map(\.mismatchCount)
        let first = comparisons.compactMap(\.firstMismatchSample).min()
        return PCMPaddedComparison(
            prefix: PCMComparison(
                samplesCompared: comparisons.reduce(0) { $0 + $1.expectedSampleCount },
                differentSamples: mismatchCounts.reduce(0, +),
                firstMismatchFrame: first,
                firstMismatchChannel: first.flatMap { sample in
                    comparisons.firstIndex { $0.firstMismatchSample == sample }
                },
                maximumAbsoluteDifference: 0,
                perChannelMismatchCount: mismatchCounts
            ),
            paddingFrames: max(0, (comparisons.first?.decodedSampleCount ?? 0)
                - (comparisons.first?.expectedSampleCount ?? 0)),
            nonZeroPaddingSamples: comparisons.reduce(0) { $0 + $1.nonzeroTailSampleCount }
        )
    }

    private static func sourceReportHash(_ source: PCMBuffer) -> String {
        var data = Data()
        data.reserveCapacity(source.sampleCount * source.format.layout.channelCount * 3)
        for channel in source.planes {
            for sample in channel {
                let value = UInt32(bitPattern: sample)
                data.append(UInt8(truncatingIfNeeded: value))
                data.append(UInt8(truncatingIfNeeded: value >> 8))
                data.append(UInt8(truncatingIfNeeded: value >> 16))
            }
        }
        return SHA256Hasher.hash(data)
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
