import Foundation

/// Private navigation block between the prediction CRC and entropy segments.
/// It contains one `bitWidth`-bit size-minus-one value per XLL segment,
/// byte-aligned zero padding, and a trailing CRC16.
public struct DTSXPrivateNavigation: Sendable, Equatable, Codable {
    /// Legacy two-segment profile used by the specialized parser below.
    public static let segmentCount = 2
    public static let byteCount = 5

    public let bitWidth: Int
    public let segmentByteCounts: [Int]
    public let zeroPaddingBitCount: Int
    public let trailingFrameByteCount: Int
    public let storedCRC16: UInt16
    public let crcIsValid: Bool

    public var serializedByteCount: Int {
        let dataByteCount = segmentByteCounts.count == Self.segmentCount
            ? 3
            : (bitWidth * segmentByteCounts.count + 7) / 8
        return dataByteCount + 2
    }

    public init(
        bitWidth: Int,
        segmentByteCounts: [Int],
        trailingFrameByteCount: Int
    ) throws {
        guard (8...12).contains(bitWidth) else {
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
        guard candidates.count == 1 else {
            let reason = candidates.isEmpty ? "no" : "multiple"
            throw DTSError.malformed(
                "XLL-X private navigation has \(reason) frame-size-consistent bit width"
            )
        }
        return candidates[0]
    }

    static func parse(
        body: Data,
        navigationStartByteOffset: Int,
        segmentCount: Int
    ) throws -> DTSXPrivateNavigation {
        guard segmentCount > 0, segmentCount <= 16 else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X private navigation segment count",
                value: String(segmentCount)
            )
        }
        var candidates: [DTSXPrivateNavigation] = []
        for width in 8...12 {
            let dataBitCount = width * segmentCount
            let dataByteCount = (dataBitCount + 7) / 8
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
        guard candidates.count == 1 else {
            let reason = candidates.isEmpty ? "no" : "multiple"
            throw DTSError.malformed(
                "XLL-X private navigation has \(reason) frame-size-consistent generalized form"
            )
        }
        return candidates[0]
    }

    private static func serializeFields(
        bitWidth: Int,
        segmentByteCounts: [Int]
    ) throws -> Data {
        guard (8...12).contains(bitWidth),
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

    private static func navigationDataBitCount(bitWidth: Int, segmentCount: Int) -> Int {
        segmentCount == Self.segmentCount
            ? 24
            : ((bitWidth * segmentCount + 7) / 8) * 8
    }
}

public extension DTSXPrivateFrameAST {
    func parseNavigation(segmentCount: Int = DTSXPrivateNavigation.segmentCount)
        throws -> DTSXPrivateNavigation {
        let predictionCRC = try parsePredictionCRC()
        let navigationStart = predictionCRC.bodyByteOffset + 2
        if segmentCount != DTSXPrivateNavigation.segmentCount {
            return try DTSXPrivateNavigation.parse(
                body: body,
                navigationStartByteOffset: navigationStart,
                segmentCount: segmentCount
            )
        }
        let navigationEnd = navigationStart + DTSXPrivateNavigation.byteCount
        guard navigationEnd <= body.count else {
            throw DTSError.truncated(
                field: "XLL-X private navigation",
                bitOffset: navigationStart * 8
            )
        }
        return try DTSXPrivateNavigation.parse(
            Data(body[navigationStart..<navigationEnd]),
            entropyStartByteOffset: navigationEnd,
            frameBodyByteCount: body.count
        )
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
