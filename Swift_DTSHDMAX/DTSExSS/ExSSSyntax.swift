import Foundation

enum ExSSSyntax {
    static let syncWord: UInt64 = 0x6458_2025
    static let shortHeaderSizeBitCount = 8
    static let shortFrameSizeBitCount = 16
}

/// DTS:X-specific decoder-navigation signal carried in the reserved tail of
/// an ExSS audio-asset descriptor.
///
/// The supplied DTS:X oracle and all five controlled `test_X` streams use the
/// same 67-bit extension after the two public decoder-navigation flags:
///
/// ```text
/// profile(5) | XLL-X byte offset(16) | signature(24)
///            | 2 * (XLL-X bytes - 24)(16) | zero pad(6)
/// ```
///
/// This relationship was verified over every access unit in the supplied
/// reference set.  Keeping it typed prevents a private XLL-X frame from being
/// emitted behind an ordinary 16-byte HDMA descriptor, which official tooling
/// classifies as plain DTS-HD Master Audio.
struct ExSSDTSXAssetDescriptorSignal: Sendable, Equatable, Codable {
    static let profileCode = 3
    static let signature: UInt64 = 0x001145
    static let fixedPrivatePrefixByteCount = 24
    static let encodedBitCount = 5 + 16 + 24 + 16 + 6
    static let imaxEncodedBitCount = 5 + 16 + 40 + 15 + 15 + 4
    static let imaxSignature: UInt64 = 0x1112_1544_44

    let xllXByteOffset: Int
    let xllXPayloadNibbleCount: Int
    let imaxGroupByteCounts: [Int]?
    var isIMAX: Bool { imaxGroupByteCounts != nil }

    var xllXFrameByteCount: Int {
        if let counts = imaxGroupByteCounts { return (45 + counts.reduce(0, +) + 3) & ~3 }
        return Self.fixedPrivatePrefixByteCount + xllXPayloadNibbleCount / 2
    }

    init(xllXByteOffset: Int, xllXFrameByteCount: Int) throws {
        guard (0...0xffff).contains(xllXByteOffset) else {
            throw DTSError.valueOutOfRange(
                field: "DTS:X XLL-X byte offset",
                value: String(xllXByteOffset)
            )
        }
        guard xllXFrameByteCount >= Self.fixedPrivatePrefixByteCount else {
            throw DTSError.valueOutOfRange(
                field: "DTS:X XLL-X frame size",
                value: String(xllXFrameByteCount)
            )
        }
        let nibbleCount = (xllXFrameByteCount - Self.fixedPrivatePrefixByteCount) * 2
        guard (0...0xffff).contains(nibbleCount) else {
            throw DTSError.valueOutOfRange(
                field: "DTS:X XLL-X payload nibble count",
                value: String(nibbleCount)
            )
        }
        self.xllXByteOffset = xllXByteOffset
        self.xllXPayloadNibbleCount = nibbleCount
        imaxGroupByteCounts = nil
    }

    init(xllXByteOffset: Int, xllXPayloadNibbleCount: Int) throws {
        guard (0...0xffff).contains(xllXByteOffset),
              (0...0xffff).contains(xllXPayloadNibbleCount),
              xllXPayloadNibbleCount.isMultiple(of: 2) else {
            throw DTSError.valueOutOfRange(
                field: "DTS:X ExSS descriptor signal",
                value: "offset=\(xllXByteOffset), nibbles=\(xllXPayloadNibbleCount)"
            )
        }
        self.xllXByteOffset = xllXByteOffset
        self.xllXPayloadNibbleCount = xllXPayloadNibbleCount
        imaxGroupByteCounts = nil
    }

    init(imaxOffset: Int, groupByteCounts: [Int]) throws {
        guard (0...0xffff).contains(imaxOffset), groupByteCounts.count == 2,
              groupByteCounts.allSatisfy({ (1...0x8000).contains($0) }) else {
            throw DTSError.invalidArgument("IMAX descriptor navigation is out of range")
        }
        xllXByteOffset = imaxOffset
        xllXPayloadNibbleCount = 0
        imaxGroupByteCounts = groupByteCounts
    }
}

enum ExSSAssetDescriptorProfile: Sendable, Equatable {
    case standardHDMA
    case dtsxXLLX
    case dtsxIMAX
}

struct ExSSFrameInfo: Sendable, Equatable, Codable {
    let byteCount: Int
    let headerByteCount: Int
    let assetDescriptorByteCount: Int
    let assetByteCount: Int
    let xllByteCount: Int
    let xllByteOffset: Int
    let codingMode: Int
    let peakBitRateSmoothingBufferSizeCode: Int
    let xllInitialDecodingDelayBitCount: Int
    let xllInitialDecodingDelayFrames: Int
    let xllSyncByteOffset: Int
    let backwardCompatibleCorePresent: Bool
    let dtsxAssetDescriptorSignal: ExSSDTSXAssetDescriptorSignal?
    let format: PCMFormat
}

struct ExSSParsedFrame: Sendable, Equatable {
    let info: ExSSFrameInfo
    let xllData: Data
}
