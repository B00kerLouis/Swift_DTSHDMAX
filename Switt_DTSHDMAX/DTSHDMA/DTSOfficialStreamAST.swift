import Foundation

public struct DTSCoreFrameAST: Sendable, Equatable {
    public let frameType: Int
    public let deficitSampleCountCode: Int
    public let crcPresent: Bool
    public let blockCount: Int
    public let frameByteCount: Int
    public let bytes: Data

    public func serialize() -> Data { bytes }
}

public struct DTSExSSFrameAST: Sendable, Equatable {
    public let exssIndex: Int
    public let wideHeader: Bool
    public let headerByteCount: Int
    public let frameByteCount: Int
    public let staticFieldsPresent: Bool
    public let presentationCount: Int
    public let assetByteCounts: [Int]
    public let header: Data
    public let assets: [Data]
    public let trailingBytes: Data

    public func serialize() -> Data {
        var output = Data()
        output.reserveCapacity(frameByteCount)
        output.append(header)
        for asset in assets { output.append(asset) }
        output.append(trailingBytes)
        return output
    }
}

public struct DTSAccessUnitAST: Sendable, Equatable {
    public let core: DTSCoreFrameAST?
    public let coreAlignmentBytes: Data
    public let exss: DTSExSSFrameAST

    public func serialize() -> Data {
        var output = Data()
        if let core { output.append(core.serialize()) }
        output.append(coreAlignmentBytes)
        output.append(exss.serialize())
        return output
    }
}

public enum DTSOfficialStreamASTParser {
    public static func parseAccessUnit(_ data: Data) throws -> DTSAccessUnitAST {
        guard data.count >= 12 else {
            throw DTSError.truncated(field: "DTS access unit", bitOffset: data.count * 8)
        }
        let sync = try data.bigEndianUInt32(at: 0)
        let core: DTSCoreFrameAST?
        let alignment: Data
        let exssOffset: Int
        if sync == 0x7ffe_8001 {
            let parsedCore = try parseCore(data)
            let alignedCoreByteCount = (parsedCore.frameByteCount + 3) & ~3
            guard alignedCoreByteCount + 12 <= data.count else {
                throw DTSError.truncated(field: "Core-aligned ExSS prefix", bitOffset: data.count * 8)
            }
            core = parsedCore
            alignment = data.subdata(in: parsedCore.frameByteCount..<alignedCoreByteCount)
            exssOffset = alignedCoreByteCount
        } else if sync == UInt32(ExSSSyntax.syncWord) {
            core = nil
            alignment = Data()
            exssOffset = 0
        } else {
            throw DTSError.malformed("access unit does not begin with DTS Core or ExSS sync")
        }
        let exss = try parseExSS(data.subdata(in: exssOffset..<data.count))
        guard exss.frameByteCount == data.count - exssOffset else {
            throw DTSError.malformed("ExSS frame does not close at the access-unit boundary")
        }
        return DTSAccessUnitAST(core: core, coreAlignmentBytes: alignment, exss: exss)
    }

    public static func parseCore(_ data: Data) throws -> DTSCoreFrameAST {
        var reader = try BitReader(data: data)
        guard try reader.read(32, field: "SYNC") == 0x7ffe_8001 else {
            throw DTSError.malformed("DTS Core sync word is missing")
        }
        let frameType = Int(try reader.read(1, field: "FTYPE"))
        let deficit = Int(try reader.read(5, field: "SHORT"))
        let crcPresent = try reader.read(1, field: "CPF") == 1
        let blockCount = Int(try reader.read(7, field: "NBLKS")) + 1
        let frameByteCount = Int(try reader.read(14, field: "FSIZE")) + 1
        guard frameByteCount <= data.count else {
            throw DTSError.truncated(field: "DTS Core frame", bitOffset: data.count * 8)
        }
        return DTSCoreFrameAST(
            frameType: frameType,
            deficitSampleCountCode: deficit,
            crcPresent: crcPresent,
            blockCount: blockCount,
            frameByteCount: frameByteCount,
            bytes: data.subdata(in: 0..<frameByteCount)
        )
    }

    public static func parseExSS(_ data: Data) throws -> DTSExSSFrameAST {
        var reader = try BitReader(data: data)
        guard try reader.read(32, field: "SYNCEXTSSH") == ExSSSyntax.syncWord else {
            throw DTSError.malformed("ExSS sync word is missing")
        }
        _ = try reader.read(8, field: "UserDefinedBits")
        let exssIndex = Int(try reader.read(2, field: "nExtSSIndex"))
        let wide = try reader.read(1, field: "bHeaderSizeType") == 1
        let headerByteCount = Int(try reader.read(wide ? 12 : 8, field: "nuExtSSHeaderSize")) + 1
        let frameByteCount = Int(try reader.read(wide ? 20 : 16, field: "nuExtSSFsize")) + 1
        guard headerByteCount <= frameByteCount, frameByteCount <= data.count else {
            throw DTSError.truncated(field: "ExSS frame", bitOffset: data.count * 8)
        }

        let staticFields = try reader.read(1, field: "bStaticFieldsPresent") == 1
        var presentationCount = 1
        var assetCount = 1
        if staticFields {
            _ = try reader.read(2, field: "nuRefClockCode")
            _ = try reader.read(3, field: "nuExSSFrameDurationCode")
            if try reader.read(1, field: "bTimeStampFlag") == 1 {
                try reader.skip(36, field: "nuTimeStamp")
            }
            presentationCount = Int(try reader.read(3, field: "nuNumAudioPresnt")) + 1
            assetCount = Int(try reader.read(3, field: "nuNumAssets")) + 1
            var activeMasks: [UInt64] = []
            activeMasks.reserveCapacity(presentationCount)
            for presentation in 0..<presentationCount {
                activeMasks.append(try reader.read(
                    exssIndex + 1,
                    field: "nuActiveExSSMask[\(presentation)]"
                ))
            }
            for (presentation, mask) in activeMasks.enumerated() {
                try reader.skip(
                    mask.nonzeroBitCount * 8,
                    field: "nuActiveAssetMask[\(presentation)]"
                )
            }
            guard try reader.read(1, field: "bMixMetadataEnbl") == 0 else {
                throw DTSError.unsupported("reversible ExSS AST with mix metadata")
            }
        }

        let sizeBitCount = wide ? 20 : 16
        var assetByteCounts: [Int] = []
        assetByteCounts.reserveCapacity(assetCount)
        for asset in 0..<assetCount {
            assetByteCounts.append(Int(try reader.read(
                sizeBitCount,
                field: "nuAssetFsize[\(asset)]"
            )) + 1)
        }
        let totalAssetByteCount = assetByteCounts.reduce(0, +)
        guard headerByteCount + totalAssetByteCount <= frameByteCount else {
            throw DTSError.malformed("ExSS assets exceed the declared frame size")
        }

        var assets: [Data] = []
        assets.reserveCapacity(assetCount)
        var offset = headerByteCount
        for count in assetByteCounts {
            assets.append(data.subdata(in: offset..<(offset + count)))
            offset += count
        }
        return DTSExSSFrameAST(
            exssIndex: exssIndex,
            wideHeader: wide,
            headerByteCount: headerByteCount,
            frameByteCount: frameByteCount,
            staticFieldsPresent: staticFields,
            presentationCount: presentationCount,
            assetByteCounts: assetByteCounts,
            header: data.subdata(in: 0..<headerByteCount),
            assets: assets,
            trailingBytes: data.subdata(in: offset..<frameByteCount)
        )
    }
}
