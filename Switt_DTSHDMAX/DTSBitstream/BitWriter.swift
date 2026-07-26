import Foundation

struct BitWriter: Sendable {
    private var accumulator: UInt64 = 0
    private var accumulatorBitCount = 0
    private var storage = ContiguousArray<UInt8>()
    private(set) var bitCount: Int = 0

    init(reservingCapacity byteCapacity: Int = 0) {
        if byteCapacity > 0 {
            storage.reserveCapacity(byteCapacity)
        }
    }

    var isByteAligned: Bool { bitCount.isMultiple(of: 8) }
    var byteCount: Int { storage.count + (accumulatorBitCount > 0 ? 1 : 0) }

    /// The complete written byte sequence. A partially written final byte is
    /// returned with its meaningful bits left-aligned, matching DTS bit order.
    var bytes: [UInt8] {
        var result = Array(storage)
        if accumulatorBitCount > 0 {
            result.append(UInt8(truncatingIfNeeded: accumulator << (8 - accumulatorBitCount)))
        }
        return result
    }

    @inline(__always)
    mutating func write(
        _ value: UInt64,
        bitCount width: Int,
        field: @autoclosure () -> String
    ) throws {
        guard (0...64).contains(width) else {
            throw DTSError.valueOutOfRange(field: "\(field()).width", value: String(width))
        }
        if width < 64, value >> UInt64(width) != 0 {
            throw DTSError.valueOutOfRange(field: field(), value: String(value))
        }
        guard width > 0 else { return }

        var remaining = width
        while remaining > 0 {
            let chunkBitCount = min(remaining, 64 - accumulatorBitCount)
            let sourceShift = remaining - chunkBitCount
            let chunk = (value >> UInt64(sourceShift)) & bitMask(width: chunkBitCount)
            accumulator = (accumulator << UInt64(chunkBitCount)) | chunk
            accumulatorBitCount += chunkBitCount
            bitCount += chunkBitCount
            remaining -= chunkBitCount
            flushWholeBytes()
        }
    }

    @inline(__always)
    mutating func writeSignedZigZag(
        _ value: Int32,
        bitCount width: Int,
        field: @autoclosure () -> String
    ) throws {
        let signed = Int64(value)
        let mapped: UInt64
        if signed >= 0 {
            mapped = UInt64(signed) << 1
        } else {
            mapped = UInt64((-signed << 1) - 1)
        }
        try write(mapped, bitCount: width, field: field())
    }

    /// Writes a DTS unary quotient: `quotient` zero bits followed by a one bit.
    /// Rice codes use this MSB-first representation before their fixed remainder.
    @inline(__always)
    mutating func writeUnary(
        _ quotient: Int,
        field: @autoclosure () -> String
    ) throws {
        guard quotient >= 0 else {
            throw DTSError.valueOutOfRange(field: field(), value: String(quotient))
        }
        var remaining = quotient
        while remaining >= 64 {
            try write(0, bitCount: 64, field: field())
            remaining -= 64
        }
        if remaining > 0 {
            try write(0, bitCount: remaining, field: field())
        }
        try write(1, bitCount: 1, field: field())
    }

    mutating func write(
        bytes newBytes: some Sequence<UInt8>,
        field: @autoclosure () -> String
    ) throws {
        if accumulatorBitCount == 0 {
            var appendedCount = 0
            for byte in newBytes {
                storage.append(byte)
                appendedCount += 1
            }
            bitCount += appendedCount * 8
            return
        }
        for byte in newBytes {
            try write(UInt64(byte), bitCount: 8, field: field())
        }
    }

    mutating func alignToByte() {
        guard accumulatorBitCount > 0 else { return }
        storage.append(UInt8(truncatingIfNeeded: accumulator << (8 - accumulatorBitCount)))
        bitCount += 8 - accumulatorBitCount
        accumulator = 0
        accumulatorBitCount = 0
    }

    @inline(__always)
    private mutating func flushWholeBytes() {
        while accumulatorBitCount >= 8 {
            let shift = accumulatorBitCount - 8
            storage.append(UInt8(truncatingIfNeeded: accumulator >> UInt64(shift)))
            accumulatorBitCount -= 8
            accumulator &= bitMask(width: accumulatorBitCount)
        }
    }

    @inline(__always)
    private func bitMask(width: Int) -> UInt64 {
        precondition((0...64).contains(width))
        return width == 64 ? .max : (UInt64(1) << UInt64(width)) - 1
    }

    mutating func alignTo(byteMultiple: Int) throws {
        guard byteMultiple > 0 else {
            throw DTSError.invalidArgument("alignment must be positive")
        }
        alignToByte()
        while storage.count % byteMultiple != 0 {
            try write(0, bitCount: 8, field: "alignment")
        }
    }

    mutating func patch(
        at bitOffset: Int,
        value: UInt64,
        bitCount width: Int,
        field: @autoclosure () -> String
    ) throws {
        guard bitOffset >= 0, width >= 0, bitOffset + width <= bitCount else {
            throw DTSError.valueOutOfRange(field: "\(field()).offset", value: String(bitOffset))
        }
        if width < 64, value >> UInt64(width) != 0 {
            throw DTSError.valueOutOfRange(field: field(), value: String(value))
        }
        guard width > 0 else { return }

        for index in 0..<width {
            let targetBit = bitOffset + index
            let byteIndex = targetBit >> 3
            let bitInByte = 7 - (targetBit & 7)
            let sourceShift = width - 1 - index
            let mask = UInt8(1 << UInt8(bitInByte))
            let isSet = ((value >> UInt64(sourceShift)) & 1) == 1
            if byteIndex < storage.count {
                if isSet {
                    storage[byteIndex] |= mask
                } else {
                    storage[byteIndex] &= ~mask
                }
            } else {
                let pendingBit = accumulatorBitCount - 1 - (targetBit - storage.count * 8)
                guard pendingBit >= 0 else {
                    throw DTSError.malformed("BitWriter patch points beyond buffered data")
                }
                let pendingMask = UInt64(1) << UInt64(pendingBit)
                if isSet {
                    accumulator |= pendingMask
                } else {
                    accumulator &= ~pendingMask
                }
            }
        }
    }

    func data() -> Data {
        guard accumulatorBitCount > 0 else { return Data(storage) }
        return Data(bytes)
    }
}
