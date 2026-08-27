import Foundation

/// Private navigation block between the prediction CRC and entropy segments.
/// It contains one `bitWidth`-bit size-minus-one value per XLL segment,
/// byte-aligned zero padding, and a trailing CRC16.
public struct DTSXPrivateNavigation: Sendable, Equatable, Codable {
    /// Legacy two-segment profile used by the specialized parser below.
    public static let segmentCount = 2
    public static let byteCount = 5
    public static let supportedBitWidths = 8...16

    public let bitWidth: Int
    public let segmentByteCounts: [Int]
    public let zeroPaddingBitCount: Int
    public let trailingFrameByteCount: Int
    public let storedCRC16: UInt16
    public let crcIsValid: Bool

    public var serializedByteCount: Int {
        Self.navigationDataBitCount(
            bitWidth: bitWidth,
            segmentCount: segmentByteCounts.count
        ) / 8 + 2
    }

    public init(
        bitWidth: Int,
        segmentByteCounts: [Int],
        trailingFrameByteCount: Int
    ) throws {
        guard Self.supportedBitWidths.contains(bitWidth) else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X navigation bit width",
                value: String(bitWidth)
            )
        }
        guard !segmentByteCounts.isEmpty,
              segmentByteCounts.count <= 16,
              segmentByteCounts.allSatisfy({ $0 > 0 && $0 <= (1 << bitWidth) }) else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X navigation segment byte count",
                value: String(describing: segmentByteCounts)
            )
        }
        guard (0...7).contains(trailingFrameByteCount) else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X navigation trailing frame bytes",
                value: String(trailingFrameByteCount)
            )
        }
        self.bitWidth = bitWidth
        self.segmentByteCounts = segmentByteCounts
        self.zeroPaddingBitCount = Self.navigationDataBitCount(
            bitWidth: bitWidth,
            segmentCount: segmentByteCounts.count
        ) - bitWidth * segmentByteCounts.count
        self.trailingFrameByteCount = trailingFrameByteCount
        let serialized = try Self.serializeFields(
            bitWidth: bitWidth,
            segmentByteCounts: segmentByteCounts
        )
        self.storedCRC16 = (UInt16(serialized[serialized.count - 2]) << 8)
            | UInt16(serialized[serialized.count - 1])
        self.crcIsValid = true
    }

    private init(
        bitWidth: Int,
        segmentByteCounts: [Int],
        trailingFrameByteCount: Int,
        storedCRC16: UInt16,
        crcIsValid: Bool
    ) {
        self.bitWidth = bitWidth
        self.segmentByteCounts = segmentByteCounts
        self.zeroPaddingBitCount = Self.navigationDataBitCount(
            bitWidth: bitWidth,
            segmentCount: segmentByteCounts.count
        ) - bitWidth * segmentByteCounts.count
        self.trailingFrameByteCount = trailingFrameByteCount
        self.storedCRC16 = storedCRC16
        self.crcIsValid = crcIsValid
    }

    public func serialize() throws -> Data {
        try Self.serializeFields(
            bitWidth: bitWidth,
            segmentByteCounts: segmentByteCounts
        )
    }

    static func parse(
        _ data: Data,
        entropyStartByteOffset: Int,
        frameBodyByteCount: Int
    ) throws -> DTSXPrivateNavigation {
        let candidates = try parseCandidates(
            data,
            entropyStartByteOffset: entropyStartByteOffset,
            frameBodyByteCount: frameBodyByteCount
        )
        guard candidates.count == 1 else {
            let reason = candidates.isEmpty ? "no" : "multiple"
            throw DTSError.malformed(
                "XLL-X private navigation has \(reason) frame-size-consistent bit width"
            )
        }
        return candidates[0]
    }

    static func parseCandidates(
        _ data: Data,
        entropyStartByteOffset: Int,
        frameBodyByteCount: Int
    ) throws -> [DTSXPrivateNavigation] {
        guard data.count == byteCount else {
            throw DTSError.truncated(
                field: "XLL-X private navigation",
                bitOffset: data.count * 8
            )
        }
        let crcIsValid = DTSCRC16.checksum(data) == 0
        guard crcIsValid else {
            throw DTSError.checksumMismatch(component: "XLL-X private navigation")
        }
        let storedCRC = (UInt16(data[3]) << 8) | UInt16(data[4])
        let dataWord = (UInt32(data[0]) << 16)
            | (UInt32(data[1]) << 8)
            | UInt32(data[2])
        var candidates: [DTSXPrivateNavigation] = []
        for width in 8...12 {
            let paddingBitCount = 24 - width * segmentCount
            let paddingMask = paddingBitCount == 0
                ? UInt32(0)
                : UInt32((1 << paddingBitCount) - 1)
            guard dataWord & paddingMask == 0 else { continue }
            let valueMask = UInt32((1 << width) - 1)
            let first = Int((dataWord >> UInt32(24 - width)) & valueMask) + 1
            let second = Int(
                (dataWord >> UInt32(24 - width * 2)) & valueMask
            ) + 1
            let trailing = frameBodyByteCount
                - entropyStartByteOffset
                - first
                - second
            guard (0...7).contains(trailing) else { continue }
            candidates.append(DTSXPrivateNavigation(
                bitWidth: width,
                segmentByteCounts: [first, second],
                trailingFrameByteCount: trailing,
                storedCRC16: storedCRC,
                crcIsValid: crcIsValid
            ))
        }
        return candidates
    }

    static func parse(
        body: Data,
        navigationStartByteOffset: Int,
        segmentCount: Int
    ) throws -> DTSXPrivateNavigation {
        let candidates = try parseCandidates(
            body: body,
            navigationStartByteOffset: navigationStartByteOffset,
            segmentCount: segmentCount
        )
        guard candidates.count == 1 else {
            let reason = candidates.isEmpty ? "no" : "multiple"
            throw DTSError.malformed(
                "XLL-X private navigation has \(reason) frame-size-consistent generalized form"
            )
        }
        return candidates[0]
    }

    static func parseCandidates(
        body: Data,
        navigationStartByteOffset: Int,
        segmentCount: Int
    ) throws -> [DTSXPrivateNavigation] {
        guard segmentCount > 0, segmentCount <= 16 else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X private navigation segment count",
                value: String(segmentCount)
            )
        }
        var candidates: [DTSXPrivateNavigation] = []
        for width in supportedBitWidths {
            let dataBitCount = navigationDataBitCount(
                bitWidth: width,
                segmentCount: segmentCount
            )
            let dataByteCount = dataBitCount / 8
            let navigationByteCount = dataByteCount + 2
            let navigationEnd = navigationStartByteOffset + navigationByteCount
            guard navigationStartByteOffset >= 0, navigationEnd <= body.count else { continue }
            let data = Data(body[navigationStartByteOffset..<navigationEnd])
            guard DTSCRC16.checksum(data) == 0 else { continue }

            let protectedData = Data(data.prefix(dataByteCount))
            var reader = try BitReader(data: protectedData)
            var segmentByteCounts: [Int] = []
            segmentByteCounts.reserveCapacity(segmentCount)
            for segment in 0..<segmentCount {
                segmentByteCounts.append(Int(try reader.read(
                    width,
                    field: "XLL-X private NAVI[\(segment)]"
                )) + 1)
            }
            var paddingIsZero = true
            while reader.bitsRemaining > 0 {
                if try reader.read(1, field: "XLL-X private NAVI padding") != 0 {
                    paddingIsZero = false
                }
            }
            guard paddingIsZero else { continue }
            let entropyStart = navigationEnd
            let trailing = body.count - entropyStart - segmentByteCounts.reduce(0, +)
            guard (0...7).contains(trailing) else { continue }
            let storedCRC = (UInt16(data[dataByteCount]) << 8)
                | UInt16(data[dataByteCount + 1])
            candidates.append(DTSXPrivateNavigation(
                bitWidth: width,
                segmentByteCounts: segmentByteCounts,
                trailingFrameByteCount: trailing,
                storedCRC16: storedCRC,
                crcIsValid: true
            ))
        }
        return candidates
    }

    private static func serializeFields(
        bitWidth: Int,
        segmentByteCounts: [Int]
    ) throws -> Data {
        guard supportedBitWidths.contains(bitWidth),
              !segmentByteCounts.isEmpty,
              segmentByteCounts.count <= 16,
              segmentByteCounts.allSatisfy({ $0 > 0 && $0 <= (1 << bitWidth) }) else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X private navigation fields",
                value: "bitWidth=\(bitWidth), segmentByteCounts=\(segmentByteCounts)"
            )
        }
        var writer = BitWriter()
        for segment in segmentByteCounts.indices {
            try writer.write(
                UInt64(segmentByteCounts[segment] - 1),
                bitCount: bitWidth,
                field: "XLL-X private NAVI[\(segment)]"
            )
        }
        let dataBitCount = bitWidth * segmentByteCounts.count
        let paddedDataBitCount = navigationDataBitCount(
            bitWidth: bitWidth,
            segmentCount: segmentByteCounts.count
        )
        let paddingBitCount = paddedDataBitCount - dataBitCount
        if paddingBitCount > 0 {
            try writer.write(
                0,
                bitCount: paddingBitCount,
                field: "XLL-X private NAVI zero padding"
            )
        }
        guard writer.bitCount == paddedDataBitCount else {
            throw DTSError.malformed("XLL-X private NAVI data is not byte aligned")
        }
        guard writer.byteCount == paddedDataBitCount / 8 else {
            throw DTSError.malformed("XLL-X private NAVI data byte count changed")
        }
        try DTSCRC16.appendChecksum(
            to: &writer,
            protectedByteOffset: 0,
            component: "XLL-X private NAVI"
        )
        guard writer.byteCount == paddedDataBitCount / 8 + 2 else {
            throw DTSError.malformed("XLL-X private NAVI CRC byte count changed")
        }
        return writer.data()
    }

    static func navigationDataBitCount(bitWidth: Int, segmentCount: Int) -> Int {
        let alignedBitCount = ((bitWidth * segmentCount + 7) / 8) * 8
        // The recovered two-segment form reserves at least three data bytes,
        // but it is not fixed at three bytes. Official active frames grow to
        // four bytes for 13/14-bit segment extents before the trailing CRC16.
        return segmentCount == Self.segmentCount
            ? max(24, alignedBitCount)
            : alignedBitCount
    }

    /// Exact serialized navigation size (data bytes plus trailing CRC16) for
    /// one width/segment-count pair. This follows the same minimum-three-byte
    /// rule as ``serialize()`` so size accounting can never diverge from the
    /// emitted bytes (the previous encoder-side `(width x segments + 7) / 8`
    /// estimate undercounted the reserved two-segment data area below 12-bit
    /// widths).
    static func serializedByteCount(bitWidth: Int, segmentCount: Int) -> Int {
        navigationDataBitCount(bitWidth: bitWidth, segmentCount: segmentCount) / 8 + 2
    }

    /// Two-segment NAVI widths the official corpus exercises: the canonical
    /// three-data-byte word carries 11-bit extents, and large active frames
    /// grow to the four-data-byte word with 13/14-bit extents. 8-10 and
    /// 12-bit words also fit three data bytes - and 15/16-bit words four -
    /// but no reference stream emits them, and a terminal bounded reader
    /// keyed to the recovered forms misparses exactly those frames. Delivery
    /// encoding must therefore never select a width outside this ladder.
    static let officialTwoSegmentBitWidths = [11, 13, 14]
}

public extension DTSXPrivateFrameAST {
    func parseNavigation(segmentCount: Int = DTSXPrivateNavigation.segmentCount)
        throws -> DTSXPrivateNavigation {
        let predictionCRC = try parsePredictionCRC()
        let navigationStart = predictionCRC.bodyByteOffset + 2
        return try DTSXPrivateNavigation.parse(
            body: body,
            navigationStartByteOffset: navigationStart,
            segmentCount: segmentCount
        )
    }

    /// Resolves a CRC-valid but frame-size-ambiguous NAVI word using entropy
    /// segment boundaries already closed by the generic decoder. This does not
    /// guess from PCM: the chosen widths must reproduce every byte-aligned
    /// segment extent and the exact entropy start offset.
    func parseNavigation(
        segmentCount: Int,
        matching decoded: DTSXPrivateIsolatedDecodedFrame
    ) throws -> DTSXPrivateNavigation {
        guard decoded.segmentBoundaryBitOffsets.count == segmentCount,
              decoded.entropyStartBitOffset.isMultiple(of: 8) else {
            throw DTSError.malformed(
                "XLL-X decoded segment boundaries cannot qualify navigation"
            )
        }
        var segmentByteCounts: [Int] = []
        segmentByteCounts.reserveCapacity(segmentCount)
        var segmentStartBitOffset = decoded.entropyStartBitOffset
        for boundary in decoded.segmentBoundaryBitOffsets {
            guard boundary >= segmentStartBitOffset else {
                throw DTSError.malformed(
                    "XLL-X decoded segment boundary precedes its start"
                )
            }
            let bitCount = boundary - segmentStartBitOffset
            let byteCount = (bitCount + 7) / 8
            segmentByteCounts.append(byteCount)
            segmentStartBitOffset += byteCount * 8
        }

        let predictionCRC = try parsePredictionCRC()
        let navigationStart = predictionCRC.bodyByteOffset + 2
        let candidates: [DTSXPrivateNavigation]
        candidates = try DTSXPrivateNavigation.parseCandidates(
            body: body,
            navigationStartByteOffset: navigationStart,
            segmentCount: segmentCount
        )
        let matches = candidates.filter {
            $0.segmentByteCounts == segmentByteCounts
                && navigationStart + $0.serializedByteCount
                    == decoded.entropyStartBitOffset / 8
        }
        guard matches.count == 1 else {
            let reason = matches.isEmpty ? "no" : "multiple"
            throw DTSError.malformed(
                "XLL-X private navigation has \(reason) entropy-boundary-qualified form"
            )
        }
        return matches[0]
    }

    func serializeReplacingNavigation(
        _ navigation: DTSXPrivateNavigation
    ) throws -> Data {
        let predictionCRC = try parsePredictionCRC()
        let navigationStart = predictionCRC.bodyByteOffset + 2
        let serializedNavigation = try navigation.serialize()
        let navigationEnd = navigationStart + serializedNavigation.count
        guard navigationEnd <= body.count else {
            throw DTSError.truncated(
                field: "XLL-X private navigation replacement",
                bitOffset: navigationStart * 8
            )
        }
        var rebuiltBody = body
        rebuiltBody.replaceSubrange(
            navigationStart..<navigationEnd,
            with: serializedNavigation
        )
        return try DTSXPrivateFrameAST(
            fixedHeaderBytes: fixedHeaderBytes,
            headerCRC16: headerCRC16,
            packetType: packetType,
            reservedHighFourBits: reservedHighFourBits,
            primarySixBitCode: primarySixBitCode,
            separatorSixBits: separatorSixBits,
            secondarySyncWord: secondarySyncWord,
            secondaryPrefixSixBits: secondaryPrefixSixBits,
            secondaryTenBitCode: secondaryTenBitCode,
            body: rebuiltBody
        ).serialize()
    }
}
