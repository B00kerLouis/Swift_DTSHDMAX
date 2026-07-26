import Foundation

public struct SHA256Hasher: Sendable {
    private static let initialState: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
    ]

    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2
    ]

    private var state = Self.initialState
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

    private mutating func updateCollection<Bytes: RandomAccessCollection>(_ bytes: Bytes)
    where Bytes.Element == UInt8, Bytes.Index == Int {
        guard !bytes.isEmpty else { return }
        messageByteCount &+= UInt64(bytes.count)

        var offset = bytes.startIndex
        if !bufferedBytes.isEmpty {
            let required = 64 - bufferedBytes.count
            let copied = min(required, bytes.count)
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

    public func finalize() -> Data {
        var copy = self
        return copy.finalizedDigest()
    }

    public func finalizeHex() -> String {
        Self.hex(finalize())
    }

    public static func hash(_ data: Data) -> String {
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalizeHex()
    }

    public static func hash(fileAt url: URL, chunkByteCount: Int = 1 << 20) throws -> String {
        guard chunkByteCount > 0 else {
            throw DTSError.invalidArgument("SHA-256 chunk size must be positive")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DTSError.io("cannot open \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        var hasher = SHA256Hasher()
        while true {
            let byteCount: Int = try autoreleasepool {
                let chunk: Data
                do { chunk = try handle.read(upToCount: chunkByteCount) ?? Data() }
                catch { throw DTSError.io("cannot read \(url.path): \(error.localizedDescription)") }
                if !chunk.isEmpty { hasher.update(chunk) }
                return chunk.count
            }
            if byteCount == 0 { break }
        }
        return hasher.finalizeHex()
    }

    public static func hash(
        fileAt url: URL,
        byteOffset: UInt64,
        byteCount: UInt64,
        chunkByteCount: Int = 1 << 20
    ) throws -> String {
        guard chunkByteCount > 0 else {
            throw DTSError.invalidArgument("SHA-256 chunk size must be positive")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw DTSError.io("cannot open \(url.path): \(error.localizedDescription)") }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: byteOffset) }
        catch { throw DTSError.io("cannot seek \(url.path): \(error.localizedDescription)") }

        var hasher = SHA256Hasher()
        var remaining = byteCount
        while remaining > 0 {
            let requested = Int(min(UInt64(chunkByteCount), remaining))
            let consumed: Int = try autoreleasepool {
                let chunk: Data
                do { chunk = try handle.read(upToCount: requested) ?? Data() }
                catch { throw DTSError.io("cannot read \(url.path): \(error.localizedDescription)") }
                guard chunk.count == requested else {
                    throw DTSError.truncated(
                        field: "SHA-256 file range",
                        bitOffset: Int(byteOffset + byteCount - remaining + UInt64(chunk.count)) * 8
                    )
                }
                hasher.update(chunk)
                return chunk.count
            }
            guard consumed == requested else {
                throw DTSError.truncated(
                    field: "SHA-256 file range",
                    bitOffset: Int(byteOffset + byteCount - remaining + UInt64(consumed)) * 8
                )
            }
            remaining -= UInt64(consumed)
        }
        return hasher.finalizeHex()
    }

    private mutating func finalizedDigest() -> Data {
        let messageBitCount = messageByteCount &* 8
        var tail = bufferedBytes
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8((messageBitCount >> UInt64(shift)) & 0xff))
        }
        for offset in stride(from: 0, to: tail.count, by: 64) {
            compress(tail[offset..<(offset + 64)])
        }

        var digest = Data()
        digest.reserveCapacity(32)
        for word in state {
            digest.append(UInt8((word >> 24) & 0xff))
            digest.append(UInt8((word >> 16) & 0xff))
            digest.append(UInt8((word >> 8) & 0xff))
            digest.append(UInt8(word & 0xff))
        }
        return digest
    }

    private mutating func compress<Bytes: RandomAccessCollection>(_ block: Bytes)
    where Bytes.Element == UInt8, Bytes.Index == Int {
        precondition(block.count == 64)
        var words = [UInt32](repeating: 0, count: 64)
        let start = block.startIndex
        for index in 0..<16 {
            let offset = start + index * 4
            words[index] = (UInt32(block[offset]) << 24)
                | (UInt32(block[offset + 1]) << 16)
                | (UInt32(block[offset + 2]) << 8)
                | UInt32(block[offset + 3])
        }
        for index in 16..<64 {
            let previous15 = words[index - 15]
            let previous2 = words[index - 2]
            let sigma0 = rotateRight(previous15, by: 7)
                ^ rotateRight(previous15, by: 18)
                ^ (previous15 >> 3)
            let sigma1 = rotateRight(previous2, by: 17)
                ^ rotateRight(previous2, by: 19)
                ^ (previous2 >> 10)
            words[index] = words[index - 16] &+ sigma0 &+ words[index - 7] &+ sigma1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]
        for index in 0..<64 {
            let bigSigma1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
            let choose = (e & f) ^ (~e & g)
            let temporary1 = h &+ bigSigma1 &+ choose &+ Self.roundConstants[index] &+ words[index]
            let bigSigma0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = bigSigma0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temporary1
            d = c
            c = b
            b = a
            a = temporary1 &+ temporary2
        }

        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
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
