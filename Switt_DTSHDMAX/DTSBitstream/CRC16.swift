import Foundation

enum DTSCRC16 {
    static let polynomial: UInt16 = 0x1021
    static let initial: UInt16 = 0xffff

    static func checksum<S: Sequence>(_ bytes: S, initialValue: UInt16 = initial) -> UInt16 where S.Element == UInt8 {
        var crc = initialValue
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ polynomial
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    static func appendChecksum(to writer: inout BitWriter, protectedByteOffset: Int, component: String) throws {
        writer.alignToByte()
        let protectedBytes = writer.bytes
        guard protectedByteOffset >= 0, protectedByteOffset <= protectedBytes.count else {
            throw DTSError.valueOutOfRange(field: "\(component).crcStart", value: String(protectedByteOffset))
        }
        let crc = checksum(protectedBytes[protectedByteOffset...])
        try writer.write(UInt64(crc), bitCount: 16, field: "\(component).crc16")
    }

    static func validate(_ bytes: ArraySlice<UInt8>, component: String) throws {
        guard bytes.count >= 2 else {
            throw DTSError.truncated(field: "\(component).crc16", bitOffset: 0)
        }
        guard checksum(bytes) == 0 else {
            throw DTSError.checksumMismatch(component: component)
        }
    }
}
