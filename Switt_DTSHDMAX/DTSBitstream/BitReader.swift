import Foundation

struct BitReader: Sendable {
    /// Data provides O(1) indexed access without copying the complete source
    /// for every reader positioned inside a long elementary stream.
    let bytes: Data
    private(set) var bitOffset: Int
    let bitLimit: Int

    init(data: Data, byteOffset: Int = 0, byteCount: Int? = nil) throws {
        let count = byteCount ?? (data.count - byteOffset)
        guard byteOffset >= 0, count >= 0, byteOffset + count <= data.count else {
            throw DTSError.truncated(field: "BitReader", bitOffset: max(0, byteOffset) * 8)
        }
        self.bytes = data
        self.bitOffset = byteOffset * 8
        self.bitLimit = (byteOffset + count) * 8
    }

    init(bytes: [UInt8], bitOffset: Int = 0, bitLimit: Int? = nil) throws {
        let limit = bitLimit ?? bytes.count * 8
        guard bitOffset >= 0, limit >= bitOffset, limit <= bytes.count * 8 else {
            throw DTSError.truncated(field: "BitReader", bitOffset: max(0, bitOffset))
        }
        self.bytes = Data(bytes)
        self.bitOffset = bitOffset
        self.bitLimit = limit
    }

    var bitsRemaining: Int { bitLimit - bitOffset }
    var isByteAligned: Bool { bitOffset.isMultiple(of: 8) }

    /// Reads at most one partial byte at each end and whole bytes in between.
    ///
    /// The former implementation advanced one bit at a time. Decoder-side
    /// verification calls this method millions of times during a feature
    /// encode, so byte-chunking is materially faster while preserving the
    /// same MSB-first value and exact bit offset.
    @inline(__always)
    mutating func read(
        _ width: Int,
        field: @autoclosure () -> String
    ) throws -> UInt64 {
        guard (0...64).contains(width), bitOffset + width <= bitLimit else {
            throw DTSError.truncated(field: field(), bitOffset: bitOffset)
        }
        guard width > 0 else { return 0 }

        var result: UInt64 = 0
        var remaining = width
        while remaining > 0 {
            let bitInByte = bitOffset & 7
            let available = 8 - bitInByte
            let chunkWidth = min(remaining, available)
            let sourceShift = available - chunkWidth
            let mask = (UInt64(1) << UInt64(chunkWidth)) - 1
            let byte = UInt64(bytes[bitOffset >> 3])
            result = (result << UInt64(chunkWidth))
                | ((byte >> UInt64(sourceShift)) & mask)
            bitOffset += chunkWidth
            remaining -= chunkWidth
        }
        return result
    }

    @inline(__always)
    mutating func readSignedZigZag(
        _ width: Int,
        field: @autoclosure () -> String
    ) throws -> Int32 {
        let value = try read(width, field: field())
        let magnitude = Int64(value >> 1)
        let signed = (value & 1) == 0 ? magnitude : -magnitude - 1
        guard signed >= Int64(Int32.min), signed <= Int64(Int32.max) else {
            throw DTSError.valueOutOfRange(field: field(), value: String(signed))
        }
        return Int32(signed)
    }

    /// Reads a DTS unary quotient: zero bits terminated by a one bit.
    /// A caller supplies a syntax-specific bound so malformed entropy data
    /// cannot consume a following section while looking for a terminator.
    @inline(__always)
    mutating func readUnary(
        maximumZeroBitCount: Int,
        field: @autoclosure () -> String
    ) throws -> Int {
        guard maximumZeroBitCount >= 0 else {
            throw DTSError.valueOutOfRange(
                field: "\(field()).maximumZeroBitCount",
                value: String(maximumZeroBitCount)
            )
        }
        var quotient = 0
        while true {
            guard quotient <= maximumZeroBitCount else {
                throw DTSError.malformed("\(field()) exceeds its bounded unary length")
            }
            guard bitOffset < bitLimit else {
                throw DTSError.truncated(field: field(), bitOffset: bitOffset)
            }

            let bitInByte = bitOffset & 7
            let available = min(8 - bitInByte, bitLimit - bitOffset)
            let sourceShift = 8 - bitInByte - available
            let mask = (UInt16(1) << UInt16(available)) - 1
            let chunk = UInt8(
                (UInt16(bytes[bitOffset >> 3]) >> UInt16(sourceShift)) & mask
            )
            if chunk == 0 {
                quotient += available
                bitOffset += available
                continue
            }

            let leadingZeroCount = chunk.leadingZeroBitCount
                - (UInt8.bitWidth - available)
            guard quotient + leadingZeroCount <= maximumZeroBitCount else {
                throw DTSError.malformed("\(field()) exceeds its bounded unary length")
            }
            bitOffset += leadingZeroCount + 1
            return quotient + leadingZeroCount
        }
    }

    mutating func skip(_ width: Int, field: String) throws {
        guard width >= 0, bitOffset + width <= bitLimit else {
            throw DTSError.truncated(field: field, bitOffset: bitOffset)
        }
        bitOffset += width
    }

    mutating func seek(to target: Int, field: String) throws {
        guard target >= bitOffset, target <= bitLimit else {
            throw DTSError.truncated(field: field, bitOffset: target)
        }
        bitOffset = target
    }

    mutating func alignToByte(field: String = "byte alignment") throws {
        try skip((-bitOffset) & 7, field: field)
    }
}
