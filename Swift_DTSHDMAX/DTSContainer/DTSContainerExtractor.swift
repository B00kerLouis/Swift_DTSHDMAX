import Foundation

public enum DTSContainerFormat: String, Codable, Sendable {
    case mpegTransportStream
    case matroska
}

public struct DTSExtractionReport: Codable, Equatable, Sendable {
    public let format: DTSContainerFormat
    public let byteCount: Int
    public let frameCount: Int?
    public let pesPacketCount: Int?
    public let transportPID: Int?
    public let matroskaTrackNumber: UInt64?

    public init(
        format: DTSContainerFormat,
        byteCount: Int,
        frameCount: Int? = nil,
        pesPacketCount: Int? = nil,
        transportPID: Int? = nil,
        matroskaTrackNumber: UInt64? = nil
    ) {
        self.format = format
        self.byteCount = byteCount
        self.frameCount = frameCount
        self.pesPacketCount = pesPacketCount
        self.transportPID = transportPID
        self.matroskaTrackNumber = matroskaTrackNumber
    }
}

/// Native elementary-stream extraction for Blu-ray M2TS/TS and Matroska.
///
/// The implementation intentionally performs no codec conversion. It removes
/// only the container, PES, and block/lacing syntax and preserves every DTS
/// elementary-stream byte in presentation order.
public enum DTSContainerExtractor {
    public static func extract(input: URL, output: URL) throws -> DTSExtractionReport {
        let inputData: Data
        do {
            inputData = try Data(contentsOf: input, options: .mappedIfSafe)
        } catch {
            throw DTSError.io("cannot read \(input.path): \(error.localizedDescription)")
        }

        let result: (Data, DTSExtractionReport)
        if MatroskaDTSExtractor.recognizes(inputData) {
            result = try MatroskaDTSExtractor.extract(inputData)
        } else if MPEGTransportDTSExtractor.recognizes(inputData) {
            result = try MPEGTransportDTSExtractor.extract(inputData)
        } else {
            throw DTSError.unsupported("input is not a supported M2TS/TS or Matroska container")
        }

        do {
            try result.0.write(to: output, options: .atomic)
        } catch {
            throw DTSError.io("cannot write \(output.path): \(error.localizedDescription)")
        }
        return result.1
    }
}

private enum MPEGTransportDTSExtractor {
    private struct PacketGeometry {
        let packetSize: Int
        let syncOffset: Int
    }

    static func recognizes(_ data: Data) -> Bool {
        geometry(in: data) != nil
    }

    static func extract(_ data: Data) throws -> (Data, DTSExtractionReport) {
        guard let geometry = geometry(in: data) else {
            throw DTSError.malformed("MPEG transport packet synchronization was not found")
        }
        guard let pat = try psiSection(pid: 0, data: data, geometry: geometry),
              let pmtPID = parsePAT(pat) else {
            throw DTSError.malformed("transport stream has no usable PAT")
        }
        guard let pmt = try psiSection(pid: pmtPID, data: data, geometry: geometry),
              let dtsPID = parsePMTForDTS(pmt) else {
            throw DTSError.malformed("transport stream PMT has no DTS/DTS-HD elementary stream")
        }

        var elementary = Data()
        elementary.reserveCapacity(max(1_048_576, data.count / 10))
        var currentPES = Data()
        var pesCount = 0

        func appendCurrentPES() throws {
            guard !currentPES.isEmpty else { return }
            guard currentPES.count >= 9,
                  currentPES[0] == 0,
                  currentPES[1] == 0,
                  currentPES[2] == 1 else {
                throw DTSError.malformed("DTS PID contains an invalid PES start code")
            }
            let declaredLength = (Int(currentPES[4]) << 8) | Int(currentPES[5])
            let payloadStart = 9 + Int(currentPES[8])
            guard payloadStart <= currentPES.count else {
                throw DTSError.malformed("truncated PES optional header")
            }
            let payloadEnd: Int
            if declaredLength == 0 {
                payloadEnd = currentPES.count
            } else {
                let declaredEnd = 6 + declaredLength
                guard declaredEnd <= currentPES.count else {
                    throw DTSError.malformed("truncated PES packet: expected \(declaredEnd), got \(currentPES.count) bytes")
                }
                payloadEnd = declaredEnd
            }
            guard payloadEnd >= payloadStart else {
                throw DTSError.malformed("PES length is shorter than its optional header")
            }
            elementary.append(currentPES[payloadStart..<payloadEnd])
            pesCount += 1
        }

        var packetStart = 0
        while packetStart + geometry.packetSize <= data.count {
            let tsStart = packetStart + geometry.syncOffset
            if data[tsStart] == 0x47 {
                let header1 = data[tsStart + 1]
                let pid = (Int(header1 & 0x1f) << 8) | Int(data[tsStart + 2])
                if pid == dtsPID,
                   let payload = try transportPayloadRange(data, tsStart: tsStart) {
                    let startsPES = (header1 & 0x40) != 0
                    if startsPES {
                        try appendCurrentPES()
                        currentPES.removeAll(keepingCapacity: true)
                    }
                    currentPES.append(data[payload])
                }
            }
            packetStart += geometry.packetSize
        }
        try appendCurrentPES()

        guard !elementary.isEmpty else {
            throw DTSError.malformed("DTS PID did not contain PES payload data")
        }
        return (
            elementary,
            DTSExtractionReport(
                format: .mpegTransportStream,
                byteCount: elementary.count,
                pesPacketCount: pesCount,
                transportPID: dtsPID
            )
        )
    }

    private static func geometry(in data: Data) -> PacketGeometry? {
        let candidates = [
            PacketGeometry(packetSize: 192, syncOffset: 4),
            PacketGeometry(packetSize: 188, syncOffset: 0),
            PacketGeometry(packetSize: 204, syncOffset: 0)
        ]
        for candidate in candidates {
            guard data.count >= candidate.syncOffset + 188 else { continue }
            let available = ((data.count - candidate.syncOffset - 188) / candidate.packetSize) + 1
            let checks = min(12, available)
            guard checks >= 3 else { continue }
            var matches = 0
            for index in 0..<checks where data[candidate.syncOffset + index * candidate.packetSize] == 0x47 {
                matches += 1
            }
            if matches == checks { return candidate }
        }
        return nil
    }

    private static func transportPayloadRange(_ data: Data, tsStart: Int) throws -> Range<Int>? {
        guard tsStart + 188 <= data.count, data[tsStart] == 0x47 else {
            throw DTSError.malformed("truncated MPEG transport packet")
        }
        if (data[tsStart + 1] & 0x80) != 0 {
            throw DTSError.malformed("transport error indicator is set")
        }
        let adaptationControl = (data[tsStart + 3] >> 4) & 0x03
        guard adaptationControl != 0 else {
            throw DTSError.malformed("reserved transport adaptation-field control")
        }
        guard adaptationControl == 1 || adaptationControl == 3 else { return nil }
        var payloadStart = tsStart + 4
        if adaptationControl == 3 {
            let adaptationLength = Int(data[payloadStart])
            payloadStart += 1 + adaptationLength
        }
        let packetEnd = tsStart + 188
        guard payloadStart <= packetEnd else {
            throw DTSError.malformed("transport adaptation field exceeds its packet")
        }
        return payloadStart..<packetEnd
    }

    private static func psiSection(
        pid: Int,
        data: Data,
        geometry: PacketGeometry
    ) throws -> Data? {
        var section = Data()
        var expectedLength: Int?
        var collecting = false
        var packetStart = 0
        while packetStart + geometry.packetSize <= data.count {
            let tsStart = packetStart + geometry.syncOffset
            guard data[tsStart] == 0x47 else {
                throw DTSError.malformed("transport synchronization lost at byte \(packetStart)")
            }
            let header1 = data[tsStart + 1]
            let packetPID = (Int(header1 & 0x1f) << 8) | Int(data[tsStart + 2])
            if packetPID == pid, let payloadRange = try transportPayloadRange(data, tsStart: tsStart) {
                var payloadStart = payloadRange.lowerBound
                if (header1 & 0x40) != 0 {
                    guard payloadStart < payloadRange.upperBound else {
                        throw DTSError.malformed("PSI payload-unit-start has no pointer field")
                    }
                    let pointer = Int(data[payloadStart])
                    payloadStart += 1 + pointer
                    guard payloadStart <= payloadRange.upperBound else {
                        throw DTSError.malformed("PSI pointer exceeds its packet")
                    }
                    section.removeAll(keepingCapacity: true)
                    expectedLength = nil
                    collecting = true
                }
                if collecting, payloadStart < payloadRange.upperBound {
                    section.append(data[payloadStart..<payloadRange.upperBound])
                    if expectedLength == nil, section.count >= 3 {
                        expectedLength = 3 + (((Int(section[1]) & 0x0f) << 8) | Int(section[2]))
                    }
                    if let expectedLength, section.count >= expectedLength {
                        return Data(section.prefix(expectedLength))
                    }
                }
            }
            packetStart += geometry.packetSize
        }
        return nil
    }

    private static func parsePAT(_ section: Data) -> Int? {
        guard section.count >= 12, section[0] == 0x00 else { return nil }
        let sectionLength = ((Int(section[1]) & 0x0f) << 8) | Int(section[2])
        let end = min(section.count, 3 + sectionLength) - 4
        var offset = 8
        while offset + 4 <= end {
            let program = (Int(section[offset]) << 8) | Int(section[offset + 1])
            let pid = (Int(section[offset + 2] & 0x1f) << 8) | Int(section[offset + 3])
            if program != 0 { return pid }
            offset += 4
        }
        return nil
    }

    private static func parsePMTForDTS(_ section: Data) -> Int? {
        guard section.count >= 16, section[0] == 0x02 else { return nil }
        let sectionLength = ((Int(section[1]) & 0x0f) << 8) | Int(section[2])
        let end = min(section.count, 3 + sectionLength) - 4
        let programInfoLength = (Int(section[10] & 0x0f) << 8) | Int(section[11])
        var offset = 12 + programInfoLength
        while offset + 5 <= end {
            let streamType = section[offset]
            let elementaryPID = (Int(section[offset + 1] & 0x1f) << 8) | Int(section[offset + 2])
            let infoLength = (Int(section[offset + 3] & 0x0f) << 8) | Int(section[offset + 4])
            if streamType == 0x82 || streamType == 0x85 || streamType == 0x86 {
                return elementaryPID
            }
            offset += 5 + infoLength
        }
        return nil
    }
}

private enum MatroskaDTSExtractor {
    private struct Element {
        let id: UInt64
        let payload: Range<Int>
    }

    private struct VINT {
        let value: UInt64
        let length: Int
        let unknown: Bool
    }

    private static let ebmlID: UInt64 = 0x1a45dfa3
    private static let segmentID: UInt64 = 0x18538067
    private static let tracksID: UInt64 = 0x1654ae6b
    private static let trackEntryID: UInt64 = 0xae
    private static let trackNumberID: UInt64 = 0xd7
    private static let trackTypeID: UInt64 = 0x83
    private static let codecID: UInt64 = 0x86
    private static let clusterID: UInt64 = 0x1f43b675
    private static let simpleBlockID: UInt64 = 0xa3
    private static let blockGroupID: UInt64 = 0xa0
    private static let blockID: UInt64 = 0xa1

    static func recognizes(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x1a && data[1] == 0x45 && data[2] == 0xdf && data[3] == 0xa3
    }

    static func extract(_ data: Data) throws -> (Data, DTSExtractionReport) {
        guard recognizes(data) else { throw DTSError.malformed("invalid EBML header") }
        guard let segment = try firstElement(id: segmentID, within: 0..<data.count, data: data) else {
            throw DTSError.malformed("Matroska Segment element was not found")
        }
        guard let tracks = try firstElement(id: tracksID, within: segment.payload, data: data),
              let trackNumber = try dtsTrackNumber(in: tracks.payload, data: data) else {
            throw DTSError.malformed("Matroska file has no A_DTS audio track")
        }

        var elementary = Data()
        elementary.reserveCapacity(max(1_048_576, data.count / 10))
        var frameCount = 0
        var cursor = segment.payload.lowerBound
        while cursor < segment.payload.upperBound {
            let element = try readElement(at: cursor, limit: segment.payload.upperBound, data: data)
            if element.id == clusterID {
                try extractCluster(
                    element.payload,
                    trackNumber: trackNumber,
                    data: data,
                    output: &elementary,
                    frameCount: &frameCount
                )
            }
            cursor = element.payload.upperBound
        }
        guard !elementary.isEmpty else {
            throw DTSError.malformed("Matroska DTS track contains no Block data")
        }
        return (
            elementary,
            DTSExtractionReport(
                format: .matroska,
                byteCount: elementary.count,
                frameCount: frameCount,
                matroskaTrackNumber: trackNumber
            )
        )
    }

    private static func dtsTrackNumber(in range: Range<Int>, data: Data) throws -> UInt64? {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let entry = try readElement(at: cursor, limit: range.upperBound, data: data)
            if entry.id == trackEntryID {
                var childCursor = entry.payload.lowerBound
                var number: UInt64?
                var type: UInt64?
                var codec: String?
                while childCursor < entry.payload.upperBound {
                    let child = try readElement(at: childCursor, limit: entry.payload.upperBound, data: data)
                    switch child.id {
                    case trackNumberID: number = try readUnsigned(child.payload, data: data)
                    case trackTypeID: type = try readUnsigned(child.payload, data: data)
                    case codecID: codec = String(decoding: data[child.payload], as: UTF8.self)
                    default: break
                    }
                    childCursor = child.payload.upperBound
                }
                if type == 2, codec?.hasPrefix("A_DTS") == true, let number { return number }
            }
            cursor = entry.payload.upperBound
        }
        return nil
    }

    private static func extractCluster(
        _ range: Range<Int>,
        trackNumber: UInt64,
        data: Data,
        output: inout Data,
        frameCount: inout Int
    ) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let element = try readElement(at: cursor, limit: range.upperBound, data: data)
            if element.id == simpleBlockID {
                try extractBlock(
                    element.payload,
                    trackNumber: trackNumber,
                    data: data,
                    output: &output,
                    frameCount: &frameCount
                )
            } else if element.id == blockGroupID {
                var groupCursor = element.payload.lowerBound
                while groupCursor < element.payload.upperBound {
                    let child = try readElement(at: groupCursor, limit: element.payload.upperBound, data: data)
                    if child.id == blockID {
                        try extractBlock(
                            child.payload,
                            trackNumber: trackNumber,
                            data: data,
                            output: &output,
                            frameCount: &frameCount
                        )
                    }
                    groupCursor = child.payload.upperBound
                }
            }
            cursor = element.payload.upperBound
        }
    }

    private static func extractBlock(
        _ range: Range<Int>,
        trackNumber: UInt64,
        data: Data,
        output: inout Data,
        frameCount: inout Int
    ) throws {
        let track = try readVINT(at: range.lowerBound, limit: range.upperBound, data: data, isID: false)
        guard track.value == trackNumber else { return }
        var cursor = range.lowerBound + track.length
        guard cursor + 3 <= range.upperBound else {
            throw DTSError.malformed("truncated Matroska Block header")
        }
        cursor += 2 // signed relative timestamp
        let flags = data[cursor]
        cursor += 1
        let lacing = (flags >> 1) & 0x03

        let sizes: [Int]
        switch lacing {
        case 0:
            sizes = [range.upperBound - cursor]
        case 1:
            (sizes, cursor) = try xiphLaceSizes(at: cursor, limit: range.upperBound, data: data)
        case 2:
            guard cursor < range.upperBound else { throw DTSError.malformed("missing fixed-lace count") }
            let count = Int(data[cursor]) + 1
            cursor += 1
            let remaining = range.upperBound - cursor
            guard remaining % count == 0 else {
                throw DTSError.malformed("fixed-laced Block payload is not evenly divisible")
            }
            sizes = Array(repeating: remaining / count, count: count)
        case 3:
            (sizes, cursor) = try ebmlLaceSizes(at: cursor, limit: range.upperBound, data: data)
        default:
            throw DTSError.malformed("invalid Matroska lacing mode")
        }

        for size in sizes {
            guard size >= 0, cursor + size <= range.upperBound else {
                throw DTSError.malformed("Matroska lace exceeds its Block")
            }
            output.append(data[cursor..<(cursor + size)])
            cursor += size
            frameCount += 1
        }
        guard cursor == range.upperBound else {
            throw DTSError.malformed("Matroska Block has unconsumed lace bytes")
        }
    }

    private static func xiphLaceSizes(
        at start: Int,
        limit: Int,
        data: Data
    ) throws -> ([Int], Int) {
        guard start < limit else { throw DTSError.malformed("missing Xiph-lace count") }
        let count = Int(data[start]) + 1
        var cursor = start + 1
        var sizes: [Int] = []
        var sum = 0
        for _ in 0..<(count - 1) {
            var size = 0
            while true {
                guard cursor < limit else { throw DTSError.malformed("truncated Xiph-lace size") }
                let byte = Int(data[cursor])
                cursor += 1
                size += byte
                if byte != 255 { break }
            }
            sizes.append(size)
            sum += size
        }
        let last = limit - cursor - sum
        guard last >= 0 else { throw DTSError.malformed("Xiph lace sizes exceed their Block") }
        sizes.append(last)
        return (sizes, cursor)
    }

    private static func ebmlLaceSizes(
        at start: Int,
        limit: Int,
        data: Data
    ) throws -> ([Int], Int) {
        guard start < limit else { throw DTSError.malformed("missing EBML-lace count") }
        let count = Int(data[start]) + 1
        var cursor = start + 1
        guard count >= 2 else { return ([limit - cursor], cursor) }
        let first = try readVINT(at: cursor, limit: limit, data: data, isID: false)
        cursor += first.length
        guard first.value <= UInt64(Int.max) else { throw DTSError.malformed("EBML lace size overflows Int") }
        var sizes = [Int(first.value)]
        var sum = Int(first.value)
        if count > 2 {
            for _ in 0..<(count - 2) {
                let deltaVINT = try readVINT(at: cursor, limit: limit, data: data, isID: false)
                cursor += deltaVINT.length
                let valueBits = 7 * deltaVINT.length
                let bias = (UInt64(1) << UInt64(valueBits - 1)) - 1
                let delta = Int64(deltaVINT.value) - Int64(bias)
                let next = Int64(sizes.last!) + delta
                guard next >= 0, next <= Int64(Int.max) else {
                    throw DTSError.malformed("invalid signed EBML-lace size delta")
                }
                sizes.append(Int(next))
                sum += Int(next)
            }
        }
        let last = limit - cursor - sum
        guard last >= 0 else { throw DTSError.malformed("EBML lace sizes exceed their Block") }
        sizes.append(last)
        return (sizes, cursor)
    }

    private static func firstElement(
        id: UInt64,
        within range: Range<Int>,
        data: Data
    ) throws -> Element? {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let element = try readElement(at: cursor, limit: range.upperBound, data: data)
            if element.id == id { return element }
            cursor = element.payload.upperBound
        }
        return nil
    }

    private static func readElement(at offset: Int, limit: Int, data: Data) throws -> Element {
        let id = try readVINT(at: offset, limit: limit, data: data, isID: true)
        let sizeOffset = offset + id.length
        let size = try readVINT(at: sizeOffset, limit: limit, data: data, isID: false)
        let payloadStart = sizeOffset + size.length
        let payloadEnd: Int
        if size.unknown {
            payloadEnd = limit
        } else {
            guard size.value <= UInt64(Int.max), payloadStart <= limit else {
                throw DTSError.malformed("EBML element size overflows the input")
            }
            let (candidate, overflow) = payloadStart.addingReportingOverflow(Int(size.value))
            guard !overflow, candidate <= limit else {
                throw DTSError.malformed("truncated EBML element 0x\(String(id.value, radix: 16))")
            }
            payloadEnd = candidate
        }
        return Element(id: id.value, payload: payloadStart..<payloadEnd)
    }

    private static func readVINT(
        at offset: Int,
        limit: Int,
        data: Data,
        isID: Bool
    ) throws -> VINT {
        guard offset < limit else { throw DTSError.malformed("truncated EBML variable integer") }
        let first = data[offset]
        guard first != 0 else { throw DTSError.malformed("invalid zero-prefixed EBML variable integer") }
        var mask: UInt8 = 0x80
        var length = 1
        while (first & mask) == 0 {
            mask >>= 1
            length += 1
        }
        guard length <= 8, offset + length <= limit else {
            throw DTSError.malformed("truncated EBML variable integer")
        }
        var value = UInt64(isID ? first : first & ~mask)
        for index in 1..<length {
            value = (value << 8) | UInt64(data[offset + index])
        }
        let valueBits = 7 * length
        let unknown = !isID && value == ((UInt64(1) << UInt64(valueBits)) - 1)
        return VINT(value: value, length: length, unknown: unknown)
    }

    private static func readUnsigned(_ range: Range<Int>, data: Data) throws -> UInt64 {
        guard !range.isEmpty, range.count <= 8 else {
            throw DTSError.malformed("invalid EBML unsigned integer width")
        }
        var value: UInt64 = 0
        for byte in data[range] { value = (value << 8) | UInt64(byte) }
        return value
    }
}
