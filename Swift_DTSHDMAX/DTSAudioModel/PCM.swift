import Foundation

public enum DTSChannelLayout: String, Sendable, Codable, CaseIterable {
    case stereo
    case fiveOneSide = "5.1(side)"
    case sevenOne = "7.1"

    public var channelCount: Int {
        switch self {
        case .stereo: 2
        case .fiveOneSide: 6
        case .sevenOne: 8
        }
    }

    /// WAVEFORMATEXTENSIBLE order: L, R [, C, LFE, Ls, Rs].
    var waveSpeakerMask: UInt32 {
        switch self {
        case .stereo: 0x0000_0003
        case .fiveOneSide: 0x0000_060f
        case .sevenOne: 0x0000_063f
        }
    }

    /// Extension-substream static metadata uses the paired speaker mask.
    var exssSpeakerPairMask: UInt16 {
        switch self {
        case .stereo: 0x0002
        case .fiveOneSide: 0x000f
        case .sevenOne: 0x084b // C, LR, LFE1, LsrRsr, LssRss
        }
    }

    /// XLL channel-set masks use one bit per DTS speaker position.
    var xllSpeakerMask: UInt16 {
        switch self {
        case .stereo: 0x06 // L, R
        case .fiveOneSide: 0x3f // C, L, R, Ls, Rs, LFE1
        case .sevenOne: 0x07a7 // C, L, R, LFE1, Lsr, Rsr, Lss, Rss
        }
    }

    /// XLL stores an exact mask width. Standard 7.1 reaches DTS bit 10.
    var xllSpeakerMaskBitCount: Int {
        switch self {
        case .stereo, .fiveOneSide: 8
        case .sevenOne: 11
        }
    }

    /// Converts WAVE canonical planes to the ascending DTS speaker-mask order.
    var waveToDTSPlaneOrder: [Int] {
        switch self {
        case .stereo:
            [0, 1]
        case .fiveOneSide:
            [2, 0, 1, 4, 5, 3] // C, L, R, Ls, Rs, LFE1
        case .sevenOne:
            [2, 0, 1, 3, 4, 5, 6, 7] // C, L, R, LFE1, Lsr, Rsr, Lss, Rss
        }
    }

    /// Converts ascending DTS speaker-mask planes to WAVE canonical order.
    var dtsToWavePlaneOrder: [Int] {
        switch self {
        case .stereo:
            [0, 1]
        case .fiveOneSide:
            [1, 2, 0, 5, 3, 4] // L, R, C, LFE1, Ls, Rs
        case .sevenOne:
            [1, 2, 0, 3, 4, 5, 6, 7] // L, R, C, LFE1, Lsr, Rsr, Lss, Rss
        }
    }

    static func fromWave(channelCount: Int, speakerMask: UInt32) throws -> DTSChannelLayout {
        switch (channelCount, speakerMask) {
        case (2, 0), (2, 0x0000_0003):
            return .stereo
        case (6, 0x0000_060f):
            return .fiveOneSide
        case (8, 0x0000_063f):
            return .sevenOne
        default:
            throw DTSError.unsupported(
                "WAVE channel layout channels=\(channelCount), mask=0x\(String(speakerMask, radix: 16))"
            )
        }
    }

    static func fromXLL(channelCount: Int, speakerMask: UInt64) throws -> DTSChannelLayout {
        switch (channelCount, speakerMask) {
        case (2, UInt64(DTSChannelLayout.stereo.xllSpeakerMask)):
            return .stereo
        case (6, UInt64(DTSChannelLayout.fiveOneSide.xllSpeakerMask)):
            return .fiveOneSide
        case (8, UInt64(DTSChannelLayout.sevenOne.xllSpeakerMask)):
            return .sevenOne
        default:
            throw DTSError.unsupported(
                "XLL channel layout channels=\(channelCount), mask=0x\(String(speakerMask, radix: 16))"
            )
        }
    }
}

public struct PCMFormat: Sendable, Equatable, Codable {
    public let sampleRate: Int
    public let bitDepth: Int
    public let layout: DTSChannelLayout

    public init(sampleRate: Int, bitDepth: Int, layout: DTSChannelLayout) throws {
        guard sampleRate == 48_000 else {
            throw DTSError.unsupported("sample rate \(sampleRate) Hz; lossless-only profile requires 48000 Hz")
        }
        guard bitDepth == 24 else {
            throw DTSError.unsupported("bit depth \(bitDepth); lossless-only profile requires 24-bit integer PCM")
        }
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.layout = layout
    }
}

public struct PCMBuffer: Sendable, Equatable {
    public let format: PCMFormat
    public private(set) var planes: [[Int32]]

    public init(format: PCMFormat, planes: [[Int32]]) throws {
        guard planes.count == format.layout.channelCount else {
            throw DTSError.malformed("expected \(format.layout.channelCount) PCM planes, found \(planes.count)")
        }
        let sampleCount = planes.first?.count ?? 0
        guard planes.allSatisfy({ $0.count == sampleCount }) else {
            throw DTSError.malformed("PCM plane lengths differ")
        }
        for (channel, plane) in planes.enumerated() {
            if let invalid = plane.first(where: { $0 < -8_388_608 || $0 > 8_388_607 }) {
                throw DTSError.valueOutOfRange(field: "pcm.channel[\(channel)]", value: String(invalid))
            }
        }
        self.format = format
        self.planes = planes
    }

    public var sampleCount: Int { planes.first?.count ?? 0 }

    func frame(at offset: Int, count: Int) throws -> PCMBuffer {
        guard offset >= 0, count >= 0, offset + count <= sampleCount else {
            throw DTSError.valueOutOfRange(field: "PCM frame range", value: "\(offset)..<\(offset + count)")
        }
        return try PCMBuffer(
            format: format,
            planes: planes.map { Array($0[offset..<(offset + count)]) }
        )
    }

    func reorderedPlanes(_ order: [Int]) throws -> [[Int32]] {
        guard order.count == planes.count, Set(order) == Set(planes.indices) else {
            throw DTSError.malformed("invalid PCM plane reorder map")
        }
        return order.map { planes[$0] }
    }
}
