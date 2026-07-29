import Foundation

public enum DTSError: Error, CustomStringConvertible, Equatable {
    case invalidArgument(String)
    case unsupported(String)
    case malformed(String)
    case truncated(field: String, bitOffset: Int)
    case valueOutOfRange(field: String, value: String)
    case checksumMismatch(component: String)
    case io(String)

    public var description: String {
        switch self {
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        case .unsupported(let message):
            return "Unsupported: \(message)"
        case .malformed(let message):
            return "Malformed stream: \(message)"
        case .truncated(let field, let bitOffset):
            return "Truncated while reading \(field) at bit \(bitOffset)"
        case .valueOutOfRange(let field, let value):
            return "Value out of range for \(field): \(value)"
        case .checksumMismatch(let component):
            return "CRC-16 mismatch in \(component)"
        case .io(let message):
            return "I/O error: \(message)"
        }
    }
}

extension Data {
    func bigEndianUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw DTSError.truncated(field: "UInt16", bitOffset: Swift.max(0, offset) * 8)
        }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func littleEndianUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw DTSError.truncated(field: "UInt16", bitOffset: Swift.max(0, offset) * 8)
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw DTSError.truncated(field: "UInt32", bitOffset: Swift.max(0, offset) * 8)
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func bigEndianUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw DTSError.truncated(field: "UInt32", bitOffset: Swift.max(0, offset) * 8)
        }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func bigEndianUInt64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= count else {
            throw DTSError.truncated(field: "UInt64", bitOffset: Swift.max(0, offset) * 8)
        }
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(self[offset + index]) }
        return value
    }

    func fourCC(at offset: Int) throws -> String {
        guard offset >= 0, offset + 4 <= count else {
            throw DTSError.truncated(field: "FourCC", bitOffset: Swift.max(0, offset) * 8)
        }
        return String(decoding: self[offset..<(offset + 4)], as: UTF8.self)
    }
}
