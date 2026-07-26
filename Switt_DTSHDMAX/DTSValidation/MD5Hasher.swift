import Foundation

/// Incremental RFC 1321 MD5 used by the Encoder Suite-compatible job log.
/// The implementation is local so delivery artifact generation never invokes
/// a platform checksum process or links a third-party crypto package.
public struct MD5Hasher: Sendable {
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    ]

    private static let constants: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee,
        0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be,
        0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa,
        0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed,
        0xa9e3_e905, 0xfcef_a3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c,
        0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05,
        0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039,
        0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1,
        0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391
    ]

    private var state: [UInt32] = [
        0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476
    ]
    private var bufferedBytes: [UInt8] = []
    private var messageByteCount: UInt64 = 0

    public init() {
        bufferedBytes.reserveCapacity(64)
    }

    public mutating func update(_ data: Data) {
        updateCollection(data)
    }

    public mutating func update(_ bytes: [UInt8]) {
        updateCollection(bytes)
    }

    public func finalize() -> Data {
        var copy = self
        return copy.finalizedDigest()
    }

    public func finalizeHex() -> String {
        Self.hex(finalize())
    }

    public static func hash(_ data: Data) -> String {
        var hasher = MD5Hasher()
        hasher.update(data)
        return hasher.finalizeHex()
    }

    private mutating func updateCollection<Bytes: RandomAccessCollection>(_ bytes: Bytes)
    where Bytes.Element == UInt8, Bytes.Index == Int {
        guard !bytes.isEmpty else { return }
        messageByteCount &+= UInt64(bytes.count)
        var offset = bytes.startIndex

        if !bufferedBytes.isEmpty {
            let copied = min(64 - bufferedBytes.count, bytes.count)
            bufferedBytes.append(contentsOf: bytes[offset..<(offset + copied)])
            offset += copied
            if bufferedBytes.count == 64 {
                compress(bufferedBytes[...])
                bufferedBytes.removeAll(keepingCapacity: true)
            }
        }
        while offset + 64 <= bytes.endIndex {
            compress(bytes[offset..<(offset + 64)])
            offset += 64
        }
        if offset < bytes.endIndex {
            bufferedBytes.append(contentsOf: bytes[offset..<bytes.endIndex])
        }
    }

    private mutating func finalizedDigest() -> Data {
        let bitCount = messageByteCount &* 8
        var tail = bufferedBytes
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 0, through: 56, by: 8) {
            tail.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }
        for offset in stride(from: 0, to: tail.count, by: 64) {
            compress(tail[offset..<(offset + 64)])
        }

        var digest = Data()
        digest.reserveCapacity(16)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return digest
    }

    private mutating func compress<Bytes: RandomAccessCollection>(_ block: Bytes)
    where Bytes.Element == UInt8, Bytes.Index == Int {
        precondition(block.count == 64)
        let start = block.startIndex
        var words = [UInt32](repeating: 0, count: 16)
        for index in words.indices {
            let offset = start + index * 4
            words[index] = UInt32(block[offset])
                | (UInt32(block[offset + 1]) << 8)
                | (UInt32(block[offset + 2]) << 16)
                | (UInt32(block[offset + 3]) << 24)
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        for index in 0..<64 {
            let function: UInt32
            let wordIndex: Int
            switch index {
            case 0..<16:
                function = (b & c) | (~b & d)
                wordIndex = index
            case 16..<32:
                function = (d & b) | (~d & c)
                wordIndex = (5 * index + 1) & 15
            case 32..<48:
                function = b ^ c ^ d
                wordIndex = (3 * index + 5) & 15
            default:
                function = c ^ (b | ~d)
                wordIndex = (7 * index) & 15
            }
            let rotated = rotateLeft(
                a &+ function &+ Self.constants[index] &+ words[wordIndex],
                by: Self.shifts[index]
            )
            a = d
            d = c
            c = b
            b &+= rotated
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
    }

    private func rotateLeft(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    private static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 2)
        for byte in data {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
