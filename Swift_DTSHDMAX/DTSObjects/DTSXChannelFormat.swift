import Foundation

/// Vision-1 fixed speaker presentations. IMAX remains a separate vision/profile.
public enum DTSXChannelFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case sevenOneFour = "7.1.4"
    case sevenOneThree = "7.1.3"
    case sevenOneTwoFront = "7.1.2F"
    case sevenOneTwoSide = "7.1.2S"
    case fiveOneFive = "5.1.5"
    case fiveOneFour = "5.1.4"
    case fiveOneThree = "5.1.3"

    public init(argument: String) throws {
        guard let value = Self.allCases.first(where: { $0.rawValue.lowercased() == argument.lowercased() }) else {
            throw DTSError.invalidArgument("Channel format must be 7.1.4, 7.1.3, 7.1.2F, 7.1.2S, 5.1.5, 5.1.4 or 5.1.3")
        }
        self = value
    }
    public var bedChannelCount: Int {
        switch self { case .sevenOneFour,.sevenOneThree,.sevenOneTwoFront,.sevenOneTwoSide: 8; default: 6 }
    }
    public var channelNames: [String] {
        let bed = bedChannelCount == 8 ? ["L","R","C","LFE","Lss","Rss","Lsr","Rsr"] : ["L","R","C","LFE","Ls","Rs"]
        return bed + heightChannelNames
    }
    public var heightChannelNames: [String] {
        switch self {
        case .sevenOneFour, .fiveOneFour: ["Lfh","Rfh","Lrh","Rrh"]
        case .sevenOneThree, .fiveOneThree: ["Lfh","Rfh","Crh"]
        case .sevenOneTwoFront: ["Lfh","Rfh"]
        case .sevenOneTwoSide: ["Lhs","Rhs"]
        case .fiveOneFive: ["Lfh","Rfh","Cfh","Lrh","Rrh"]
        }
    }
    /// Fixed metadata indexes the 5.1.5 front-height trio as left/centre/right.
    /// The public input API retains the Encoder Suite's Lfh/Rfh/Cfh order.
    var privateChannelOrder: [Int] {
        self == .fiveOneFive ? [0,2,1,3,4] : Array(heightChannelNames.indices)
    }
    var bedLayout: DTSChannelLayout { bedChannelCount == 8 ? .sevenOne : .fiveOneSide }
    var groupAssociation: UInt8 { bedChannelCount == 8 ? 2 : 1 }

    /// Constant speaker/matrix declarations, with the CRC generated below.
    /// These contain no compressed audio, predictor state or oracle payload.
    private static let metadataTable = Dictionary(uniqueKeysWithValues: allCases.map { ($0,$0.makeMetadata()) })
    var metadata: Data { Self.metadataTable[self]! }
    private func makeMetadata() -> Data {
        let values: [UInt8]
        switch self {
        case .sevenOneFour: values = [0x02,0,0x08,0x50,0x28,0x4b,0xfa,0x71,0x0d,0x62,0x02,0xfa,0x02,0xdc,0x13,0x71,0x0d,0xc8,0x37]
        case .sevenOneThree: values = [0x02,0,0x08,0x50,0x28,0x4b,0xfa,0x69,0x0d,0x62,0x02,0xfa,0x02,0xdc,0x13,0x73,0x0c,0x71]
        case .sevenOneTwoFront: values = [0x02,0,0x08,0x50,0x28,0x4b,0xfa,0x50,0xd6,0x20,0x2f,0xa0,0x2d,0xc1,0x37]
        case .sevenOneTwoSide: values = [0x02,0,0x08,0x50,0x28,0x4b,0xfa,0x65,0x09,0x62,0x02,0xfa,0x40,0xde,0x03,0x70]
        case .fiveOneFive: values = [0x02,0,0x08,0x50,0x0f,0xfa,0x70,0x15,0xe1,0x02,0xfa,0x0b,0x71,0x37,0x07,0x72,0x37,0x43,0x70]
        case .fiveOneFour: values = [0x02,0,0x08,0x50,0x0f,0xfa,0x70,0x05,0xe1,0x02,0xfa,0x0b,0x71,0x37,0x23,0x74,0x37]
        case .fiveOneThree: values = [0x02,0,0x08,0x50,0x0f,0xfa,0x68,0x05,0xe1,0x02,0xfa,0x0b,0x71,0x37,0x63,0x1c,0x40]
        }
        let crc = DTSCRC16.checksum(values)
        return Data(values + [UInt8(crc >> 8), UInt8(crc & 255)])
    }

    /// Q15 fixed-height folds in canonical bed order. Silent matrix columns
    /// remain silent; Crh is a centre rear feed and folds into both surrounds.
    private static let heightFoldTable = Dictionary(uniqueKeysWithValues: allCases.map { ($0,$0.makeHeightFolds()) })
    var heightFolds: [[(channel: Int,gain: Int64)]] { Self.heightFoldTable[self]! }
    private func makeHeightFolds() -> [[(channel: Int,gain: Int64)]] {
        heightChannelNames.map { name in
            switch name {
            case "Lfh": [(0,23_170)]
            case "Rfh": [(1,23_170)]
            case "Cfh": [(2,23_170)]
            case "Lhs": [(4,23_170)]
            case "Rhs": [(5,23_170)]
            case "Lrh": [(bedChannelCount == 8 ? 6 : 4,23_170)]
            case "Rrh": [(bedChannelCount == 8 ? 7 : 5,23_170)]
            case "Crh": [(bedChannelCount == 8 ? 6 : 4,16_423),(bedChannelCount == 8 ? 7 : 5,16_423)]
            default: preconditionFailure("Unmapped height identity")
            }
        }
    }

    func compatibilityValues(_ planes: [[Int32]], at sample: Int) -> [Int64] {
        var bed = (0..<bedChannelCount).map { Int64(planes[$0][sample]) }
        for (height, routes) in heightFolds.enumerated() {
            let value = Int64(planes[bedChannelCount+height][sample])
            for route in routes { bed[route.channel] += (value * route.gain + 16_384) >> 15 }
        }
        return bed
    }
}

/// Integer speaker feeds in the explicit channel order of the selected format.
public struct DTSXChannelPCMBuffer: Sendable {
    public let channelFormat: DTSXChannelFormat
    public let planes: [[Int32]]
    public var sampleCount: Int { planes.first?.count ?? 0 }
    public init(channelFormat: DTSXChannelFormat, planes: [[Int32]]) throws {
        guard planes.count == channelFormat.channelNames.count,
              let count = planes.first?.count, count > 0,
              planes.allSatisfy({ $0.count == count }) else {
            throw DTSError.invalidArgument("PCM dimensions do not match \(channelFormat.rawValue)")
        }
        self.channelFormat = channelFormat
        self.planes = planes
    }
    func compatibilityBed() throws -> PCMBuffer {
        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: channelFormat.bedLayout)
        var bed = Array(repeating: [Int32](repeating: 0,count: sampleCount),count: channelFormat.bedChannelCount)
        for sample in 0..<sampleCount {
            let values = channelFormat.compatibilityValues(planes,at: sample)
            for channel in bed.indices {
                guard (-8_388_608...8_388_607).contains(values[channel]) else {
                    throw DTSError.malformed("Fixed speaker compatibility fold exceeds signed 24-bit PCM")
                }
                bed[channel][sample] = Int32(values[channel])
            }
        }
        // PCMBuffer uses WAVE order: rear surround precedes side surround.
        return try PCMBuffer(format: format, planes: channelFormat.bedChannelCount == 8 ? [0,1,2,3,6,7,4,5].map { bed[$0] } : bed)
    }
}
