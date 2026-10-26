import Foundation

/// One fixed-speaker metadata chunk and one native, fully coded XLL audio
/// group. Its predictor/NAVI/entropy bytes are serialized from the input PCM.
struct DTSXFixedPrivateFrame: Sendable {
    let data: Data
    let format: DTSXChannelFormat
    let group: Data
    let groupByteCount: Int
    let navigationWidth: Int

    static func format(of data: Data) -> DTSXChannelFormat? {
        DTSXChannelFormat.allCases.first { $0 != .sevenOneFour && data.starts(with: $0.metadata) }
    }

    static func encode(format: DTSXChannelFormat, planes: [[Int32]], plan: XLLSegmentationPlan,
                       mode: DTSEncodeMode) throws -> DTSXFixedPrivateFrame {
        guard format != .sevenOneFour, planes.count == format.heightChannelNames.count,
              let publicWidth = plan.segmentSizeBitCount else {
            throw DTSError.invalidArgument("Fixed speaker audio group dimensions or public NAVI are invalid")
        }
        let codec = XLLEncoder(codingMode: mode.privateGroupCodingMode,maximumPredictionOrder: 10)
        let set = try codec.encodeObjectChannelSet(planes: format.privateChannelOrder.map { planes[$0] },segmentCount: plan.segmentCount,fixedSpeakerMapping: true,minimumNavigationWidth: max(8,publicWidth))
        let width = max(8,publicWidth,set.requiredNavigationWidth)
        let group = try set.serialize(navigationWidth: width)
        var data = format.metadata
        data.append(format.groupAssociation)
        data.append(group)
        while !data.count.isMultiple(of: 4) { data.append(0) }
        let result = try parse(data,groupByteCount: group.count,navigationWidth: width)
        guard try result.decode(segmentCount: plan.segmentCount) == planes else {
            throw DTSError.malformed("Fixed speaker audio group failed native PCM reconstruction")
        }
        return result
    }

    static func parse(_ data: Data, segmentCount: Int, publicNavigationWidth: Int) throws -> DTSXFixedPrivateFrame {
        guard let format = format(of: data), [2,4,8].contains(segmentCount) else {
            throw DTSError.malformed("Unknown fixed speaker frame or partition")
        }
        let width = max(8, publicNavigationWidth)
        guard width <= 16 else { throw DTSError.malformed("Fixed speaker NAVI width is invalid") }
        let start = format.metadata.count+1
        var r = try BitReader(data: data,byteOffset: start)
        let header = Int(try r.read(10,field: "Fixed group header bytes"))+1
        let naviStart = start+header
        let naviBytes = (width*segmentCount+7)/8+2
        guard naviStart+naviBytes <= data.count else { throw DTSError.malformed("Fixed speaker NAVI exceeds its frame") }
        guard DTSCRC16.checksum(data.subdata(in: naviStart..<naviStart+naviBytes)) == 0 else {
            throw DTSError.checksumMismatch(component: "Fixed speaker NAVI")
        }
        r = try BitReader(data: data,byteOffset: naviStart,byteCount: naviBytes)
        var entropyBytes = 0
        for _ in 0..<segmentCount { entropyBytes += Int(try r.read(width,field: "Fixed speaker segment bytes"))+1 }
        let result = try parse(data,groupByteCount: header+naviBytes+entropyBytes,navigationWidth: width)
        _ = try result.decode(segmentCount: segmentCount)
        return result
    }

    static func parse(_ data: Data, groupByteCount: Int, navigationWidth: Int) throws -> DTSXFixedPrivateFrame {
        guard let format = format(of: data), data.count.isMultiple(of: 4),
              (8...16).contains(navigationWidth), groupByteCount > 2 else {
            throw DTSError.malformed("Fixed speaker frame identity, width or alignment is invalid")
        }
        let start = format.metadata.count + 1, end = start + groupByteCount
        guard start < data.count, end <= data.count, data[start-1] == format.groupAssociation,
              data.count-end < 8, data[end...].allSatisfy({ $0 == 0 }),
              DTSCRC16.checksum(data.prefix(start-1)) == 0 else {
            throw DTSError.malformed("Fixed speaker metadata/audio sizes do not close")
        }
        let group = data.subdata(in: start..<end)
        var reader = try BitReader(data: group)
        let headerBytes = Int(try reader.read(10,field: "Fixed group header bytes"))+1
        let channels = Int(try reader.read(4,field: "Fixed group channels"))+1
        guard channels == format.heightChannelNames.count, headerBytes <= group.count,
              DTSCRC16.checksum(group.prefix(headerBytes)) == 0 else {
            throw DTSError.malformed("Fixed speaker group header dimensions or CRC are invalid")
        }
        return Self(data: data,format: format,group: group,groupByteCount: groupByteCount,navigationWidth: navigationWidth)
    }

    func decode(segmentCount: Int) throws -> [[Int32]] {
        let coded = try XLLDecoder().decodeIMAXChannelSet(data: group,segmentCount: segmentCount,segmentSizeBitCount: navigationWidth,fixedSpeakerMapping: true)
        var semantic = Array(repeating: [Int32](),count: coded.count)
        for (index,destination) in format.privateChannelOrder.enumerated() { semantic[destination] = coded[index] }
        return semantic
    }
}

extension DTSEncodeMode {
    var privateGroupCodingMode: XLLCodingMode { self == .auto ? .terminalOfficialPredictive : .terminalOfficialRice }
}
