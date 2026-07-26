import Foundation

/// DTS Encoder Suite `.dtshd` files place the raw DTS Core/ExSS elementary
/// stream in a `STRMDATA` chunk. Blu-ray/MKV elementary streams start directly
/// with a DTS Core or ExSS sync word and therefore use the full file range.
enum DTSHDFileContainer {
    struct ElementaryStreamRange: Sendable, Equatable {
        let byteOffset: UInt64
        let byteCount: UInt64

        var endOffset: UInt64 { byteOffset + byteCount }
    }

    private static let coreSyncWord: UInt32 = 0x7ffe_8001
    private static let exssSyncWord: UInt32 = 0x6458_2025
    private static let headerTag = Array("DTSHDHDR".utf8)
    private static let streamDataTag = Array("STRMDATA".utf8)

    static func wrapHDMA(
        elementaryStream: Data,
        format: PCMFormat,
        sourceSampleCount: Int,
        frameRate: DTSFrameRate,
        streamKind: DTSHDMAStreamKind = .dtsHDMA
    ) throws -> Data {
        guard format.sampleRate == 48_000, format.bitDepth == 24 else {
            throw DTSError.unsupported("DTSHD product container requires 48 kHz/24-bit PCM")
        }
        guard streamKind == .dtsHDMA || streamKind == .dtsxHDMA else {
            throw DTSError.invalidArgument("DTSHD product container requires a final HDMA stream")
        }
        let channelPairMask: Int
        if streamKind == .dtsxHDMA {
            guard format.layout == .sevenOne else {
                throw DTSError.unsupported("DTS:X product container requires a 7.1 compatibility bed")
            }
            // Encoder Suite DTS:X products mark both the 7.1 bed and the
            // immersive/object extension in AUPR-HDR. Plain 7.1 HDMA uses
            // 0x084b; writing that mask for DTS:X makes the authoring header
            // contradict the ExSS asset descriptor and destabilizes muxers.
            channelPairMask = 0x886b
        } else {
            switch format.layout {
            case .fiveOneSide:
                channelPairMask = 0x000f
            case .sevenOne:
                channelPairMask = 0x084b
            case .stereo:
                throw DTSError.unsupported(
                    "DTS HDMA product container requires 5.1(side) or 7.1 PCM"
                )
            }
        }
        guard sourceSampleCount > 0 else {
            throw DTSError.invalidArgument("DTSHD source sample count must be positive")
        }
        let metrics = try hdmaMetrics(elementaryStream)
        guard metrics.accessUnitCount <= Int(UInt32.max), sourceSampleCount <= 0xffff_ffff_ff else {
            throw DTSError.valueOutOfRange(
                field: "DTSHD program dimensions",
                value: "(metrics.accessUnitCount) AU, (sourceSampleCount) samples"
            )
        }

        let averageExtensionKbps = Int(
            (Double(metrics.totalExSSByteCount) * 8.0 * 48_000.0
                / Double(sourceSampleCount) / 1_000.0).rounded()
        )
        let peakExtensionKbps = Int(
            (Double(metrics.maximumExSSByteCount) * 8.0 * 48_000.0
                / Double(XLLSyntax.frameSampleCount) / 1_000.0).rounded()
        )
        guard averageExtensionKbps <= 0xff_ffff, peakExtensionKbps <= Int(UInt16.max) else {
            throw DTSError.valueOutOfRange(
                field: "DTSHD extension bitrate",
                value: "average (averageExtensionKbps), peak (peakExtensionKbps) kbps"
            )
        }

        var output = Data()
        appendChunk(
            tag: "DTSHDHDR",
            payload: Data([
                0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00,
                0x00, 0x02, 0x00, 0x1d, 0x01, 0x00, 0x00, 0x00
            ]),
            to: &output
        )
        appendChunk(
            tag: "CORESSMD",
            payload: Data([
                0x00, 0xbb, 0x80, 0x05, 0xe5, 0x08,
                0x0b, 0x00, 0x00, 0x07, 0xdc, 0x00
            ]),
            to: &output
        )

        var extensionMetadata = Data()
        appendUInt24(averageExtensionKbps, to: &extensionMetadata)
        extensionMetadata.append(0x00)
        appendUInt16(peakExtensionKbps, to: &extensionMetadata)
        extensionMetadata.append(contentsOf: [0x00, 0x80])
        appendChunk(tag: "EXTSS_MD", payload: extensionMetadata, to: &output)

        var accessUnitMetadata = Data([0x00, 0x00, 0x05])
        appendUInt24(48_000, to: &accessUnitMetadata)
        appendUInt32(metrics.accessUnitCount, to: &accessUnitMetadata)
        appendUInt16(XLLSyntax.frameSampleCount, to: &accessUnitMetadata)
        appendUInt40(sourceSampleCount, to: &accessUnitMetadata)
        appendUInt16(channelPairMask, to: &accessUnitMetadata)
        appendUInt16(XLLSyntax.coreCompatiblePrimingSampleCount, to: &accessUnitMetadata)
        accessUnitMetadata.append(contentsOf: [0x00, 0x00, 0x00])
        appendChunk(tag: "AUPR-HDR", payload: accessUnitMetadata, to: &output)
        appendChunk(tag: "STRMDATA", payload: elementaryStream, to: &output)

        // Encoder Suite `.dtshd` products carry an access-unit navigation
        // table and a decoder-safe blackout access unit after STRMDATA.  The
        // payload is not part of the elementary stream, but authoring/player
        // applications use it for startup, seek and flush.  Omitting these
        // chunks leaves some native players to synthesize a flush frame from
        // stale state, which is especially unsafe for Core-associated XLL.
        var navigation = Data()
        appendUInt32(metrics.accessUnitCount, to: &navigation)
        appendUInt32(0x0001_0400, to: &navigation)
        for offset in metrics.accessUnitOffsets {
            // DTSHD NAVI stores a 32-bit byte offset with the low 24 bits
            // preceding the high 8-bit bank. This is a one-byte left rotation,
            // not a plain big-endian UInt32. It is visible at every 16 MiB
            // boundary in Encoder Suite products.
            let value = UInt32(offset)
            let packed = (value << 8) | (value >> 24)
            appendUInt32(Int(packed), to: &navigation)
        }
        appendChunk(tag: "NAVI-TBL", payload: navigation, to: &output)

        var timecode = Data()
        appendUInt32(48_000, to: &timecode)
        timecode.append(frameRate.containerCode)
        timecode.append(contentsOf: Array(repeating: 0, count: 27))
        appendChunk(tag: "TIMECODE", payload: timecode, to: &output)

        var buildVersion = Data(
            "BUILD DATE = Jul 23 2026\nBUILD TIME = 00:00:00\nVERSION = 1\nREVISION = 0\n\0".utf8
        )
        if buildVersion.count < 76 {
            buildVersion.append(contentsOf: Array(repeating: 0, count: 76 - buildVersion.count))
        } else if buildVersion.count > 76 {
            buildVersion = Data(buildVersion.prefix(76))
        }
        appendChunk(tag: "BUILDVER", payload: buildVersion, to: &output)

        let blackoutByteCount = metrics.firstAccessUnitByteCount
        guard blackoutByteCount > 0, blackoutByteCount <= elementaryStream.count else {
            throw DTSError.malformed("DTSHD blackout access unit is unavailable")
        }
        appendChunk(
            tag: "BLACKOUT",
            payload: Data(elementaryStream.prefix(blackoutByteCount)),
            to: &output
        )
        return output
    }

    static func authoringFrameRate(at url: URL) throws -> DTSFrameRate? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let prefix = try handle.read(upToCount: 8) ?? Data()
        guard prefix == Data(headerTag) else { return nil }

        var offset: UInt64 = 0
        while offset + 16 <= fileSize {
            try handle.seek(toOffset: offset)
            let header = try handle.read(upToCount: 16) ?? Data()
            guard header.count == 16 else {
                throw DTSError.truncated(
                    field: "DTSHD chunk header",
                    bitOffset: Int(offset) * 8
                )
            }
            let tag = Data(header.prefix(8))
            let byteCount = header[8..<16].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            let payloadOffset = offset + 16
            let (end, overflow) = payloadOffset.addingReportingOverflow(byteCount)
            guard !overflow, end <= fileSize else {
                throw DTSError.truncated(
                    field: "DTSHD chunk payload",
                    bitOffset: Int(offset) * 8
                )
            }
            if tag == Data("TIMECODE".utf8) {
                guard byteCount >= 5 else {
                    throw DTSError.truncated(
                        field: "DTSHD TIMECODE",
                        bitOffset: Int(payloadOffset) * 8
                    )
                }
                try handle.seek(toOffset: payloadOffset + 4)
                guard let code = try handle.read(upToCount: 1)?.first else {
                    throw DTSError.truncated(
                        field: "DTSHD TIMECODE frame rate",
                        bitOffset: Int(payloadOffset + 4) * 8
                    )
                }
                return try DTSFrameRate(containerCode: code)
            }
            offset = end
        }
        return nil
    }

    static func elementaryStream(in file: Data) throws -> Data {
        let prefix = Data(file.prefix(1 << 16))
        let range = try elementaryStreamRange(
            in: prefix,
            fileByteCount: UInt64(file.count)
        )
        guard range.byteOffset <= UInt64(Int.max), range.endOffset <= UInt64(Int.max) else {
            throw DTSError.valueOutOfRange(
                field: "DTSHD elementary stream range",
                value: "(range.byteOffset)..<(range.endOffset)"
            )
        }
        return file.subdata(in: Int(range.byteOffset)..<Int(range.endOffset))
    }

    static func elementaryStreamRange(
        in prefix: Data,
        fileByteCount: UInt64
    ) throws -> ElementaryStreamRange {
        guard fileByteCount > 0, prefix.count >= 4 else {
            throw DTSError.truncated(field: "DTS-HD file prefix", bitOffset: 0)
        }

        let initialWord = try bigEndianUInt32(prefix, at: 0)
        if initialWord == coreSyncWord || initialWord == exssSyncWord {
            return ElementaryStreamRange(byteOffset: 0, byteCount: fileByteCount)
        }
        guard prefix.count >= 16, Array(prefix.prefix(8)) == headerTag else {
            throw DTSError.malformed("expected a DTS Core/ExSS stream or DTSHDHDR file header")
        }

        var cursor = 0
        while cursor + 16 <= prefix.count {
            let tag = Array(prefix[cursor..<(cursor + 8)])
            let byteCount = try bigEndianUInt64(prefix, at: cursor + 8)
            let payloadOffset = UInt64(cursor + 16)
            let (payloadEnd, overflow) = payloadOffset.addingReportingOverflow(byteCount)
            guard !overflow, payloadEnd <= fileByteCount else {
                throw DTSError.truncated(field: "DTSHD chunk payload", bitOffset: (cursor + 8) * 8)
            }
            if tag == streamDataTag {
                return ElementaryStreamRange(byteOffset: payloadOffset, byteCount: byteCount)
            }
            guard payloadEnd <= UInt64(prefix.count) else {
                throw DTSError.truncated(field: "DTSHD header", bitOffset: Int(payloadEnd) * 8)
            }
            cursor = Int(payloadEnd)
        }
        throw DTSError.malformed("DTSHDHDR file has no STRMDATA chunk")
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw DTSError.truncated(field: "DTS-HD UInt32", bitOffset: max(0, offset) * 8)
        }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func bigEndianUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else {
            throw DTSError.truncated(field: "DTS-HD UInt64", bitOffset: max(0, offset) * 8)
        }
        var value: UInt64 = 0
        for byte in data[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private static func hdmaMetrics(
        _ stream: Data
    ) throws -> (
        accessUnitCount: Int,
        totalExSSByteCount: Int,
        maximumExSSByteCount: Int,
        accessUnitOffsets: [Int],
        firstAccessUnitByteCount: Int
    ) {
        var offset = 0
        var accessUnitCount = 0
        var totalExSSByteCount = 0
        var maximumExSSByteCount = 0
        var accessUnitOffsets: [Int] = []
        var firstAccessUnitByteCount = 0
        while offset < stream.count {
            guard offset <= Int(UInt32.max) else {
                throw DTSError.valueOutOfRange(
                    field: "DTSHD navigation offset",
                    value: String(offset)
                )
            }
            accessUnitOffsets.append(offset)
            guard stream.count - offset >= 12,
                  try bigEndianUInt32(stream, at: offset) == coreSyncWord else {
                throw DTSError.malformed("DTS HDMA access unit is missing its Core")
            }
            var coreReader = try BitReader(data: stream, byteOffset: offset)
            _ = try coreReader.read(32, field: "DTS Core sync")
            _ = try coreReader.read(1, field: "FTYPE")
            _ = try coreReader.read(5, field: "SHORT")
            _ = try coreReader.read(1, field: "CPF")
            _ = try coreReader.read(7, field: "NBLKS")
            let coreByteCount = Int(try coreReader.read(14, field: "FSIZE")) + 1
            let exssOffset = offset + ((coreByteCount + 3) & ~3)
            guard exssOffset + 12 <= stream.count,
                  try bigEndianUInt32(stream, at: exssOffset) == exssSyncWord else {
                throw DTSError.malformed("DTS HDMA Core has no ExSS companion")
            }
            var exssReader = try BitReader(data: stream, byteOffset: exssOffset)
            _ = try exssReader.read(32, field: "SYNCEXTSSH")
            _ = try exssReader.read(8, field: "UserDefinedBits")
            _ = try exssReader.read(2, field: "nExtSSIndex")
            let wide = try exssReader.read(1, field: "bHeaderSizeType") == 1
            _ = try exssReader.read(wide ? 12 : 8, field: "nuExtSSHeaderSize")
            let exssByteCount = Int(
                try exssReader.read(wide ? 20 : 16, field: "nuExtSSFsize")
            ) + 1
            guard exssByteCount > 0, exssByteCount <= stream.count - exssOffset else {
                throw DTSError.truncated(field: "DTSHD ExSS access unit", bitOffset: exssOffset * 8)
            }
            totalExSSByteCount += exssByteCount
            maximumExSSByteCount = max(maximumExSSByteCount, exssByteCount)
            accessUnitCount += 1
            let nextOffset = exssOffset + exssByteCount
            if accessUnitCount == 1 {
                firstAccessUnitByteCount = nextOffset - offset
            }
            offset = nextOffset
        }
        guard accessUnitCount > 0, offset == stream.count else {
            throw DTSError.malformed("DTSHD elementary stream has no complete access units")
        }
        return (
            accessUnitCount,
            totalExSSByteCount,
            maximumExSSByteCount,
            accessUnitOffsets,
            firstAccessUnitByteCount
        )
    }

    private static func appendChunk(tag: String, payload: Data, to output: inout Data) {
        output.append(contentsOf: tag.utf8)
        appendUInt64(payload.count, to: &output)
        output.append(payload)
    }

    private static func appendUInt16(_ value: Int, to output: inout Data) {
        output.append(UInt8(truncatingIfNeeded: value >> 8))
        output.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendUInt24(_ value: Int, to output: inout Data) {
        output.append(UInt8(truncatingIfNeeded: value >> 16))
        output.append(UInt8(truncatingIfNeeded: value >> 8))
        output.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendUInt32(_ value: Int, to output: inout Data) {
        output.append(UInt8(truncatingIfNeeded: value >> 24))
        output.append(UInt8(truncatingIfNeeded: value >> 16))
        output.append(UInt8(truncatingIfNeeded: value >> 8))
        output.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendUInt40(_ value: Int, to output: inout Data) {
        output.append(UInt8(truncatingIfNeeded: value >> 32))
        appendUInt32(value, to: &output)
    }

    private static func appendUInt64(_ value: Int, to output: inout Data) {
        let unsigned = UInt64(value)
        for shift in stride(from: 56, through: 0, by: -8) {
            output.append(UInt8(truncatingIfNeeded: unsigned >> UInt64(shift)))
        }
    }
}

public struct DTSAccessUnitInfo: Sendable, Equatable, Codable {
    public let index: Int
    public let byteOffset: UInt64
    public let byteCount: Int
    public let coreByteCount: Int?
    public let exssByteCount: Int?
    public let pcmSampleCount: Int
}

public struct DTSStreamInspector: Sendable {
    private static let coreSyncWord: UInt64 = 0x7ffe_8001
    private static let probeByteCount = 1 << 16

    public init() {}

    public func inspect(data: Data, maximumAccessUnits: Int) throws -> [DTSAccessUnitInfo] {
        guard maximumAccessUnits > 0 else {
            throw DTSError.invalidArgument("maximum access-unit count must be positive")
        }
        let elementaryStream = try DTSHDFileContainer.elementaryStream(in: data)
        var infos: [DTSAccessUnitInfo] = []
        var offset = 0
        for index in 0..<maximumAccessUnits {
            guard offset < elementaryStream.count else { break }
            let prefixEnd = min(elementaryStream.count, offset + Self.probeByteCount)
            let prefix = elementaryStream.subdata(in: offset..<prefixEnd)
            let info = try parseAccessUnit(prefix: prefix, index: index, byteOffset: UInt64(offset))
            guard info.byteCount <= elementaryStream.count - offset else {
                throw DTSError.truncated(field: "DTS access unit", bitOffset: offset * 8)
            }
            infos.append(info)
            offset += info.byteCount
        }
        guard offset == elementaryStream.count || infos.count == maximumAccessUnits else {
            throw DTSError.truncated(field: "DTS access-unit inspection", bitOffset: offset * 8)
        }
        return infos
    }

    public func inspect(url: URL, maximumAccessUnits: Int) throws -> [DTSAccessUnitInfo] {
        guard maximumAccessUnits > 0 else {
            throw DTSError.invalidArgument("maximum access-unit count must be positive")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DTSError.io("cannot open \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        let fileByteCount: UInt64
        do { fileByteCount = try handle.seekToEnd() }
        catch { throw DTSError.io("cannot determine (url.path) size: \(error.localizedDescription)") }
        do { try handle.seek(toOffset: 0) }
        catch { throw DTSError.io("cannot seek \(url.path): \(error.localizedDescription)") }
        let filePrefix: Data
        do { filePrefix = try handle.read(upToCount: Self.probeByteCount) ?? Data() }
        catch { throw DTSError.io("cannot read \(url.path): \(error.localizedDescription)") }
        let elementary = try DTSHDFileContainer.elementaryStreamRange(
            in: filePrefix,
            fileByteCount: fileByteCount
        )

        var infos: [DTSAccessUnitInfo] = []
        var offset = elementary.byteOffset
        for index in 0..<maximumAccessUnits {
            guard offset < elementary.endOffset else { break }
            do { try handle.seek(toOffset: offset) } catch {
                throw DTSError.io("cannot seek \(url.path): \(error.localizedDescription)")
            }
            let prefix: Data
            let available = min(UInt64(Self.probeByteCount), elementary.endOffset - offset)
            do { prefix = try handle.read(upToCount: Int(available)) ?? Data() } catch {
                throw DTSError.io("cannot read \(url.path): \(error.localizedDescription)")
            }
            if prefix.isEmpty { break }
            let info = try parseAccessUnit(prefix: prefix, index: index, byteOffset: offset)
            guard UInt64(info.byteCount) <= elementary.endOffset - offset else {
                throw DTSError.truncated(field: "DTS access unit", bitOffset: Int(offset) * 8)
            }
            infos.append(info)
            offset += UInt64(info.byteCount)
        }
        return infos
    }

    public func excerpt(input: URL, output: URL, accessUnitCount: Int) throws -> [DTSAccessUnitInfo] {
        let infos = try inspect(url: input, maximumAccessUnits: accessUnitCount)
        guard infos.count == accessUnitCount else {
            throw DTSError.truncated(field: "requested DTS access units", bitOffset: 0)
        }
        let totalBytes = infos.reduce(0) { $0 + $1.byteCount }
        let inputHandle: FileHandle
        do {
            inputHandle = try FileHandle(forReadingFrom: input)
        } catch {
            throw DTSError.io("cannot open \(input.path): \(error.localizedDescription)")
        }
        defer { try? inputHandle.close() }
        guard let start = infos.first?.byteOffset else {
            throw DTSError.malformed("requested DTS excerpt is empty")
        }
        do { try inputHandle.seek(toOffset: start) } catch {
            throw DTSError.io("cannot seek \(input.path): \(error.localizedDescription)")
        }
        let excerpt: Data
        do {
            excerpt = try inputHandle.read(upToCount: totalBytes) ?? Data()
        } catch {
            throw DTSError.io("cannot read excerpt: \(error.localizedDescription)")
        }
        guard excerpt.count == totalBytes else {
            throw DTSError.truncated(field: "DTS excerpt", bitOffset: excerpt.count * 8)
        }
        do {
            try excerpt.write(to: output, options: .atomic)
        } catch {
            throw DTSError.io("cannot write \(output.path): \(error.localizedDescription)")
        }
        return infos
    }

    private func parseAccessUnit(prefix: Data, index: Int, byteOffset: UInt64) throws -> DTSAccessUnitInfo {
        var reader = try BitReader(data: prefix)
        let sync = try reader.read(32, field: "DTS sync word")
        if sync == Self.coreSyncWord {
            _ = try reader.read(1, field: "FTYPE")
            _ = try reader.read(5, field: "SHORT")
            _ = try reader.read(1, field: "CPF")
            let pcmBlocks = Int(try reader.read(7, field: "NBLKS")) + 1
            let coreByteCount = Int(try reader.read(14, field: "FSIZE")) + 1
            let alignedCoreByteCount = (coreByteCount + 3) & ~3
            var exssByteCount: Int?
            if prefix.count >= alignedCoreByteCount + 10,
               try readBigEndianUInt32(prefix, at: alignedCoreByteCount) == UInt32(ExSSSyntax.syncWord) {
                exssByteCount = try parseExSSSize(prefix, at: alignedCoreByteCount)
            }
            return DTSAccessUnitInfo(
                index: index,
                byteOffset: byteOffset,
                byteCount: alignedCoreByteCount + (exssByteCount ?? 0),
                coreByteCount: coreByteCount,
                exssByteCount: exssByteCount,
                pcmSampleCount: pcmBlocks * 32
            )
        }
        if sync == ExSSSyntax.syncWord {
            let exssByteCount = try parseExSSSize(prefix, at: 0)
            return DTSAccessUnitInfo(
                index: index,
                byteOffset: byteOffset,
                byteCount: exssByteCount,
                coreByteCount: nil,
                exssByteCount: exssByteCount,
                pcmSampleCount: XLLSyntax.frameSampleCount
            )
        }
        throw DTSError.malformed(
            "unsupported DTS sync 0x\(String(sync, radix: 16)) at byte \(byteOffset)"
        )
    }

    private func parseExSSSize(_ data: Data, at byteOffset: Int) throws -> Int {
        var reader = try BitReader(data: data, byteOffset: byteOffset)
        guard try reader.read(32, field: "SYNCEXTSSH") == ExSSSyntax.syncWord else {
            throw DTSError.malformed("ExSS sync word is missing at byte \(byteOffset)")
        }
        _ = try reader.read(8, field: "UserDefinedBits")
        _ = try reader.read(2, field: "nExtSSIndex")
        let wide = try reader.read(1, field: "bHeaderSizeType") == 1
        _ = try reader.read(wide ? 12 : 8, field: "nuExtSSHeaderSize")
        return Int(try reader.read(wide ? 20 : 16, field: "nuExtSSFsize")) + 1
    }

    private func readBigEndianUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw DTSError.truncated(field: "UInt32", bitOffset: offset * 8)
        }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
