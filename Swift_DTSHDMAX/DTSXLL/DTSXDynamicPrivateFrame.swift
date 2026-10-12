import Foundation

/// Experimental profiles keep fixed height identity separate from moving
/// aggregates. TFC occupies record zero only in the reserved IMAX profile.
public enum DTSXDynamicLayout: String, CaseIterable, Codable, Sendable {
    case sevenOneFour = "7.1.4"
    case sevenOneFive = "7.1.5"

    public var dynamicObjectCount: Int { 4 }
    public var reservedIMAXObjectCount: Int { self == .sevenOneFive ? 1 : 0 }
    public var fixedPlaneCount: Int { self == .sevenOneFour ? 12 : 13 }
    var recordCount: Int { dynamicObjectCount + reservedIMAXObjectCount }
}

/// Quantized spherical coordinates in the type-241 transport grid.
public struct DTSXObjectPosition: Sendable, Equatable, Codable {
    public let azimuthCode: Int
    public let elevationCode: Int
    public let distanceCode: Int

    private enum CodingKeys: String,CodingKey { case azimuthCode,elevationCode,distanceCode }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(azimuthCode: c.decode(Int.self,forKey: .azimuthCode),
                      elevationCode: c.decode(Int.self,forKey: .elevationCode),
                      distanceCode: c.decode(Int.self,forKey: .distanceCode))
    }

    public init(azimuthCode: Int, elevationCode: Int, distanceCode: Int = 63) throws {
        guard (0...239).contains(azimuthCode), (0...120).contains(elevationCode),
              (0...63).contains(distanceCode) else {
            throw DTSError.invalidArgument("Object position is outside the spherical transport grid")
        }
        self.azimuthCode = azimuthCode
        self.elevationCode = elevationCode
        self.distanceCode = distanceCode
    }

    public init(room: AtmosPosition, layout: DTSXDynamicLayout = .sevenOneFour) throws {
        guard room.x.isFinite, room.y.isFinite, room.z.isFinite else {
            throw DTSError.invalidArgument("Object coordinates must be finite")
        }
        let point = AtmosPosition(x: min(1,max(-1,room.x)),y: min(1,max(-1,room.y)),z: min(1,max(0,room.z)))
        let radius = max(abs(point.x),abs(point.y),point.z)
        let direction = DTSXDynamicSpatialModel.direction(image: DTSXDynamicSpatialModel.image(room: point,layout: layout),radius: 1)
        try self.init(direction: direction,distance: radius)
    }

    init(direction: AtmosPosition, distance: Double? = nil) throws {
        let radius = min(1,max(0,distance ?? sqrt(direction.x*direction.x+direction.y*direction.y+direction.z*direction.z)))
        let a = atan2(direction.x,direction.y)*180 / .pi
        let e = atan2(direction.z,hypot(direction.x,direction.y))*180 / .pi
        func circularError(_ first: Double,_ second: Double) -> Double {
            abs((first-second+540).truncatingRemainder(dividingBy: 360)-180)
        }
        let approximate = Int(((a+180)/1.5).rounded())
        let candidates = Set((-2...2).map { ((approximate+$0)%240+240)%240 } + [47,193]).sorted()
        let azimuthCode = candidates.min {
            let first = $0 == 47 ? -110.0 : ($0 == 193 ? 110.0 : Double($0)*1.5-180)
            let second = $1 == 47 ? -110.0 : ($1 == 193 ? 110.0 : Double($1)*1.5-180)
            return circularError(a,first) < circularError(a,second)
        }!
        let elevationCode = min(120,max(60,Int((e/1.5+60).rounded())))
        let units = Int((radius*64).rounded())
        let distanceCode = radius <= 1.0/64 ? 0 : min(63,max(1,units-1))
        try self.init(azimuthCode: azimuthCode,elevationCode: elevationCode,distanceCode: distanceCode)
    }

    public static let reservedTFC = try! DTSXObjectPosition(azimuthCode: 120, elevationCode: 77)
    var azimuth: Double { azimuthCode == 47 ? -110 : (azimuthCode == 193 ? 110 : Double(azimuthCode) * 1.5 - 180) }
    var elevation: Double { Double(elevationCode - 60) * 1.5 }
    var distance: Double { distanceCode == 0 ? 0 : Double(distanceCode+1)/64 }

    /// Candidate compatibility image used by the programme carrier planner.
    /// Moving positions must not directly change the transmitted fold rows.
    func foldCodes(for layout: DTSXDynamicLayout) -> [Int] {
        let field = DTS714VBAPPanner.transportGains(azimuth: azimuth,elevation: elevation,distance: distance)
        var gains = Array(field.prefix(8))
        let destinations = layout == .sevenOneFive ? [0,1,4,5] : [0,1,6,7]
        let height = Double(DTSXDynamicMetadata.gainQ15(layout == .sevenOneFive ? 61 : 55))/32768
        for index in 0..<4 { gains[destinations[index]] += field[index+8]*height }
        let maximum = max(1,gains.max() ?? 1)
        return gains.map { value in
            let target = value/maximum
            return (0...61).min {
                abs(Double(DTSXDynamicMetadata.gainQ15($0))/32768-target)
                    < abs(Double(DTSXDynamicMetadata.gainQ15($1))/32768-target)
            }!
        }
    }
}

struct DTSXDynamicMetadata: Sendable {
    let positions: [DTSXObjectPosition]
    /// Canonical L/R/C/LFE/Lss/Rss/Lsr/Rsr order.
    let foldCodes: [[Int]]
    let heightFoldCode: Int?
    let reservedTFC: Bool
    let byteCount: Int
    let chunkByteCounts: [Int]

    static let referenceOrder = [2, 0, 1, 3, 6, 7, 4, 5]
    static func gainQ15(_ code: Int) -> Int64 {
        code == 0 ? 0 : Int64(XLLSyntax.downmixCoefficientsQ15[4 * code - 3])
    }

    static func encode(layout: DTSXDynamicLayout, positions moving: [DTSXObjectPosition],
                       dynamicFoldCodes: [[Int]]) throws -> Data {
        guard moving.count == layout.dynamicObjectCount,
              dynamicFoldCodes.count == layout.dynamicObjectCount,
              dynamicFoldCodes.allSatisfy({ $0.count == 8 && $0.allSatisfy({ (0...61).contains($0) }) }) else {
            throw DTSError.invalidArgument("Dynamic position/fold dimensions or gain codes are invalid")
        }
        let positions = (layout.reservedIMAXObjectCount == 1 ? [.reservedTFC] : []) + moving
        let folds = (layout.reservedIMAXObjectCount == 1 ? [[46,46,58,0,0,0,0,0]] : []) + dynamicFoldCodes
        var w = BitWriter()
        func put(_ value: Int, _ bits: Int) throws { try w.write(UInt64(value), bitCount: bits, field: "Object metadata") }
        try put(0xf1, 8); try put(0x40, 8); try put(0, 5); try put(1, 4)
        try put(1, 1); try put(0, 1); try put(1, 1); try put(positions.count - 1, 4)
        try put(0b001100000, 9); try put(2, 3); try put(0x084b, 12); try put(0, 8)
        for index in positions.indices {
            try put(1, 1); try put(3, 2); try put(index, 3); try put(1, 2); try put(0, 10)
        }
        for index in positions.indices {
            try put(0, 3); try put(0x20, 7); try put(1, 1); try put(1, 1); try put(0, 2); try put(61, 6)
            try put(positions[index].distanceCode, 6); try put(positions[index].azimuthCode, 8)
            try put(positions[index].elevationCode, 7); try put(0, 1)
            try put(1, 1); try put(0, 1)
            let row = referenceOrder.map { folds[index][$0] }
            try put(row.enumerated().reduce(0) { $0 | ($1.element > 0 ? 1 << $1.offset : 0) }, 8)
            for code in row where code > 0 { try put(code, 6) }
        }
        try put(layout.reservedIMAXObjectCount, 1)
        if layout.reservedIMAXObjectCount == 1 {
            for index in positions.indices {
                try put(index == 0 ? 1 : 0, 1)
                if index == 0 {
                    try put(0, 2); try put(8, 5); try put(0x80, 8)
                    try put(1, 1); try put(1, 1); try put(61, 6)
                }
            }
        }
        w.alignToByte()
        do {
            // Type 3 lists fixed height identities and their compatible folds.
            try put(3, 8); try put(0, 8); try put(0, 1); try put(1, 4); try put(1, 4)
            try put(0, 1); try put(0, 1); try put(0, 4)
            try put(1, 1); try put(61, 6); try put(0, 1); try put(3, 3); try put(0x886b, 16)
            try put(2, 5); try put(0, 6); try put(1, 1); try put(0, 1); try put(0x3fa, 12)
            let bedColumns = layout == .sevenOneFive ? [1,2,8,9] : [1,2,6,7]
            for (index, heightColumn) in [4,5,10,11].enumerated() {
                let bed = bedColumns[index]
                try put((1 << bed) | (1 << heightColumn), 12)
                // Bed columns precede height columns in each row.
                try put(layout == .sevenOneFive ? 61 : 55, 6); try put(61, 6)
            }
            w.alignToByte()
        }
        try DTSCRC16.appendChecksum(to: &w, protectedByteOffset: 0, component: "Object presentation")
        return w.data()
    }

    static func parse(_ bytes: Data) throws -> DTSXDynamicMetadata {
        var r = try BitReader(data: bytes)
        func get(_ bits: Int) throws -> Int { Int(try r.read(bits, field: "Object metadata")) }
        func expect(_ bits: Int, _ value: Int) throws {
            guard try get(bits) == value else { throw DTSError.malformed("Unsupported object metadata field at bit \(r.bitOffset)") }
        }
        try expect(8, 0xf1); try expect(8, 0x40); try expect(5, 0); try expect(4, 1)
        try expect(1, 1); try expect(1, 0); try expect(1, 1)
        let count = try get(4) + 1
        guard [4,5].contains(count) else { throw DTSError.unsupported("Object declaration count") }
        try expect(9, 0b001100000); try expect(3, 2); try expect(12, 0x084b); try expect(8, 0)
        for index in 0..<count {
            try expect(1, 1); try expect(2, 3); try expect(3, index); try expect(2, 1); try expect(10, 0)
        }
        var positions: [DTSXObjectPosition] = [], folds: [[Int]] = []
        for _ in 0..<count {
            try expect(3, 0); try expect(7, 0x20); try expect(1, 1); try expect(1, 1); try expect(2, 0); try expect(6, 61)
            let distance = try get(6), azimuth = try get(8), elevation = try get(7)
            positions.append(try DTSXObjectPosition(azimuthCode: azimuth, elevationCode: elevation, distanceCode: distance))
            try expect(1, 0); try expect(1, 1); try expect(1, 0)
            let mask = try get(8)
            var fold = Array(repeating: 0, count: 8)
            for column in 0..<8 where mask & (1 << column) != 0 {
                let code = try get(6)
                guard (1...61).contains(code) else { throw DTSError.malformed("Object fold gain escape") }
                fold[referenceOrder[column]] = code
            }
            folds.append(fold)
        }
        let reserved = try get(1) == 1
        if reserved {
            for index in 0..<count {
                try expect(1, index == 0 ? 1 : 0)
                if index == 0 {
                    try expect(2, 0); try expect(5, 8); try expect(8, 0x80)
                    try expect(1, 1); try expect(1, 1); try expect(6, 61)
                }
            }
            guard count == 5, positions[0] == .reservedTFC, folds[0] == [46,46,58,0,0,0,0,0] else {
                throw DTSError.malformed("Reserved IMAX object was changed or mixed with dynamic slots")
            }
        }
        func align() throws { let padding = (8 - r.bitOffset % 8) % 8; try expect(padding, 0) }
        try align()
        let objectBytes = r.bitOffset / 8
        var heightCode: Int?
        do {
            try expect(8, 3); try expect(8, 0); try expect(1, 0); try expect(4, 1); try expect(4, 1)
            try expect(1, 0); try expect(1, 0); try expect(4, 0)
            try expect(1, 1); try expect(6, 61); try expect(1, 0); try expect(3, 3); try expect(16, 0x886b)
            try expect(5, 2); try expect(6, 0); try expect(1, 1); try expect(1, 0); try expect(12, 0x3fa)
            heightCode = reserved ? 61 : 55
            let bedColumns = reserved ? [1,2,8,9] : [1,2,6,7]
            for (index, height) in [4,5,10,11].enumerated() {
                try expect(12, (1 << bedColumns[index]) | (1 << height))
                try expect(6, heightCode!); try expect(6, 61)
            }
            try align()
        }
        let end = r.bitOffset / 8 + 2
        guard end <= bytes.count, DTSCRC16.checksum(bytes.prefix(end)) == 0,
              (count == 4 && heightCode != nil && !reserved) || (count == 5 && heightCode != nil && reserved) else {
            throw DTSError.malformed("Object presentation CRC or fixed/dynamic role count is invalid")
        }
        let chunks = [objectBytes, end - objectBytes - 2]
        return DTSXDynamicMetadata(positions: positions, foldCodes: folds, heightFoldCode: heightCode,
                                   reservedTFC: reserved, byteCount: end, chunkByteCounts: chunks)
    }
}

/// Explicit metadata followed by one object group and an optional fixed
/// height quartet. Every group's NAVI shares the enclosing public width.
struct DTSXDynamicPrivateFrame: Sendable {
    let data: Data
    let metadata: DTSXDynamicMetadata
    let groups: [DTSIMAXPrivateFrame.Group]
    var navigationWidth: Int { groups.map(\.navigationWidth).max() ?? 0 }
    static func isDynamic(_ bytes: Data) -> Bool {
        bytes.count >= 4 && bytes[0] == 0xf1 && bytes[1] == 0x40 && bytes[2] == 0 && [0xd3,0xd4].contains(bytes[3])
    }

    static func encode(layout: DTSXDynamicLayout, positions: [DTSXObjectPosition], dynamicFoldCodes: [[Int]], planes: [[Int32]],
                       plan: XLLSegmentationPlan, mode: DTSEncodeMode) throws -> DTSXDynamicPrivateFrame {
        guard let publicWidth = plan.segmentSizeBitCount,
              planes.count == layout.recordCount + 4 else {
            throw DTSError.invalidArgument("Object frame plane count or public NAVI width is invalid")
        }
        let codec = XLLEncoder(codingMode: mode == .auto ? .terminalOfficialPredictive : .terminalOfficialRice,
                               maximumPredictionOrder: 10)
        var sets = [try codec.encodeObjectChannelSet(planes: Array(planes.prefix(layout.recordCount)), segmentCount: plan.segmentCount)]
        sets.append(try codec.encodeObjectChannelSet(planes: Array(planes.suffix(4)), segmentCount: plan.segmentCount))
        let width = max(8, publicWidth, sets.map(\.requiredNavigationWidth).max() ?? 0)
        var data = try DTSXDynamicMetadata.encode(layout: layout, positions: positions, dynamicFoldCodes: dynamicFoldCodes)
        for (index, set) in sets.enumerated() {
            data.append(index == 0 ? 3 : 2)
            data.append(contentsOf: [0x34,0x38,0x8c,0x4f])
            let framed = try DTSIMAXPrivateFrame.commonFrame(body: set.serialize(navigationWidth: width),
                                                             segmentCount: plan.segmentCount, navigationWidth: width)
            data.append(framed.dropFirst(4))
        }
        while !data.count.isMultiple(of: 4) { data.append(0) }
        let result = try parse(data)
        try result.validate(plan: plan, allowWiderWidth: true)
        guard try result.decode() == planes else { throw DTSError.malformed("Object audio failed native PCM reconstruction") }
        return result
    }

    static func parse(_ data: Data) throws -> DTSXDynamicPrivateFrame {
        guard isDynamic(data), data.count.isMultiple(of: 4) else { throw DTSError.malformed("Unaligned object frame") }
        let metadata = try DTSXDynamicMetadata.parse(data)
        var cursor = metadata.byteCount, groups: [DTSIMAXPrivateFrame.Group] = []
        let counts = [metadata.positions.count, 4]
        for (index, count) in counts.enumerated() {
            guard cursor + 13 <= data.count, data[cursor] == (index == 0 ? 3 : 2),
                  data.subdata(in: cursor+1..<cursor+5) == Data([0x34,0x38,0x8c,0x4f]) else {
                throw DTSError.malformed("Object group association is invalid")
            }
            cursor += 5
            var r = try BitReader(data: data, byteOffset: cursor, byteCount: data.count - cursor)
            guard try r.read(4, field: "Object common version") == 0 else { throw DTSError.unsupported("Object common version") }
            let header = Int(try r.read(8, field: "Object common bytes")) + 1
            let bits = Int(try r.read(5, field: "Object size width")) + 1
            let size = Int(try r.read(bits, field: "Object bytes")) + 1
            guard try r.read(4, field: "Object sets") == 0 else { throw DTSError.malformed("Object group set count") }
            let segments = 1 << Int(try r.read(4, field: "Object segments"))
            let samples = 1 << Int(try r.read(4, field: "Object segment samples"))
            let width = Int(try r.read(5, field: "Object NAVI width")) + 1
            let headerEnd = cursor + header - 4, frameEnd = cursor + size - 4
            guard [2,4,8].contains(segments), segments * samples == 512, (8...16).contains(width),
                  header >= 12, headerEnd <= frameEnd, frameEnd <= data.count,
                  DTSCRC16.checksum(data.subdata(in: cursor..<headerEnd)) == 0 else {
                throw DTSError.malformed("Object common header dimensions or CRC are invalid")
            }
            var b = try BitReader(data: data, byteOffset: headerEnd, byteCount: frameEnd - headerEnd)
            let bareSize = Int(try b.read(10, field: "Object bare size")) + 1
            guard try b.read(4, field: "Object channels") + 1 == count, bareSize <= frameEnd - headerEnd else {
                throw DTSError.malformed("Object audio group channel count")
            }
            groups.append(.init(bytes: data.subdata(in: headerEnd..<frameEnd), channelCount: count,
                                segmentCount: segments, navigationWidth: width, chunkByteCount: size + 1))
            cursor = frameEnd
        }
        guard data.count - cursor < 4, data[cursor...].allSatisfy({ $0 == 0 }) else { throw DTSError.malformed("Object frame tail") }
        return DTSXDynamicPrivateFrame(data: data, metadata: metadata, groups: groups)
    }

    func validate(plan: XLLSegmentationPlan, allowWiderWidth: Bool = false) throws {
        let width = max(8, plan.segmentSizeBitCount ?? 0)
        guard groups.allSatisfy({ $0.segmentCount == plan.segmentCount && $0.navigationWidth == navigationWidth &&
            (allowWiderWidth ? $0.navigationWidth >= width : $0.navigationWidth == width) }) else {
            throw DTSError.malformed("Object groups disagree with public NAVI")
        }
    }
    func decode() throws -> [[Int32]] {
        try groups.flatMap { try XLLDecoder().decodeIMAXChannelSet(data: $0.bytes, segmentCount: $0.segmentCount,
                                                                 segmentSizeBitCount: $0.navigationWidth) }
    }
}
