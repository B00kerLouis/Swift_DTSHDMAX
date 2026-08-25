import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum ADMBWFReader {
    private struct WaveChunks {
        let format: AtmosPCMDescriptor
        let axmlOffset: UInt64
        let axmlByteCount: Int
        let chnaOffset: UInt64
        let chnaByteCount: Int
    }

    private struct CHNAEntry {
        let trackIndex: Int
        let uid: String
    }

    public static func read(url: URL) throws -> AtmosMaster {
        let input = url.standardizedFileURL
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: input) }
        catch { throw DTSError.io("cannot open ADM BWF: \(error.localizedDescription)") }
        defer { try? handle.close() }

        let chunks = try readWaveChunks(handle: handle, url: input)
        guard chunks.format.sampleRate == 48_000,
              chunks.format.bitDepth == 24,
              chunks.format.bytesPerPacket == chunks.format.channelCount * 3 else {
            throw DTSError.unsupported("ADM BWF must be 48 kHz packed 24-bit interleaved PCM")
        }
        let axml = try readExactly(
            chunks.axmlByteCount,
            from: handle,
            offset: chunks.axmlOffset,
            field: "ADM axml"
        )
        let chna = try readExactly(
            chunks.chnaByteCount,
            from: handle,
            offset: chunks.chnaOffset,
            field: "ADM chna"
        )
        let channelAssignments = try parseCHNA(chna, expectedChannelCount: chunks.format.channelCount)
        let metadata = try parseAXML(axml)

        var bedChannels: [AtmosBedChannel] = []
        var objects: [AtmosObjectChannel] = []
        var events: [AtmosMetadataEvent] = []
        for assignment in channelAssignments {
            guard let trackFormat = metadata.trackFormatByUID[assignment.uid],
                  let streamFormat = metadata.streamFormatByTrackFormat[trackFormat],
                  let channelFormatID = metadata.channelFormatByStreamFormat[streamFormat],
                  let channel = metadata.channelFormats[channelFormatID] else {
                throw DTSError.malformed(
                    "ADM chna track \(assignment.trackIndex) cannot be resolved through axml"
                )
            }
            let channelIndex = assignment.trackIndex - 1
            switch channel.typeDefinition {
            case "DirectSpeakers":
                guard let mapping = bedMapping(channel.name) else {
                    throw DTSError.unsupported("ADM bed channel \(channel.name)")
                }
                bedChannels.append(AtmosBedChannel(
                    dolbyName: mapping.label,
                    elementID: channelIndex,
                    audioChannelIndex: channelIndex,
                    dtsSpeaker: mapping.speaker
                ))
            case "Objects":
                objects.append(AtmosObjectChannel(
                    elementID: channelIndex,
                    audioChannelIndex: channelIndex
                ))
                for (blockIndex, block) in channel.blocks.enumerated() {
                    var event = AtmosMetadataEvent(
                        elementID: channelIndex,
                        samplePosition: try samples(block.rtime, sampleRate: chunks.format.sampleRate)
                    )
                    if blockIndex == 0 { event.active = true }
                    event.position = AtmosPosition(
                        x: block.x ?? 0,
                        y: block.y ?? 0,
                        z: block.z ?? 0
                    )
                    event.snap = false
                    if let size = [block.width, block.height, block.depth].compactMap({ $0 }).max() {
                        event.size = size
                    }
                    if let diffuse = block.diffuse { event.decorrelation = diffuse }
                    if let interpolationLength = block.interpolationLength {
                        event.rampLength = try samples(
                            interpolationLength,
                            sampleRate: chunks.format.sampleRate,
                            isDuration: true
                        )
                    }
                    event.importance = 1
                    event.gain = block.gainDB ?? 0
                    events.append(event)
                }
            default:
                throw DTSError.unsupported("ADM channel type \(channel.typeDefinition)")
            }
        }
        guard bedChannels.count + objects.count == chunks.format.channelCount else {
            throw DTSError.malformed("ADM channel assignments do not cover every PCM channel")
        }
        guard !bedChannels.isEmpty, !objects.isEmpty else {
            throw DTSError.malformed("ADM master must contain a bed and object channels")
        }
        events.sort {
            if $0.samplePosition != $1.samplePosition { return $0.samplePosition < $1.samplePosition }
            return $0.elementID < $1.elementID
        }
        return AtmosMaster(
            version: "ADM BWF",
            manifestURL: input,
            metadataURL: input,
            audioURL: input,
            offset: 0,
            firstFrameOfAction: 0,
            framesPerSecond: nil,
            bedChannels: bedChannels.sorted { $0.audioChannelIndex < $1.audioChannelIndex },
            objects: objects.sorted { $0.audioChannelIndex < $1.audioChannelIndex },
            audioFormat: chunks.format,
            metadataSampleRate: chunks.format.sampleRate,
            metadataEvents: events
        )
    }

    private static func readWaveChunks(handle: FileHandle, url: URL) throws -> WaveChunks {
        let fileSize: UInt64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw DTSError.io("ADM BWF size is unavailable")
            }
            fileSize = size.uint64Value
        } catch let error as DTSError {
            throw error
        } catch {
            throw DTSError.io("cannot inspect ADM BWF: \(error.localizedDescription)")
        }
        let header = try readExactly(12, from: handle, offset: 0, field: "ADM RIFF header")
        let container = try header.fourCC(at: 0)
        guard container == "RIFF" || container == "RF64", try header.fourCC(at: 8) == "WAVE" else {
            throw DTSError.unsupported("ADM input is not RIFF/RF64 WAVE")
        }

        var sampleRate: Int?
        var channelCount: Int?
        var bitDepth: Int?
        var blockAlign: Int?
        var dataOffset: UInt64?
        var dataByteCount: UInt64?
        var rf64DataByteCount: UInt64?
        var axml: (UInt64, Int)?
        var chna: (UInt64, Int)?
        var cursor: UInt64 = 12
        while cursor <= fileSize, fileSize - cursor >= 8 {
            let chunkHeader = try readExactly(8, from: handle, offset: cursor, field: "ADM WAVE chunk")
            let identifier = try chunkHeader.fourCC(at: 0)
            let declaredByteCount = UInt64(try chunkHeader.littleEndianUInt32(at: 4))
            let bodyOffset = cursor + 8
            var effectiveByteCount = declaredByteCount
            if identifier == "data", declaredByteCount == UInt64(UInt32.max) {
                guard let rf64DataByteCount else {
                    throw DTSError.malformed("RF64 data chunk precedes ds64")
                }
                effectiveByteCount = rf64DataByteCount
            }
            guard effectiveByteCount <= fileSize - bodyOffset else {
                throw DTSError.truncated(field: "ADM WAVE chunk \(identifier)", bitOffset: Int(bodyOffset) * 8)
            }

            switch identifier {
            case "ds64":
                guard effectiveByteCount >= 16 else { throw DTSError.malformed("RF64 ds64 is too short") }
                let body = try readExactly(16, from: handle, offset: bodyOffset, field: "ADM ds64")
                rf64DataByteCount = try body.littleEndianUInt64(at: 8)
            case "fmt ":
                guard effectiveByteCount >= 16 else { throw DTSError.malformed("ADM fmt is too short") }
                let body = try readExactly(
                    Int(min(effectiveByteCount, 40)),
                    from: handle,
                    offset: bodyOffset,
                    field: "ADM fmt"
                )
                let formatTag = try body.littleEndianUInt16(at: 0)
                guard formatTag == 1 || formatTag == 0xfffe else {
                    throw DTSError.unsupported("ADM WAVE format tag 0x\(String(formatTag, radix: 16))")
                }
                channelCount = Int(try body.littleEndianUInt16(at: 2))
                sampleRate = Int(try body.littleEndianUInt32(at: 4))
                blockAlign = Int(try body.littleEndianUInt16(at: 12))
                bitDepth = Int(try body.littleEndianUInt16(at: 14))
            case "data":
                dataOffset = bodyOffset
                dataByteCount = effectiveByteCount
            case "axml":
                guard effectiveByteCount <= UInt64(Int.max) else {
                    throw DTSError.valueOutOfRange(field: "ADM axml size", value: String(effectiveByteCount))
                }
                axml = (bodyOffset, Int(effectiveByteCount))
            case "chna":
                guard effectiveByteCount <= UInt64(Int.max) else {
                    throw DTSError.valueOutOfRange(field: "ADM chna size", value: String(effectiveByteCount))
                }
                chna = (bodyOffset, Int(effectiveByteCount))
            default:
                break
            }
            let paddedByteCount = effectiveByteCount + (effectiveByteCount & 1)
            let (next, overflow) = bodyOffset.addingReportingOverflow(paddedByteCount)
            guard !overflow, next > cursor else { throw DTSError.malformed("ADM WAVE chunk size overflow") }
            cursor = next
        }
        guard let sampleRate, let channelCount, let bitDepth, let blockAlign,
              let dataOffset, let dataByteCount, let axml, let chna else {
            throw DTSError.malformed("ADM BWF is missing fmt/data/axml/chna chunks")
        }
        guard blockAlign > 0, dataByteCount.isMultiple(of: UInt64(blockAlign)) else {
            throw DTSError.malformed("ADM PCM data is not frame aligned")
        }
        return WaveChunks(
            format: AtmosPCMDescriptor(
                container: .wave,
                sampleRate: sampleRate,
                formatID: "lpcm",
                formatFlags: 0,
                bytesPerPacket: blockAlign,
                framesPerPacket: 1,
                channelCount: channelCount,
                bitDepth: bitDepth,
                audioDataOffset: dataOffset,
                audioDataByteCount: dataByteCount,
                sampleCount: dataByteCount / UInt64(blockAlign)
            ),
            axmlOffset: axml.0,
            axmlByteCount: axml.1,
            chnaOffset: chna.0,
            chnaByteCount: chna.1
        )
    }

    private static func parseCHNA(_ data: Data, expectedChannelCount: Int) throws -> [CHNAEntry] {
        guard data.count >= 4 else { throw DTSError.malformed("ADM chna is too short") }
        let trackCount = Int(try data.littleEndianUInt16(at: 0))
        let uidCount = Int(try data.littleEndianUInt16(at: 2))
        guard trackCount == expectedChannelCount, uidCount == expectedChannelCount,
              data.count >= 4 + uidCount * 40 else {
            throw DTSError.malformed("ADM chna track/UID count does not match PCM channels")
        }
        var entries: [CHNAEntry] = []
        entries.reserveCapacity(uidCount)
        for index in 0..<uidCount {
            let offset = 4 + index * 40
            let trackIndex = Int(try data.littleEndianUInt16(at: offset))
            let uid = ascii(data[(offset + 2)..<(offset + 14)])
            guard (1...expectedChannelCount).contains(trackIndex), !uid.isEmpty else {
                throw DTSError.malformed("ADM chna contains an invalid track assignment")
            }
            entries.append(CHNAEntry(trackIndex: trackIndex, uid: uid))
        }
        let sorted = entries.sorted { $0.trackIndex < $1.trackIndex }
        guard sorted.map(\.trackIndex) == Array(1...expectedChannelCount) else {
            throw DTSError.malformed("ADM chna track indices are not contiguous")
        }
        return sorted
    }

    private static func parseAXML(_ data: Data) throws -> ADMBWFXMLDelegate.Result {
        let delegate = ADMBWFXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw DTSError.malformed(
                "ADM axml parse failed: \(parser.parserError?.localizedDescription ?? "unknown XML error")"
            )
        }
        return try delegate.result()
    }

    private static func samples(
        _ time: String,
        sampleRate: Int,
        isDuration: Bool = false
    ) throws -> Int64 {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        let secondText: Substring
        let wholeSeconds: Int64
        if isDuration, parts.count == 1 {
            secondText = parts[0]
            wholeSeconds = 0
        } else {
            guard parts.count == 3, let hours = Int64(parts[0]), let minutes = Int64(parts[1]) else {
                throw DTSError.malformed("invalid ADM time \(time)")
            }
            secondText = parts[2]
            wholeSeconds = hours * 3_600 + minutes * 60
        }
        let secondsParts = secondText.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let seconds = Int64(secondsParts[0]) else {
            throw DTSError.malformed("invalid ADM time \(time)")
        }
        var result = (wholeSeconds + seconds) * Int64(sampleRate)
        if secondsParts.count == 2, !secondsParts[1].isEmpty {
            guard let numerator = Int64(secondsParts[1]) else {
                throw DTSError.malformed("invalid ADM fractional time \(time)")
            }
            var denominator: Int64 = 1
            for _ in secondsParts[1] { denominator *= 10 }
            result += (numerator * Int64(sampleRate) + denominator / 2) / denominator
        }
        return result
    }

    private static func bedMapping(
        _ name: String
    ) -> (label: String, speaker: DTSSpeakerPosition)? {
        switch name {
        case "RoomCentricLeft": ("L", .left)
        case "RoomCentricRight": ("R", .right)
        case "RoomCentricCenter": ("C", .center)
        case "RoomCentricLFE": ("LFE", .lfe1)
        case "RoomCentricLeftSideSurround": ("Lss", .leftSideSurround)
        case "RoomCentricRightSideSurround": ("Rss", .rightSideSurround)
        case "RoomCentricLeftRearSurround": ("Lrs", .leftRearSurround)
        case "RoomCentricRightRearSurround": ("Rrs", .rightRearSurround)
        case "RoomCentricLeftTopSurround": ("Lts", .leftHeightSide)
        case "RoomCentricRightTopSurround": ("Rts", .rightHeightSide)
        default: nil
        }
    }

    private static func ascii(_ bytes: Data.SubSequence) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readExactly(
        _ count: Int,
        from handle: FileHandle,
        offset: UInt64,
        field: String
    ) throws -> Data {
        do { try handle.seek(toOffset: offset) }
        catch { throw DTSError.io("cannot seek \(field): \(error.localizedDescription)") }
        let data: Data
        do { data = try handle.read(upToCount: count) ?? Data() }
        catch { throw DTSError.io("cannot read \(field): \(error.localizedDescription)") }
        guard data.count == count else {
            throw DTSError.truncated(field: field, bitOffset: Int(offset) * 8 + data.count * 8)
        }
        return data
    }
}

private final class ADMBWFXMLDelegate: NSObject, XMLParserDelegate {
    struct Block {
        let rtime: String
        var x: Double?
        var y: Double?
        var z: Double?
        var width: Double?
        var height: Double?
        var depth: Double?
        var diffuse: Double?
        var gainDB: Double?
        var interpolationLength: String?
    }

    final class ChannelFormat {
        let id: String
        let name: String
        let typeDefinition: String
        var blocks: [Block] = []

        init(id: String, name: String, typeDefinition: String) {
            self.id = id
            self.name = name
            self.typeDefinition = typeDefinition
        }
    }

    struct Result {
        let channelFormats: [String: ChannelFormat]
        let trackFormatByUID: [String: String]
        let streamFormatByTrackFormat: [String: String]
        let channelFormatByStreamFormat: [String: String]
    }

    private var channelFormats: [String: ChannelFormat] = [:]
    private var trackFormatByUID: [String: String] = [:]
    private var streamFormatByTrackFormat: [String: String] = [:]
    private var channelFormatByStreamFormat: [String: String] = [:]
    private var currentChannel: ChannelFormat?
    private var currentBlock: Block?
    private var currentPositionCoordinate: String?
    private var currentTrackUID: String?
    private var currentTrackFormat: String?
    private var currentStreamFormat: String?
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
        switch elementName {
        case "audioChannelFormat":
            if let id = attributeDict["audioChannelFormatID"],
               let name = attributeDict["audioChannelFormatName"],
               let type = attributeDict["typeDefinition"] {
                currentChannel = ChannelFormat(id: id, name: name, typeDefinition: type)
            }
        case "audioBlockFormat":
            if currentChannel?.typeDefinition == "Objects", let rtime = attributeDict["rtime"] {
                currentBlock = Block(rtime: rtime)
            }
        case "position":
            currentPositionCoordinate = attributeDict["coordinate"]
        case "audioTrackUID":
            currentTrackUID = attributeDict["UID"]
        case "audioTrackFormat":
            currentTrackFormat = attributeDict["audioTrackFormatID"]
        case "audioStreamFormat":
            currentStreamFormat = attributeDict["audioStreamFormatID"]
        case "jumpPosition":
            if currentBlock != nil { currentBlock!.interpolationLength = attributeDict["interpolationLength"] }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentBlock != nil {
            switch elementName {
            case "position":
                if let number = Double(value) {
                    switch currentPositionCoordinate {
                    case "X": currentBlock!.x = number
                    case "Y": currentBlock!.y = number
                    case "Z": currentBlock!.z = number
                    default: break
                    }
                }
                currentPositionCoordinate = nil
            case "width": currentBlock!.width = Double(value)
            case "height": currentBlock!.height = Double(value)
            case "depth": currentBlock!.depth = Double(value)
            case "diffuse": currentBlock!.diffuse = Double(value)
            case "gain": currentBlock!.gainDB = Double(value)
            case "audioBlockFormat":
                currentChannel?.blocks.append(currentBlock!)
                currentBlock = nil
            default: break
            }
        }

        switch elementName {
        case "audioChannelFormat":
            if let channel = currentChannel { channelFormats[channel.id] = channel }
            currentChannel = nil
        case "audioTrackFormatIDRef":
            if let uid = currentTrackUID, !value.isEmpty { trackFormatByUID[uid] = value }
        case "audioTrackUID":
            currentTrackUID = nil
        case "audioStreamFormatIDRef":
            if let track = currentTrackFormat, !value.isEmpty { streamFormatByTrackFormat[track] = value }
        case "audioTrackFormat":
            currentTrackFormat = nil
        case "audioChannelFormatIDRef":
            if let stream = currentStreamFormat, !value.isEmpty { channelFormatByStreamFormat[stream] = value }
        case "audioStreamFormat":
            currentStreamFormat = nil
        default:
            break
        }
        currentText = ""
    }

    func result() throws -> Result {
        guard !channelFormats.isEmpty,
              !trackFormatByUID.isEmpty,
              !streamFormatByTrackFormat.isEmpty,
              !channelFormatByStreamFormat.isEmpty else {
            throw DTSError.malformed("ADM axml is missing channel/track/stream mappings")
        }
        return Result(
            channelFormats: channelFormats,
            trackFormatByUID: trackFormatByUID,
            streamFormatByTrackFormat: streamFormatByTrackFormat,
            channelFormatByStreamFormat: channelFormatByStreamFormat
        )
    }
}

private extension Data {
    func littleEndianUInt64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= count else {
            throw DTSError.truncated(field: "UInt64", bitOffset: Swift.max(0, offset) * 8)
        }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(self[offset + index]) << UInt64(index * 8) }
        return value
    }
}
