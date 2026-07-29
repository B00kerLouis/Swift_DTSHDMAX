import Foundation

public struct XLLChannelSetAST: Sendable, Equatable, Codable {
    public let channelCount: Int
    public let residualChannelMask: UInt64
    public let bitDepth: Int
    public let storageBitDepth: Int
    public let sampleRateIndex: Int
    public let replacementSet: Int
    public let isPrimary: Bool
    public let hasEmbeddedDownmix: Bool
    public let hierarchical: Bool
    public let speakerMask: UInt64?
    public let headerByteRange: Range<Int>
}

public struct XLLFrameAST: Sendable, Equatable, Codable {
    public let frameByteCount: Int
    public let commonHeaderByteCount: Int
    public let frameSizeBitCount: Int
    public let channelSetCount: Int
    public let segmentCount: Int
    public let segmentSampleCount: Int
    public let segmentSizeBitCount: Int
    public let bandDataCRCMode: Int
    public let scalableLSBs: Bool
    public let fixedLSBWidth: Int?
    public let channelMaskBitCount: Int
    public let channelSets: [XLLChannelSetAST]
    public let naviByteRange: Range<Int>
    public let naviSegmentByteCounts: [Int]
    public let navigationCRC: UInt16
    public let bandDataByteRange: Range<Int>
    public let privateDataByteRange: Range<Int>
    public let data: Data

    public var privateData: Data { data.subdata(in: privateDataByteRange) }
    public var bandData: Data { data.subdata(in: bandDataByteRange) }

    public func serialize() -> Data { data }
}

public enum XLLFrameASTParser {
    public static func parse(_ data: Data) throws -> XLLFrameAST {
        let bytes = Array(data)
        var reader = try BitReader(bytes: bytes)
        guard try reader.read(32, field: "SYNCXLL") == XLLSyntax.syncWord else {
            throw DTSError.malformed("XLL sync word is missing")
        }
        let version = Int(try reader.read(4, field: "nVersion")) + 1
        guard version == XLLSyntax.streamVersion else {
            throw DTSError.unsupported("XLL syntax version \(version)")
        }
        let commonHeaderByteCount = Int(try reader.read(8, field: "nHeaderSize")) + 1
        let frameSizeBitCount = Int(try reader.read(5, field: "nBits4FrameFsize")) + 1
        let frameByteCount = Int(try reader.read(frameSizeBitCount, field: "nLLFrameSize")) + 1
        guard frameByteCount == data.count else {
            throw DTSError.malformed("XLL frame size does not equal supplied data")
        }
        let channelSetCount = Int(try reader.read(4, field: "nNumChSetsInFrame")) + 1
        let segmentCount = 1 << Int(try reader.read(4, field: "nSegmentsInFrame"))
        let segmentSampleCount = 1 << Int(try reader.read(4, field: "nSmplInSeg"))
        let segmentSizeBitCount = Int(try reader.read(5, field: "nBits4SSize")) + 1
        let bandDataCRCMode = Int(try reader.read(2, field: "nBandDataCRCEn"))
        let scalableLSBs = try reader.read(1, field: "bScalableLSBs") == 1
        let channelMaskBitCount = Int(try reader.read(5, field: "nBits4ChMask")) + 1
        let fixedLSBWidth = scalableLSBs
            ? Int(try reader.read(4, field: "nFixedLSBWidth"))
            : nil
        guard commonHeaderByteCount >= 6, commonHeaderByteCount <= data.count else {
            throw DTSError.malformed("XLL common header exceeds frame")
        }
        try DTSCRC16.validate(bytes[4..<commonHeaderByteCount], component: "XLL common header")
        try reader.seek(to: commonHeaderByteCount * 8, field: "XLL common header end")

        var channelSets: [XLLChannelSetAST] = []
        channelSets.reserveCapacity(channelSetCount)
        var lowerHierarchyChannelCount = 0
        for index in 0..<channelSetCount {
            let headerStart = reader.bitOffset / 8
            let headerByteCount = Int(try reader.read(10, field: "nChSetHeaderSize[\(index)]")) + 1
            let headerEnd = headerStart + headerByteCount
            guard headerEnd <= frameByteCount else {
                throw DTSError.malformed("XLL channel-set header exceeds frame")
            }
            let channelCount = Int(try reader.read(4, field: "nChSetLLChannel[\(index)]")) + 1
            let residual = try reader.read(channelCount, field: "nResidualChEncode[\(index)]")
            let bitDepth = Int(try reader.read(5, field: "nBitResolution[\(index)]")) + 1
            let storage = Int(try reader.read(5, field: "nBitWidth[\(index)]")) + 1
            let frequency = Int(try reader.read(4, field: "sFreqIndex[\(index)]"))
            _ = try reader.read(2, field: "nFsInterpolate[\(index)]")
            let replacement = Int(try reader.read(2, field: "nReplacementSet[\(index)]"))
            if replacement != 0 { _ = try reader.read(1, field: "bActiveReplaceSet[\(index)]") }
            let primary = try reader.read(1, field: "bPrimaryChSet[\(index)]") == 1
            let embedded = try reader.read(1, field: "bDownmixCoeffCodeEmbedded[\(index)]") == 1
            if embedded {
                _ = try reader.read(1, field: "bDownmixEmbedded[\(index)]")
                if primary { _ = try reader.read(3, field: "nLLDownmixType[\(index)]") }
            }
            let hierarchical = try reader.read(1, field: "bHierChSet[\(index)]") == 1
            if embedded {
                guard lowerHierarchyChannelCount > 0 else {
                    throw DTSError.malformed("XLL primary channel set has an embedded downmix")
                }
                try reader.skip(
                    (channelCount + 1) * lowerHierarchyChannelCount * 9,
                    field: "DownmixCoeffs[\(index)]"
                )
            }
            let hasSpeakerMask = try reader.read(1, field: "bChMaskEnabled[\(index)]") == 1
            let speakerMask = hasSpeakerMask
                ? try reader.read(channelMaskBitCount, field: "nChMask[\(index)]")
                : nil
            try DTSCRC16.validate(bytes[headerStart..<headerEnd], component: "XLL channel-set header")
            channelSets.append(XLLChannelSetAST(
                channelCount: channelCount,
                residualChannelMask: residual,
                bitDepth: bitDepth,
                storageBitDepth: storage,
                sampleRateIndex: frequency,
                replacementSet: replacement,
                isPrimary: primary,
                hasEmbeddedDownmix: embedded,
                hierarchical: hierarchical,
                speakerMask: speakerMask,
                headerByteRange: headerStart..<headerEnd
            ))
            lowerHierarchyChannelCount += channelCount
            try reader.seek(to: headerEnd * 8, field: "XLL channel-set header end")
        }

        let navigationStart = reader.bitOffset / 8
        var navi: [Int] = []
        let frequencyBandCount = channelSets.map { _ in 1 }
        for band in 0..<(frequencyBandCount.max() ?? 0) {
            for segment in 0..<segmentCount {
                for channelSet in 0..<channelSetCount where frequencyBandCount[channelSet] > band {
                    navi.append(Int(try reader.read(
                        segmentSizeBitCount,
                        field: "NAVI[\(band)][\(segment)][\(channelSet)]"
                    )) + 1)
                }
            }
        }
        try reader.alignToByte(field: "XLL NAVI alignment")
        let crc = UInt16(try reader.read(16, field: "XLL NAVI CRC16"))
        let navigationEnd = reader.bitOffset / 8
        try DTSCRC16.validate(bytes[navigationStart..<navigationEnd], component: "XLL NAVI")
        let bandByteCount = navi.reduce(0, +)
        let bandStart = navigationEnd
        let bandEnd = bandStart + bandByteCount
        guard bandEnd <= frameByteCount else {
            throw DTSError.malformed("XLL band data exceeds frame")
        }
        let privateStart = (bandEnd + 3) & ~3
        guard privateStart <= frameByteCount else {
            throw DTSError.malformed("XLL private-data alignment exceeds frame")
        }
        return XLLFrameAST(
            frameByteCount: frameByteCount,
            commonHeaderByteCount: commonHeaderByteCount,
            frameSizeBitCount: frameSizeBitCount,
            channelSetCount: channelSetCount,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            segmentSizeBitCount: segmentSizeBitCount,
            bandDataCRCMode: bandDataCRCMode,
            scalableLSBs: scalableLSBs,
            fixedLSBWidth: fixedLSBWidth,
            channelMaskBitCount: channelMaskBitCount,
            channelSets: channelSets,
            naviByteRange: navigationStart..<navigationEnd,
            naviSegmentByteCounts: navi,
            navigationCRC: crc,
            bandDataByteRange: bandStart..<bandEnd,
            privateDataByteRange: privateStart..<frameByteCount,
            data: data
        )
    }
}

public struct XLLPBRFrame: Sendable, Equatable, Codable {
    public let frame: Data
    public let startAccessUnit: Int
    public let endAccessUnit: Int
    public let sha256: String
}

/// Reassembles XLL frames when ExSS assets split a frame over AU boundaries.
/// It does not assume a frame starts at every asset boundary and therefore
/// handles both DTS:X PBR and ordinary one-frame-per-AU HDMA.
public enum XLLPBRAssembler {
    public static func assemble(assets: [(accessUnit: Int, data: Data)]) throws -> [XLLPBRFrame] {
        var pending = Data()
        var spans: [(count: Int, accessUnit: Int)] = []
        var output: [XLLPBRFrame] = []
        for asset in assets {
            pending.append(asset.data)
            if !asset.data.isEmpty { spans.append((asset.data.count, asset.accessUnit)) }
            while pending.count >= 8 {
                guard bigEndianUInt32(pending, at: 0) == UInt32(XLLSyntax.syncWord) else {
                    guard let sync = findSync(in: pending), sync > 0 else { break }
                    _ = consume(sync, data: &pending, spans: &spans)
                    continue
                }
                let size = try frameByteCount(pending)
                guard pending.count >= size else { break }
                let frame = Data(pending.prefix(size))
                let start = spans.first?.accessUnit ?? asset.accessUnit
                let end = consume(size, data: &pending, spans: &spans)
                output.append(XLLPBRFrame(
                    frame: frame,
                    startAccessUnit: start,
                    endAccessUnit: end,
                    sha256: SHA256Hasher.hash(frame)
                ))
            }
        }
        guard pending.isEmpty else {
            throw DTSError.truncated(field: "PBR XLL frame", bitOffset: pending.count * 8)
        }
        return output
    }

    private static func consume(
        _ count: Int,
        data: inout Data,
        spans: inout [(count: Int, accessUnit: Int)]
    ) -> Int {
        var remaining = count
        var end = spans.first?.accessUnit ?? 0
        while remaining > 0, !spans.isEmpty {
            end = spans[0].accessUnit
            if remaining < spans[0].count {
                spans[0].count -= remaining
                remaining = 0
            } else {
                remaining -= spans[0].count
                spans.removeFirst()
            }
        }
        data = Data(data.dropFirst(count))
        return end
    }

    private static func frameByteCount(_ data: Data) throws -> Int {
        var reader = try BitReader(data: data)
        guard try reader.read(32, field: "SYNCXLL") == XLLSyntax.syncWord else {
            throw DTSError.malformed("XLL sync word is missing")
        }
        _ = try reader.read(4, field: "nVersion")
        _ = try reader.read(8, field: "nHeaderSize")
        let width = Int(try reader.read(5, field: "nBits4FrameFsize")) + 1
        return Int(try reader.read(width, field: "nLLFrameSize")) + 1
    }

    private static func findSync(in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        for index in 0...(data.count - 4) where bigEndianUInt32(data, at: index) == UInt32(XLLSyntax.syncWord) {
            return index
        }
        return nil
    }

    private static func bigEndianUInt32(_ data: Data, at index: Int) -> UInt32 {
        (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
    }
}
