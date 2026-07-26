import Foundation

public enum DTSSpeakerPosition: String, Codable, Sendable, CaseIterable {
    case center = "C"
    case left = "L"
    case right = "R"
    case leftSurround = "Ls"
    case rightSurround = "Rs"
    case lfe1 = "LFE1"
    case centerSurround = "Cs"
    case leftRearSurround = "Lsr"
    case rightRearSurround = "Rsr"
    case leftSideSurround = "Lss"
    case rightSideSurround = "Rss"
    case leftHeightSide = "Lhs"
    case rightHeightSide = "Rhs"

    /// Individual-channel mask defined by ETSI TS 102 114 Table 6-22.
    public var individualMask: UInt32 {
        switch self {
        case .center: 0x0000_0001
        case .left: 0x0000_0002
        case .right: 0x0000_0004
        case .leftSurround: 0x0000_0008
        case .rightSurround: 0x0000_0010
        case .lfe1: 0x0000_0020
        case .centerSurround: 0x0000_0040
        case .leftRearSurround: 0x0000_0080
        case .rightRearSurround: 0x0000_0100
        case .leftSideSurround: 0x0000_0200
        case .rightSideSurround: 0x0000_0400
        case .leftHeightSide: 0x0010_0000
        case .rightHeightSide: 0x0020_0000
        }
    }
}

public struct AtmosBedChannel: Codable, Equatable, Sendable {
    public let dolbyName: String
    public let elementID: Int
    public let audioChannelIndex: Int
    public let dtsSpeaker: DTSSpeakerPosition
}

public struct AtmosObjectChannel: Codable, Equatable, Sendable {
    public let elementID: Int
    public let audioChannelIndex: Int
}

public struct AtmosPosition: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
}

/// One sparse DAMF metadata update. `samplePosition` is resolved even when the
/// YAML-like source omits it and inherits the preceding global sample position.
public struct AtmosMetadataEvent: Codable, Equatable, Sendable {
    public let elementID: Int
    public var samplePosition: Int64
    public var active: Bool?
    public var position: AtmosPosition?
    public var snap: Bool?
    public var elevation: Bool?
    public var zones: String?
    public var size: Double?
    public var decorrelation: Double?
    public var importance: Double?
    public var gain: Double?
    public var rampLength: Int64?
    public var trimBypass: Bool?
    public var dialog: Double?
    public var music: Double?
    public var screenFactor: Double?
    public var depthFactor: Double?
    public var headTrackMode: String?
    public var binauralRenderMode: String?
}

public enum AtmosPCMContainer: String, Codable, Sendable {
    case caf
    case wave
    /// IAB essence inside an IMF MXF track file. Audio is stored per frame as
    /// AudioDataPCM/AudioDataDLC elements, not as one interleaved PCM span;
    /// `audioDataOffset`/`audioDataByteCount` describe the raw essence range.
    case iabMXF
}

public struct AtmosPCMDescriptor: Codable, Equatable, Sendable {
    public let container: AtmosPCMContainer
    public let sampleRate: Int
    public let formatID: String
    public let formatFlags: UInt32
    public let bytesPerPacket: Int
    public let framesPerPacket: Int
    public let channelCount: Int
    public let bitDepth: Int
    public let audioDataOffset: UInt64
    public let audioDataByteCount: UInt64
    public let sampleCount: UInt64
}

public struct AtmosMaster: Codable, Equatable, Sendable {
    public let version: String
    public let manifestURL: URL
    public let metadataURL: URL
    public let audioURL: URL
    public let offset: Int64
    public let firstFrameOfAction: Int64
    public let framesPerSecond: Double?
    public let bedChannels: [AtmosBedChannel]
    public let objects: [AtmosObjectChannel]
    public let audioFormat: AtmosPCMDescriptor
    public let metadataSampleRate: Int
    public let metadataEvents: [AtmosMetadataEvent]
}

public struct AtmosMasterSummary: Codable, Equatable, Sendable {
    public let version: String
    public let sampleRate: Int
    public let bitDepth: Int
    public let audioChannelCount: Int
    public let sampleCount: UInt64
    public let offset: Int64
    public let firstFrameOfAction: Int64
    public let framesPerSecond: Double?
    public let bedChannels: [AtmosBedChannel]
    public let objectCount: Int
    public let metadataEventCount: Int
    public let positionedEventCount: Int
    public let firstMetadataSample: Int64?
    public let lastMetadataSample: Int64?

    public init(master: AtmosMaster) {
        version = master.version
        sampleRate = master.audioFormat.sampleRate
        bitDepth = master.audioFormat.bitDepth
        audioChannelCount = master.audioFormat.channelCount
        sampleCount = master.audioFormat.sampleCount
        offset = master.offset
        firstFrameOfAction = master.firstFrameOfAction
        framesPerSecond = master.framesPerSecond
        bedChannels = master.bedChannels
        objectCount = master.objects.count
        metadataEventCount = master.metadataEvents.count
        positionedEventCount = master.metadataEvents.lazy.filter { $0.position != nil }.count
        firstMetadataSample = master.metadataEvents.first?.samplePosition
        lastMetadataSample = master.metadataEvents.last?.samplePosition
    }
}

/// Native reader for Dolby Atmos Master File (DAMF) manifest, metadata, and
/// CAF layout. It does not import or link the Swift_TrueHD project.
public enum AtmosMasterReader {
    public static func read(manifestURL: URL) throws -> AtmosMaster {
        let manifestText = try textFile(manifestURL)
        let manifest = try parseManifest(manifestText, manifestURL: manifestURL)
        let audioFormat = try readCAFDescriptor(manifest.audioURL)
        guard audioFormat.channelCount == manifest.bedChannels.count + manifest.objects.count else {
            throw DTSError.malformed(
                "DAMF manifest maps \(manifest.bedChannels.count + manifest.objects.count) elements "
                + "but CAF contains \(audioFormat.channelCount) channels"
            )
        }
        let metadataText = try textFile(manifest.metadataURL)
        let metadata = try parseMetadata(metadataText)
        guard metadata.sampleRate == audioFormat.sampleRate else {
            throw DTSError.malformed(
                "DAMF metadata sample rate \(metadata.sampleRate) differs from CAF \(audioFormat.sampleRate)"
            )
        }
        return AtmosMaster(
            version: manifest.version,
            manifestURL: manifestURL,
            metadataURL: manifest.metadataURL,
            audioURL: manifest.audioURL,
            offset: manifest.offset,
            firstFrameOfAction: manifest.ffoa,
            framesPerSecond: manifest.fps,
            bedChannels: manifest.bedChannels,
            objects: manifest.objects,
            audioFormat: audioFormat,
            metadataSampleRate: metadata.sampleRate,
            metadataEvents: metadata.events
        )
    }

    private struct ParsedManifest {
        let version: String
        let metadataURL: URL
        let audioURL: URL
        let offset: Int64
        let ffoa: Int64
        let fps: Double
        let bedChannels: [AtmosBedChannel]
        let objects: [AtmosObjectChannel]
    }

    private struct ParsedMetadata {
        let sampleRate: Int
        let events: [AtmosMetadataEvent]
    }

    private static func parseManifest(_ text: String, manifestURL: URL) throws -> ParsedManifest {
        var version: String?
        var metadataName: String?
        var audioName: String?
        var offset: Int64?
        var ffoa: Int64?
        var fps: Double?
        var bedEntries: [(String, Int)] = []
        var objectIDs: [Int] = []
        var pendingBedName: String?
        var inObjects = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("version:") { version = scalar(afterColon: line) }
            else if line.hasPrefix("metadata:") { metadataName = scalar(afterColon: line) }
            else if line.hasPrefix("audio:") { audioName = scalar(afterColon: line) }
            else if line.hasPrefix("offset:") { offset = Int64(scalar(afterColon: line)) }
            else if line.hasPrefix("ffoa:") { ffoa = Int64(scalar(afterColon: line)) }
            else if line.hasPrefix("fps:") { fps = Double(scalar(afterColon: line)) }
            else if line == "objects:" { inObjects = true; pendingBedName = nil }
            else if !inObjects, line.hasPrefix("- channel:") {
                pendingBedName = scalar(afterColon: line)
            } else if line.hasPrefix("ID:") || line.hasPrefix("- ID:") {
                guard let id = Int(scalar(afterColon: line)) else {
                    throw DTSError.malformed("DAMF manifest contains a non-integer element ID")
                }
                if inObjects {
                    objectIDs.append(id)
                } else if let name = pendingBedName {
                    bedEntries.append((name, id))
                    pendingBedName = nil
                }
            }
        }

        guard let version, let metadataName, let audioName,
              let offset, let ffoa, let fps else {
            throw DTSError.malformed("DAMF manifest is missing required presentation fields")
        }
        guard !bedEntries.isEmpty else { throw DTSError.malformed("DAMF manifest has no bed channels") }
        let directory = manifestURL.deletingLastPathComponent()
        let bedChannels = try bedEntries.enumerated().map { index, entry in
            guard let speaker = dtsSpeaker(forDolbyBedName: entry.0) else {
                throw DTSError.unsupported("Dolby bed channel \(entry.0) has no DTS mapping")
            }
            return AtmosBedChannel(
                dolbyName: entry.0,
                elementID: entry.1,
                audioChannelIndex: index,
                dtsSpeaker: speaker
            )
        }
        let objects = objectIDs.enumerated().map { index, id in
            AtmosObjectChannel(elementID: id, audioChannelIndex: bedChannels.count + index)
        }
        return ParsedManifest(
            version: version,
            metadataURL: directory.appendingPathComponent(metadataName),
            audioURL: directory.appendingPathComponent(audioName),
            offset: offset,
            ffoa: ffoa,
            fps: fps,
            bedChannels: bedChannels,
            objects: objects
        )
    }

    private static func parseMetadata(_ text: String) throws -> ParsedMetadata {
        var sampleRate: Int?
        var events: [AtmosMetadataEvent] = []
        events.reserveCapacity(max(1_024, text.utf8.count / 64))
        var currentSamplePosition: Int64 = 0
        var event: AtmosMetadataEvent?

        func finishEvent() {
            if let event { events.append(event) }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("sampleRate:") {
                sampleRate = Int(scalar(afterColon: line))
            } else if line.hasPrefix("- ID:") {
                finishEvent()
                guard let id = Int(scalar(afterColon: line)) else { continue }
                event = AtmosMetadataEvent(elementID: id, samplePosition: currentSamplePosition)
            } else if event != nil {
                let value = scalar(afterColon: line)
                switch fieldName(line) {
                case "samplePos":
                    if let position = Int64(value) {
                        currentSamplePosition = position
                        event!.samplePosition = position
                    }
                case "active": event!.active = Bool(value)
                case "pos": event!.position = try parsePosition(value)
                case "snap": event!.snap = Bool(value)
                case "elevation": event!.elevation = Bool(value)
                case "zones": event!.zones = value
                case "size": event!.size = Double(value)
                case "decorr": event!.decorrelation = Double(value)
                case "importance": event!.importance = Double(value)
                case "gain": event!.gain = Double(value)
                case "rampLength": event!.rampLength = Int64(value)
                case "trimBypass": event!.trimBypass = Bool(value)
                case "dialog": event!.dialog = Double(value)
                case "music": event!.music = Double(value)
                case "screenFactor": event!.screenFactor = Double(value)
                case "depthFactor": event!.depthFactor = Double(value)
                case "headTrackMode": event!.headTrackMode = value
                case "binauralRenderMode": event!.binauralRenderMode = value
                default: break
                }
            }
        }
        finishEvent()
        guard let sampleRate else { throw DTSError.malformed("DAMF metadata has no sampleRate") }
        guard !events.isEmpty else { throw DTSError.malformed("DAMF metadata has no events") }
        return ParsedMetadata(sampleRate: sampleRate, events: events)
    }

    private static func parsePosition(_ value: String) throws -> AtmosPosition {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let components = trimmed.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard components.count == 3,
              let x = Double(components[0]),
              let y = Double(components[1]),
              let z = Double(components[2]) else {
            throw DTSError.malformed("invalid DAMF object position \(value)")
        }
        return AtmosPosition(x: x, y: y, z: z)
    }

    private static func dtsSpeaker(forDolbyBedName name: String) -> DTSSpeakerPosition? {
        switch name {
        case "L": .left
        case "R": .right
        case "C": .center
        case "LFE": .lfe1
        case "Lss": .leftSideSurround
        case "Rss": .rightSideSurround
        // Dolby spells rear surround "Lrs/Rrs"; DTS spells it "Lsr/Rsr".
        case "Lrs": .leftRearSurround
        case "Rrs": .rightRearSurround
        // Dolby top-surround is the angular counterpart of DTS height-side.
        case "Lts": .leftHeightSide
        case "Rts": .rightHeightSide
        default: nil
        }
    }

    private static func readCAFDescriptor(_ url: URL) throws -> AtmosPCMDescriptor {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw DTSError.io("cannot open \(url.path): \(error.localizedDescription)") }
        defer { try? handle.close() }
        let header = try readExactly(8, from: handle, field: "CAF header")
        guard try header.fourCC(at: 0) == "caff" else {
            throw DTSError.unsupported("DAMF audio is not a CAF file")
        }
        var cursor: UInt64 = 8
        var description: (Int, String, UInt32, Int, Int, Int, Int)?
        var audioData: (UInt64, UInt64)?
        while audioData == nil || description == nil {
            try handle.seek(toOffset: cursor)
            let chunkHeader = try readExactly(12, from: handle, field: "CAF chunk header")
            let identifier = try chunkHeader.fourCC(at: 0)
            let chunkSize = try chunkHeader.bigEndianUInt64(at: 4)
            let payloadOffset = cursor + 12
            if identifier == "desc" {
                guard chunkSize >= 32 else { throw DTSError.malformed("CAF desc chunk is too short") }
                let body = try readExactly(32, from: handle, field: "CAF desc")
                let sampleRate = Double(bitPattern: try body.bigEndianUInt64(at: 0))
                description = (
                    Int(sampleRate.rounded()), try body.fourCC(at: 8),
                    try body.bigEndianUInt32(at: 12), Int(try body.bigEndianUInt32(at: 16)),
                    Int(try body.bigEndianUInt32(at: 20)), Int(try body.bigEndianUInt32(at: 24)),
                    Int(try body.bigEndianUInt32(at: 28))
                )
            } else if identifier == "data" {
                guard chunkSize >= 4 else { throw DTSError.malformed("CAF data chunk has no edit count") }
                audioData = (payloadOffset + 4, chunkSize - 4)
            }
            guard chunkSize != UInt64.max else {
                throw DTSError.unsupported("CAF chunk with unknown size")
            }
            let (next, overflow) = payloadOffset.addingReportingOverflow(chunkSize)
            guard !overflow, next > cursor else { throw DTSError.malformed("CAF chunk size overflow") }
            cursor = next
        }
        guard let description, let audioData else { throw DTSError.malformed("CAF is incomplete") }
        let (sampleRate, formatID, flags, bytesPerPacket, framesPerPacket, channels, bitDepth) = description
        guard formatID == "lpcm", bitDepth == 24, framesPerPacket == 1,
              bytesPerPacket == channels * 3 else {
            throw DTSError.unsupported(
                "DAMF CAF must be packed 24-bit LPCM with one frame per packet"
            )
        }
        guard audioData.1.isMultiple(of: UInt64(bytesPerPacket)) else {
            throw DTSError.malformed("CAF audio byte count is not packet aligned")
        }
        return AtmosPCMDescriptor(
            container: .caf,
            sampleRate: sampleRate,
            formatID: formatID,
            formatFlags: flags,
            bytesPerPacket: bytesPerPacket,
            framesPerPacket: framesPerPacket,
            channelCount: channels,
            bitDepth: bitDepth,
            audioDataOffset: audioData.0,
            audioDataByteCount: audioData.1,
            sampleCount: audioData.1 / UInt64(bytesPerPacket)
        )
    }

    private static func textFile(_ url: URL) throws -> String {
        do { return String(decoding: try Data(contentsOf: url), as: UTF8.self) }
        catch { throw DTSError.io("cannot read \(url.path): \(error.localizedDescription)") }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle, field: String) throws -> Data {
        let data: Data
        do { data = try handle.read(upToCount: count) ?? Data() }
        catch { throw DTSError.io("cannot read \(field): \(error.localizedDescription)") }
        guard data.count == count else { throw DTSError.truncated(field: field, bitOffset: 0) }
        return data
    }

    private static func scalar(afterColon line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    private static func fieldName(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        return String(line[..<colon])
    }
}
