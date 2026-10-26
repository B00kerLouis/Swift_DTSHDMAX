import Foundation

/// One frame-local, full-coded audio group. Its NAVI width is finalized only
/// after both IMAX groups and the enclosing public plan have contributed.
struct DTSIMAXBareChannelSet: Sendable {
    let header: Data
    let segments: [Data]
    let channelCount: Int
    let segmentSampleCount: Int
    let requiredNavigationWidth: Int
    let predictionOrders: [Int]
    let fixedPredictionOrders: [Int]
    let fixedHeaderNavigationWidth: Int?

    func serialize(navigationWidth: Int) throws -> Data {
        guard navigationWidth >= requiredNavigationWidth, navigationWidth <= 16,
              fixedHeaderNavigationWidth == nil || fixedHeaderNavigationWidth == navigationWidth else {
            throw DTSError.malformed("IMAX group NAVI width cannot represent its segments")
        }
        var navi = BitWriter()
        for (index, segment) in segments.enumerated() {
            try navi.write(UInt64(segment.count - 1), bitCount: navigationWidth, field: "IMAX NAVI[\(index)]")
        }
        navi.alignToByte()
        try DTSCRC16.appendChecksum(to: &navi, protectedByteOffset: 0, component: "IMAX group NAVI")
        var output = header
        output.append(navi.data())
        for segment in segments { output.append(segment) }
        return output
    }
}

/// Fixed 12.1 presentation: TFC first, then TFL/TFR/TBL/TBR. Only the
/// persistent mapping bytes are fixed; every audio group is natively encoded.
struct DTSIMAXPrivateFrame: Sendable {
    static let syncWord: UInt32 = 0xf140_00d0
    // CRC-closed type-241/type-3 mapping: TFC at (0,25.5), C/L/R fold
    // coefficients 27571/13818/13818 in Q15, four unity height folds.
    static let metadata = Data([
        0xf1,0x40,0x00,0xd0,0x30,0x28,0x4b,0x00,0xe1,0x00,0x02,0x0c,0xf7,0xf7,0x89,0xa8,
        0x1f,0xab,0xae,0x00,0x03,0x00,0x08,0x81,0xf4,0xe2,0x1a,0xc4,0x04,0x7f,0x40,0x25,
        0xef,0xa0,0x49,0xef,0xa8,0x81,0xef,0xb1,0x01,0xef,0xa0,0x31,0xb3
    ])
    private static let markerTail = Data([0x34,0x38,0x8c,0x4f])

    struct Group: Sendable {
        let bytes: Data
        let channelCount: Int
        let segmentCount: Int
        let navigationWidth: Int
        let chunkByteCount: Int
    }
    let data: Data
    let groups: [Group]
    var navigationWidth: Int { groups.map(\.navigationWidth).max() ?? 0 }
    var segmentCount: Int { groups.first?.segmentCount ?? 0 }

    static func encode(
        planes: [[Int32]], plan: XLLSegmentationPlan, encodeMode: DTSEncodeMode
    ) throws -> DTSIMAXPrivateFrame {
        guard planes.count == 5 else { throw DTSError.invalidArgument("IMAX private input requires TFC and four heights") }
        guard let publicWidth = plan.segmentSizeBitCount else { throw DTSError.invalidArgument("IMAX requires the enclosing public NAVI width") }
        let codec = XLLEncoder(
            codingMode: encodeMode == .auto ? .terminalOfficialPredictive : .terminalOfficialRice,
            maximumPredictionOrder: 10
        )
        let first = try codec.encodeIMAXChannelSet(planes: [planes[0]], segmentCount: plan.segmentCount)
        let second = try codec.encodeIMAXChannelSet(planes: Array(planes.dropFirst()), segmentCount: plan.segmentCount)
        let width = max(8, publicWidth, first.requiredNavigationWidth, second.requiredNavigationWidth)
        var output = metadata
        for (mask, group) in [(UInt8(3), first), (UInt8(2), second)] {
            output.append(mask)
            output.append(markerTail)
            let body = try group.serialize(navigationWidth: width)
            let framed = try commonFrame(body: body, segmentCount: plan.segmentCount, navigationWidth: width)
            output.append(framed.dropFirst(4))
        }
        while !output.count.isMultiple(of: 4) { output.append(0) }
        let result = try parse(output)
        try result.validate(plan: plan, allowWiderWidth: true)
        guard try result.decode() == planes else {
            throw DTSError.malformed("IMAX private audio failed sample-exact frame reconstruction")
        }
        return result
    }

    /// These controls are XLL common headers with the four-byte sync omitted.
    /// Keep the virtual size (including that sync) and its CRC, so offsets can
    /// be derived without scanning entropy for candidate channel headers.
    static func commonFrame(body: Data, segmentCount: Int, navigationWidth: Int) throws -> Data {
        var sizeBits = 7
        var common = Data()
        var size = 0
        for _ in 0..<8 {
            var writer = BitWriter()
            try writer.write(0x41a2_9547, bitCount: 32, field: "IMAX virtual XLL sync")
            try writer.write(0, bitCount: 4, field: "IMAX XLL version")
            let headerSizeOffset = writer.bitCount
            try writer.write(0, bitCount: 8, field: "IMAX common header size")
            try writer.write(UInt64(sizeBits - 1), bitCount: 5, field: "IMAX frame-size width")
            let frameSizeOffset = writer.bitCount
            try writer.write(0, bitCount: sizeBits, field: "IMAX virtual frame size")
            try writer.write(0, bitCount: 4, field: "IMAX channel-set count")
            try writer.write(UInt64(ceilLog2(segmentCount)), bitCount: 4, field: "IMAX segment count")
            try writer.write(UInt64(ceilLog2(512 / segmentCount)), bitCount: 4, field: "IMAX segment samples")
            try writer.write(UInt64(navigationWidth - 1), bitCount: 5, field: "IMAX NAVI width")
            try writer.write(0, bitCount: 2, field: "IMAX band CRC mode")
            try writer.write(0, bitCount: 1, field: "IMAX scalable LSB flag")
            try writer.write(0, bitCount: 5, field: "IMAX unmapped mask width")
            writer.alignToByte()
            let headerBytes = writer.byteCount + 2
            size = (headerBytes + body.count + 3) & ~3
            let needed = max(7, ceilLog2(size))
            if needed != sizeBits { sizeBits = needed; continue }
            try writer.patch(at: headerSizeOffset, value: UInt64(headerBytes - 1), bitCount: 8, field: "IMAX header size")
            try writer.patch(at: frameSizeOffset, value: UInt64(size - 1), bitCount: sizeBits, field: "IMAX frame size")
            try DTSCRC16.appendChecksum(to: &writer, protectedByteOffset: 4, component: "IMAX common header")
            common = writer.data()
            break
        }
        guard !common.isEmpty else { throw DTSError.malformed("IMAX common-size finalization failed") }
        common.append(body)
        while common.count < size { common.append(0) }
        return common
    }

    static func isIMAX(_ bytes: Data) -> Bool { bytes.prefix(4) == metadata.prefix(4) }

    static func parse(_ bytes: Data) throws -> DTSIMAXPrivateFrame {
        guard bytes.count.isMultiple(of: 4), bytes.count > metadata.count,
              bytes.prefix(metadata.count) == metadata,
              DTSCRC16.checksum(metadata) == 0 else {
            throw DTSError.malformed("IMAX fixed presentation metadata or alignment is invalid")
        }
        var cursor = metadata.count
        var groups: [Group] = []
        for (ordinal, mask) in [UInt8(3), UInt8(2)].enumerated() {
            guard cursor + 5 < bytes.count, bytes[cursor] == mask,
                  bytes.subdata(in: cursor + 1..<cursor + 5) == markerTail else {
                throw DTSError.malformed("IMAX audio-group association is missing")
            }
            cursor += 5
            var reader = try BitReader(data: bytes, byteOffset: cursor)
            guard try reader.read(4, field: "IMAX common version") == 0 else { throw DTSError.unsupported("IMAX common version") }
            let headerBytes = Int(try reader.read(8, field: "IMAX common header bytes")) + 1
            let frameBits = Int(try reader.read(5, field: "IMAX frame size bits")) + 1
            let frameBytes = Int(try reader.read(frameBits, field: "IMAX frame bytes")) + 1
            guard try reader.read(4, field: "IMAX channel-set count") == 0 else { throw DTSError.malformed("IMAX group must contain one channel set") }
            let segments = 1 << Int(try reader.read(4, field: "IMAX segments"))
            let samples = 1 << Int(try reader.read(4, field: "IMAX segment samples"))
            let width = Int(try reader.read(5, field: "IMAX NAVI width")) + 1
            let headerEnd = cursor + headerBytes - 4
            let frameEnd = cursor + frameBytes - 4
            guard [2,4,8].contains(segments), samples * segments == 512,
                  (1...16).contains(width), headerBytes >= 12, headerEnd <= frameEnd,
                  frameEnd <= bytes.count,
                  DTSCRC16.checksum(bytes.subdata(in: cursor..<headerEnd)) == 0 else {
                throw DTSError.malformed("IMAX common header size, dimensions or CRC is invalid")
            }
            var bareReader = try BitReader(data: bytes, byteOffset: headerEnd, byteCount: frameEnd - headerEnd)
            let bareSize = Int(try bareReader.read(10, field: "IMAX channel header bytes")) + 1
            let channels = Int(try bareReader.read(4, field: "IMAX group channels")) + 1
            guard channels == (ordinal == 0 ? 1 : 4), bareSize <= frameEnd - headerEnd else {
                throw DTSError.malformed("IMAX audio-group channel count is invalid")
            }
            groups.append(Group(bytes: bytes.subdata(in: headerEnd..<frameEnd), channelCount: channels,
                                segmentCount: segments, navigationWidth: width, chunkByteCount: frameBytes + 1))
            cursor = frameEnd
        }
        guard bytes.count - cursor < 4, bytes[cursor...].allSatisfy({ $0 == 0 }) else {
            throw DTSError.malformed("IMAX private frame has a nonzero or oversized tail")
        }
        return DTSIMAXPrivateFrame(data: bytes, groups: groups)
    }

    func validate(plan: XLLSegmentationPlan, allowWiderWidth: Bool = false) throws {
        guard let publicWidth = plan.segmentSizeBitCount else { throw DTSError.malformed("IMAX public NAVI width is missing") }
        let expectedWidth = max(8, publicWidth)
        guard groups.allSatisfy({ $0.segmentCount == plan.segmentCount &&
            (allowWiderWidth ? $0.navigationWidth >= expectedWidth : $0.navigationWidth == expectedWidth) }),
              groups[0].navigationWidth == groups[1].navigationWidth else {
            throw DTSError.malformed("IMAX groups disagree with enclosing XLL navigation")
        }
    }

    func decode() throws -> [[Int32]] {
        try groups.flatMap { group in
            try XLLDecoder().decodeIMAXChannelSet(data: group.bytes, segmentCount: group.segmentCount,
                                                 segmentSizeBitCount: group.navigationWidth)
        }
    }

    private static func ceilLog2(_ value: Int) -> Int {
        value <= 1 ? 0 : Int.bitWidth - (value - 1).leadingZeroBitCount
    }
}
