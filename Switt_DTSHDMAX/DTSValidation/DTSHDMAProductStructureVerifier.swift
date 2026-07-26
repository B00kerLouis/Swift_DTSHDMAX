import Foundation

/// Transport validation for final DTS HDMA and internal XLL diagnostic streams.
public struct DTSHDMAStreamStructureReport: Sendable, Equatable, Codable {
    public let expectedStreamKind: DTSHDMAStreamKind
    public let accessUnitCount: Int
    public let coreAccessUnitCount: Int
    public let exssAccessUnitCount: Int
    public let firstAccessUnitSyncWord: UInt32
    public let allCodingModesAreLosslessXLL: Bool
    public let allCoreAssociationsMatch: Bool
    public let trailingByteCount: Int
    public let isValid: Bool
}

public enum DTSHDMAStreamStructureVerifier {
    public static func verify(
        _ stream: Data,
        expectedStreamKind: DTSHDMAStreamKind
    ) throws -> DTSHDMAStreamStructureReport {
        guard expectedStreamKind == .xllStandalone || expectedStreamKind == .dtsHDMA else {
            throw DTSError.invalidArgument(
                "DTS-HD stream verification accepts XLL-Standalone or DTS HDMA only"
            )
        }
        guard !stream.isEmpty else {
            throw DTSError.malformed("DTS-HD product stream is empty")
        }
        let elementaryStream = try DTSHDFileContainer.elementaryStream(in: stream)

        let parser = ExSSParser()
        var offset = 0
        var accessUnitCount = 0
        var coreAccessUnitCount = 0
        var exssAccessUnitCount = 0
        var allCodingModesAreLosslessXLL = true
        var allCoreAssociationsMatch = true
        var firstSyncWord: UInt32 = 0

        while offset < elementaryStream.count {
            guard elementaryStream.count - offset >= 16 else {
                throw DTSError.truncated(
                    field: "DTS-HD access-unit prefix",
                    bitOffset: offset * 8
                )
            }
            let sync = try elementaryStream.bigEndianUInt32(at: offset)
            if accessUnitCount == 0 { firstSyncWord = sync }

            let exssOffset: Int
            let hasCore: Bool
            if sync == 0x7ffe_8001 {
                var coreReader = try BitReader(
                    data: elementaryStream,
                    byteOffset: offset
                )
                _ = try coreReader.read(32, field: "DTS Core sync")
                _ = try coreReader.read(1, field: "FTYPE")
                _ = try coreReader.read(5, field: "SHORT")
                _ = try coreReader.read(1, field: "CPF")
                _ = try coreReader.read(7, field: "NBLKS")
                let coreByteCount = Int(try coreReader.read(14, field: "FSIZE")) + 1
                let alignedCoreByteCount = (coreByteCount + 3) & ~3
                exssOffset = offset + alignedCoreByteCount
                hasCore = true
                coreAccessUnitCount += 1
                guard exssOffset + 16 <= elementaryStream.count,
                      try elementaryStream.bigEndianUInt32(at: exssOffset) == UInt32(ExSSSyntax.syncWord) else {
                    throw DTSError.malformed(
                        "DTS Core access unit has no ExSS companion"
                    )
                }
            } else if sync == UInt32(ExSSSyntax.syncWord) {
                exssOffset = offset
                hasCore = false
            } else {
                throw DTSError.malformed(
                    "unexpected DTS-HD access-unit sync 0x\(String(sync, radix: 16)) at byte \(offset)"
                )
            }

            let prefix = elementaryStream.subdata(in: exssOffset..<(exssOffset + 16))
            let frameByteCount = try exssByteCount(prefix)
            guard exssOffset + frameByteCount <= elementaryStream.count else {
                throw DTSError.truncated(
                    field: "ExSS access unit",
                    bitOffset: exssOffset * 8
                )
            }
            let frame = elementaryStream.subdata(
                in: exssOffset..<(exssOffset + frameByteCount)
            )
            let parsed = try parser.parse(frame: frame)
            exssAccessUnitCount += 1
            allCodingModesAreLosslessXLL =
                allCodingModesAreLosslessXLL
                    && ((hasCore && parsed.info.codingMode == 0)
                        || (!hasCore && parsed.info.codingMode == 1))
            allCoreAssociationsMatch =
                allCoreAssociationsMatch
                    && parsed.info.backwardCompatibleCorePresent == hasCore
            offset = exssOffset + frameByteCount
            accessUnitCount += 1
        }

        let baseIsValid = accessUnitCount > 0
            && exssAccessUnitCount == accessUnitCount
            && allCodingModesAreLosslessXLL
            && allCoreAssociationsMatch
        let productIsValid: Bool
        switch expectedStreamKind {
        case .xllStandalone:
            productIsValid = coreAccessUnitCount == 0
                && firstSyncWord == UInt32(ExSSSyntax.syncWord)
        case .dtsHDMA:
            productIsValid = coreAccessUnitCount == accessUnitCount
                && firstSyncWord == 0x7ffe_8001
        case .dtsxHDMA:
            productIsValid = false
        }
        let trailingByteCount = elementaryStream.count - offset
        let report = DTSHDMAStreamStructureReport(
            expectedStreamKind: expectedStreamKind,
            accessUnitCount: accessUnitCount,
            coreAccessUnitCount: coreAccessUnitCount,
            exssAccessUnitCount: exssAccessUnitCount,
            firstAccessUnitSyncWord: firstSyncWord,
            allCodingModesAreLosslessXLL: allCodingModesAreLosslessXLL,
            allCoreAssociationsMatch: allCoreAssociationsMatch,
            trailingByteCount: trailingByteCount,
            isValid: baseIsValid && productIsValid && trailingByteCount == 0
        )
        guard report.isValid else {
            throw DTSError.malformed(
                "DTS-HD stream does not match the \(expectedStreamKind.rawValue) transport contract"
            )
        }
        return report
    }

    private static func exssByteCount(_ prefix: Data) throws -> Int {
        var reader = try BitReader(data: prefix)
        guard try reader.read(32, field: "SYNCEXTSSH") == ExSSSyntax.syncWord else {
            throw DTSError.malformed("ExSS sync word is missing")
        }
        _ = try reader.read(8, field: "UserDefinedBits")
        _ = try reader.read(2, field: "nExtSSIndex")
        let wide = try reader.read(1, field: "bHeaderSizeType") == 1
        _ = try reader.read(wide ? 12 : 8, field: "nuExtSSHeaderSize")
        return Int(try reader.read(wide ? 20 : 16, field: "nuExtSSFsize")) + 1
    }
}

public struct DTSHDProductContainerReport: Sendable, Equatable, Codable {
    public let chunkTags: [String]
    public let chunkByteCounts: [Int]
    public let accessUnitCount: Int
    public let navigationEntryCount: Int
    public let navigationOffsetsMatchAccessUnits: Bool
    public let blackoutMatchesFirstAccessUnit: Bool
    public let chunksEndAtFileBoundary: Bool
    public let isValid: Bool
}

/// Strict validation for the Encoder Suite-style `.dtshd` product wrapper.
/// The elementary stream remains independently validated above; this checks
/// the authoring metadata used by native players for startup, seek and flush.
public enum DTSHDProductContainerVerifier {
    private static let expectedTags = [
        "DTSHDHDR", "CORESSMD", "EXTSS_MD", "AUPR-HDR", "STRMDATA",
        "NAVI-TBL", "TIMECODE", "BUILDVER", "BLACKOUT"
    ]

    public static func verify(_ product: Data) throws -> DTSHDProductContainerReport {
        var cursor = 0
        var chunks: [(tag: String, range: Range<Int>)] = []
        while cursor + 16 <= product.count {
            let tag = String(decoding: product[cursor..<(cursor + 8)], as: UTF8.self)
            let byteCount = try readUInt64(product, at: cursor + 8)
            guard byteCount <= UInt64(Int.max) else {
                throw DTSError.valueOutOfRange(field: "DTSHD chunk size", value: String(byteCount))
            }
            let start = cursor + 16
            let end = start + Int(byteCount)
            guard end >= start, end <= product.count else {
                throw DTSError.truncated(field: "DTSHD chunk \(tag)", bitOffset: start * 8)
            }
            chunks.append((tag, start..<end))
            cursor = end
        }

        let tags = chunks.map(\.tag)
        let counts = chunks.map { $0.range.count }
        let complete = cursor == product.count
        guard let streamChunk = chunks.first(where: { $0.tag == "STRMDATA" }),
              let navigationChunk = chunks.first(where: { $0.tag == "NAVI-TBL" }),
              let blackoutChunk = chunks.first(where: { $0.tag == "BLACKOUT" }) else {
            throw DTSError.malformed("DTSHD product is missing STRMDATA/NAVI-TBL/BLACKOUT")
        }
        let stream = product.subdata(in: streamChunk.range)
        let offsets = try accessUnitOffsets(stream)
        let navigation = product.subdata(in: navigationChunk.range)
        guard navigation.count >= 8 else {
            throw DTSError.truncated(field: "DTSHD NAVI-TBL", bitOffset: navigationChunk.range.lowerBound * 8)
        }
        let navigationCount = Int(try navigation.bigEndianUInt32(at: 0))
        let navigationMagic = try navigation.bigEndianUInt32(at: 4)
        let expectedNavigationByteCount = 8 + navigationCount * 4
        var navigationMatches = navigationMagic == 0x0001_0400
            && navigationCount == offsets.count
            && navigation.count == expectedNavigationByteCount
        if navigationMatches {
            for (index, offset) in offsets.enumerated() {
                let actual = try navigation.bigEndianUInt32(at: 8 + index * 4)
                guard let value = UInt32(exactly: offset) else {
                    throw DTSError.valueOutOfRange(
                        field: "DTSHD NAVI-TBL offset",
                        value: String(offset)
                    )
                }
                let expected = (value << 8) | (value >> 24)
                if actual != expected {
                    navigationMatches = false
                    break
                }
            }
        }

        let firstAccessUnitByteCount = offsets.count > 1
            ? offsets[1]
            : stream.count
        let blackout = product.subdata(in: blackoutChunk.range)
        let blackoutMatches = firstAccessUnitByteCount > 0
            && blackout == stream.prefix(firstAccessUnitByteCount)
        let fixedChunkSizesValid = chunks.first(where: { $0.tag == "TIMECODE" })?.range.count == 32
            && chunks.first(where: { $0.tag == "BUILDVER" })?.range.count == 76
        let valid = tags == expectedTags
            && complete
            && navigationMatches
            && blackoutMatches
            && fixedChunkSizesValid
        return DTSHDProductContainerReport(
            chunkTags: tags,
            chunkByteCounts: counts,
            accessUnitCount: offsets.count,
            navigationEntryCount: navigationCount,
            navigationOffsetsMatchAccessUnits: navigationMatches,
            blackoutMatchesFirstAccessUnit: blackoutMatches,
            chunksEndAtFileBoundary: complete,
            isValid: valid
        )
    }

    private static func accessUnitOffsets(_ stream: Data) throws -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        while offset < stream.count {
            offsets.append(offset)
            guard offset + 12 <= stream.count,
                  try stream.bigEndianUInt32(at: offset) == 0x7ffe_8001 else {
                throw DTSError.malformed("DTSHD STRMDATA access unit is missing its Core")
            }
            var core = try BitReader(data: stream, byteOffset: offset)
            _ = try core.read(32, field: "DTS Core sync")
            _ = try core.read(1, field: "FTYPE")
            _ = try core.read(5, field: "SHORT")
            _ = try core.read(1, field: "CPF")
            _ = try core.read(7, field: "NBLKS")
            let coreByteCount = Int(try core.read(14, field: "FSIZE")) + 1
            let exssOffset = offset + ((coreByteCount + 3) & ~3)
            guard exssOffset + 12 <= stream.count,
                  try stream.bigEndianUInt32(at: exssOffset) == UInt32(ExSSSyntax.syncWord) else {
                throw DTSError.malformed("DTSHD STRMDATA Core has no ExSS companion")
            }
            var exss = try BitReader(data: stream, byteOffset: exssOffset)
            _ = try exss.read(32, field: "SYNCEXTSSH")
            _ = try exss.read(8, field: "UserDefinedBits")
            _ = try exss.read(2, field: "nExtSSIndex")
            let wide = try exss.read(1, field: "bHeaderSizeType") == 1
            _ = try exss.read(wide ? 12 : 8, field: "nuExtSSHeaderSize")
            let exssByteCount = Int(try exss.read(wide ? 20 : 16, field: "nuExtSSFsize")) + 1
            offset = exssOffset + exssByteCount
            guard offset <= stream.count else {
                throw DTSError.truncated(field: "DTSHD STRMDATA ExSS", bitOffset: exssOffset * 8)
            }
        }
        guard !offsets.isEmpty, offset == stream.count else {
            throw DTSError.malformed("DTSHD STRMDATA has no complete access units")
        }
        return offsets
    }

    private static func readUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else {
            throw DTSError.truncated(field: "DTSHD UInt64", bitOffset: max(0, offset) * 8)
        }
        var value: UInt64 = 0
        for byte in data[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}
