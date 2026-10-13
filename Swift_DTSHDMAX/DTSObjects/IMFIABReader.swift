import Foundation

/// Native reader for IMF IAB track files: MXF (SMPTE ST 377-1) generic
/// container essence carrying a SMPTE ST 2098-2 Immersive Audio Bitstream.
///
/// The MXF layer locates IAB essence element KLVs (clip- or frame-wrapped,
/// essence element key `06.0E.2B.34.01.02.01.xx.0D.01.03.01` with item type
/// 0x16 and element type 0x0D). The IAB layer parses every IABitstream frame:
/// the IAFrame header, BedDefinition channels, ObjectDefinition per-sub-block
/// pan states, and the AudioDataPCM/AudioDataDLC essence directory.
///
/// Positions are converted from the ST 2098-2 unit cube (x: 0=left wall,
/// y: 0=front wall, z: 0=speaker plane) to the Dolby room-centric coordinates
/// used by the shared Atmos scene model:
///
///     dolbyX = 2*iabX - 1    dolbyY = 1 - 2*iabY    dolbyZ = iabZ
///
/// The bed/object structure must be constant across frames, which is how IMF
/// IAB masters are authored; a stream whose element layout changes mid-program
/// is rejected instead of guessed at.
public struct IABMaster: Sendable {
    /// Metadata-compatible view usable by inspect/compare tooling. The
    /// descriptor's `audioDataOffset`/`audioDataByteCount` reference the raw
    /// IAB essence span, not interleaved PCM.
    public let master: AtmosMaster
    public let samplesPerFrame: Int
    public let frameRateCode: Int
    public let bitDepthCode: Int

    struct PlaneAudio: Sendable {
        /// Byte offset of the AudioData element start within the frame body;
        /// -1 marks a silent plane (AudioDataID 0).
        let elementOffset: Int32
        let isDLC: Bool
    }

    struct FrameAudioIndex: Sendable {
        let bodyOffset: UInt64
        let bodyByteCount: Int
        let planeAudio: [PlaneAudio]
    }

    let frames: [FrameAudioIndex]
}

public enum IMFIABReader {
    // MARK: - Public entry points

    public static func read(url: URL) throws -> IABMaster {
        let input = url.standardizedFileURL
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: input) }
        catch { throw DTSError.io("cannot open IMF IAB MXF: \(error.localizedDescription)") }
        defer { try? handle.close() }
        let fileSize = try fileByteCount(input)

        let essenceRanges = try locateIABEssence(handle: handle, fileSize: fileSize)
        guard !essenceRanges.isEmpty else {
            throw DTSError.unsupported("MXF file contains no IAB essence element (item 0x16, type 0x0D)")
        }

        var layout: Layout?
        var frames: [IABMaster.FrameAudioIndex] = []
        var events: [AtmosMetadataEvent] = []
        var header: FrameHeader?

        for range in essenceRanges {
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                guard range.upperBound - cursor >= 5 else {
                    throw DTSError.truncated(field: "IABitstream TLV header", bitOffset: Int(cursor) * 8)
                }
                let tlvHeader = try readExactly(5, from: handle, offset: cursor, field: "IABitstream TLV header")
                let tag = tlvHeader[tlvHeader.startIndex]
                let length = UInt64(try tlvHeader.bigEndianUInt32(at: 1))
                let bodyOffset = cursor + 5
                guard length <= range.upperBound - bodyOffset else {
                    throw DTSError.truncated(field: "IABitstream TLV body", bitOffset: Int(bodyOffset) * 8)
                }
                switch tag {
                case 0x01:
                    break // Preamble segment; content is out of scope per ST 2098-2 section 8.1.3.
                case 0x02:
                    guard length <= UInt64(Int.max) else {
                        throw DTSError.valueOutOfRange(field: "IAFrame length", value: String(length))
                    }
                    let body = try readExactly(Int(length), from: handle, offset: bodyOffset, field: "IAFrame")
                    let frameIndex = frames.count
                    let parsed = try parseFrame(
                        body: body,
                        frameIndex: frameIndex,
                        layout: &layout,
                        header: &header,
                        events: &events
                    )
                    frames.append(IABMaster.FrameAudioIndex(
                        bodyOffset: bodyOffset,
                        bodyByteCount: Int(length),
                        planeAudio: parsed
                    ))
                default:
                    throw DTSError.malformed("unknown IABitstream segment tag 0x\(String(tag, radix: 16))")
                }
                cursor = bodyOffset + length
            }
        }

        guard let layout, let header, !frames.isEmpty else {
            throw DTSError.malformed("IAB essence contains no IAFrame")
        }
        events.sort {
            if $0.samplePosition != $1.samplePosition { return $0.samplePosition < $1.samplePosition }
            return $0.elementID < $1.elementID
        }

        let samplesPerFrame = try frameSampleCount(frameRateCode: header.frameRateCode)
        let planeCount = layout.bedChannels.count + layout.objects.count
        let sampleCount = UInt64(frames.count) * UInt64(samplesPerFrame)
        let descriptor = AtmosPCMDescriptor(
            container: .iabMXF,
            sampleRate: 48_000,
            formatID: "iabf",
            formatFlags: 0,
            bytesPerPacket: planeCount * 3,
            framesPerPacket: 1,
            channelCount: planeCount,
            bitDepth: 24,
            audioDataOffset: essenceRanges[0].lowerBound,
            audioDataByteCount: essenceRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) },
            sampleCount: sampleCount
        )
        let master = AtmosMaster(
            version: "IMF IAB (ST 2098-2)",
            manifestURL: input,
            metadataURL: input,
            audioURL: input,
            offset: 0,
            firstFrameOfAction: 0,
            framesPerSecond: frameRate(code: header.frameRateCode),
            bedChannels: layout.bedChannels,
            objects: layout.objects,
            audioFormat: descriptor,
            metadataSampleRate: 48_000,
            metadataEvents: events
        )
        return IABMaster(
            master: master,
            samplesPerFrame: samplesPerFrame,
            frameRateCode: header.frameRateCode,
            bitDepthCode: header.bitDepthCode,
            frames: frames
        )
    }

    /// True when the file starts with an MXF partition pack key.
    public static func hasMXFHeader(_ url: URL) throws -> Bool {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw DTSError.io("cannot open \(url.path): \(error.localizedDescription)") }
        defer { try? handle.close() }
        let prefix: Data
        do { prefix = try handle.read(upToCount: 13) ?? Data() }
        catch { throw DTSError.io("cannot read \(url.path): \(error.localizedDescription)") }
        let partitionPackPrefix: [UInt8] = [
            0x06, 0x0e, 0x2b, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0d, 0x01, 0x02, 0x01
        ]
        guard prefix.count == 13 else { return false }
        return Array(prefix.prefix(12)) == partitionPackPrefix
    }

    /// Decodes one frame's audio into packed 24-bit little-endian interleaved
    /// PCM in plane order (bed channels, then objects).
    static func decodeFrameAudio(
        iab: IABMaster,
        frameIndex: Int,
        handle: FileHandle
    ) throws -> Data {
        let frame = iab.frames[frameIndex]
        let body = try readExactly(
            frame.bodyByteCount,
            from: handle,
            offset: frame.bodyOffset,
            field: "IAFrame audio body"
        )
        let planeCount = frame.planeAudio.count
        let sampleCount = iab.samplesPerFrame
        let planes: [[Int32]?] = try DTSParallel.map(count: planeCount,
            workerCount: planeCount >= 8 ? DTSParallel.workerCount(for: planeCount) : 1) { plane in
            let reference = frame.planeAudio[plane]
            guard reference.elementOffset >= 0 else { return nil }
            return try decodeAudioElement(
                bytes: body,
                elementOffset: Int(reference.elementOffset),
                isDLC: reference.isDLC,
                sampleCount: sampleCount,
                bitDepthCode: iab.bitDepthCode,
                frameRateCode: iab.frameRateCode
            )
        }
        var interleaved = Data(count: sampleCount * planeCount * 3)
        interleaved.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: UInt8.self)
            for plane in planes.indices {
                guard let samples = planes[plane] else { continue }
                for sample in 0..<sampleCount {
                    let value = UInt32(bitPattern: samples[sample]) & 0x00ff_ffff
                    let destination = (sample * planeCount + plane) * 3
                    output[destination] = UInt8(value & 0xff)
                    output[destination + 1] = UInt8((value >> 8) & 0xff)
                    output[destination + 2] = UInt8((value >> 16) & 0xff)
                }
            }
        }
        return interleaved
    }

    // MARK: - MXF KLV layer

    private static func locateIABEssence(
        handle: FileHandle,
        fileSize: UInt64
    ) throws -> [Range<UInt64>] {
        var ranges: [Range<UInt64>] = []
        var cursor: UInt64 = 0
        while cursor < fileSize {
            guard fileSize - cursor >= 17 else { break }
            let keyAndLength = try readExactly(17, from: handle, offset: cursor, field: "MXF KLV key")
            let key = Array(keyAndLength.prefix(16))
            guard key[0] == 0x06, key[1] == 0x0e, key[2] == 0x2b, key[3] == 0x34 else {
                throw DTSError.malformed("MXF KLV key does not start with a SMPTE UL at byte \(cursor)")
            }
            var lengthByteCount = 1
            var length: UInt64
            let first = keyAndLength[keyAndLength.startIndex + 16]
            if first < 0x80 {
                length = UInt64(first)
            } else {
                let extra = Int(first & 0x7f)
                guard extra > 0, extra <= 8 else {
                    throw DTSError.malformed("unsupported MXF BER length at byte \(cursor)")
                }
                let lengthBytes = try readExactly(
                    extra,
                    from: handle,
                    offset: cursor + 17,
                    field: "MXF BER length"
                )
                length = 0
                for byte in lengthBytes { length = (length << 8) | UInt64(byte) }
                lengthByteCount += extra
            }
            let bodyOffset = cursor + 16 + UInt64(lengthByteCount)
            guard length <= fileSize - bodyOffset else {
                throw DTSError.truncated(field: "MXF KLV body", bitOffset: Int(bodyOffset) * 8)
            }
            // Generic-container essence element: 06.0E.2B.34.01.02.01.xx
            // 0D.01.03.01, item type 0x16 (sound), element type 0x0D (IAB
            // clip-wrapped, ST 2067-201).
            if key[4] == 0x01, key[5] == 0x02, key[6] == 0x01,
               key[8] == 0x0d, key[9] == 0x01, key[10] == 0x03, key[11] == 0x01,
               key[12] == 0x16, key[14] == 0x0d {
                ranges.append(bodyOffset..<(bodyOffset + length))
            }
            cursor = bodyOffset + length
        }
        return ranges
    }

    // MARK: - IAFrame parsing

    private struct FrameHeader {
        let sampleRateCode: Int
        let bitDepthCode: Int
        let frameRateCode: Int
    }

    private struct Layout {
        let bedChannelIDs: [Int]
        let bedIdentities: [String]
        let objectMetaIDs: [Int]
        let objectIndexByMetaID: [Int: Int]
        let bedChannels: [AtmosBedChannel]
        let objects: [AtmosObjectChannel]
    }

    private struct ParsedBedChannel {
        let channelID: Int
        let audioDataID: Int
        let bedID: String
    }

    private struct ParsedObjectSubBlock {
        let gainDB: Double
        let position: AtmosPosition
        let snap: Bool
        let size: Double
        let decorrelation: Double
    }

    private struct ParsedObject {
        let metaID: Int
        let audioDataID: Int
        /// One entry per pan sub block; nil where PanInfoExists == 0.
        let subBlocks: [ParsedObjectSubBlock?]
    }

    private static func parseFrame(
        body: Data,
        frameIndex: Int,
        layout: inout Layout?,
        header: inout FrameHeader?,
        events: inout [AtmosMetadataEvent]
    ) throws -> [IABMaster.PlaneAudio] {
        var reader = try BitReader(data: body)
        let frameElementID = try plex(&reader, startWidth: 8, field: "IAFrame ElementID")
        guard frameElementID == 0x08 else {
            throw DTSError.malformed("IABitstream frame does not start with IA_FRAME (0x08)")
        }
        _ = try plex(&reader, startWidth: 8, field: "IAFrame ElementSize")

        let version = try reader.read(8, field: "IAFrame Version")
        guard version == 1 else {
            throw DTSError.unsupported("IAB bitstream version \(version)")
        }
        let sampleRateCode = Int(try reader.read(2, field: "IAFrame SampleRate"))
        guard sampleRateCode == 0 else {
            throw DTSError.unsupported("IAB sample rate code \(sampleRateCode); this pipeline requires 48 kHz")
        }
        let bitDepthCode = Int(try reader.read(2, field: "IAFrame BitDepth"))
        guard bitDepthCode == 0 || bitDepthCode == 1 else {
            throw DTSError.malformed("reserved IAB bit depth code \(bitDepthCode)")
        }
        let frameRateCode = Int(try reader.read(4, field: "IAFrame FrameRate"))
        _ = try plex(&reader, startWidth: 8, field: "IAFrame MaxRendered")
        try reader.alignToByte(field: "IAFrame AlignBits")

        if let header {
            guard header.frameRateCode == frameRateCode,
                  header.bitDepthCode == bitDepthCode else {
                throw DTSError.malformed("IAFrame \(frameIndex) changes frame rate or bit depth mid-program")
            }
        } else {
            header = FrameHeader(
                sampleRateCode: sampleRateCode,
                bitDepthCode: bitDepthCode,
                frameRateCode: frameRateCode
            )
        }

        let subBlockCounts = try panSubBlockSampleCounts(frameRateCode: frameRateCode)
        let samplesPerFrame = try frameSampleCount(frameRateCode: frameRateCode)

        var bedChannels: [ParsedBedChannel] = []
        var objects: [ParsedObject] = []
        var audioDirectory: [Int: (offset: Int, isDLC: Bool)] = [:]

        let subElementCount = try plex(&reader, startWidth: 8, field: "IAFrame SubElementCount")
        for _ in 0..<subElementCount {
            try parseElement(
                &reader,
                subBlockCount: subBlockCounts.count,
                bedChannels: &bedChannels,
                objects: &objects,
                audioDirectory: &audioDirectory
            )
        }

        // Establish or verify the constant program layout.
        if let layout {
            guard bedChannels.map(\.channelID) == layout.bedChannelIDs,
                  bedChannels.map(\.bedID) == layout.bedIdentities,
                  objects.map(\.metaID) == layout.objectMetaIDs else {
                throw DTSError.unsupported(
                    "IAFrame \(frameIndex) changes the bed/object layout; dynamic IAB layouts are not supported"
                )
            }
        } else {
            layout = try makeLayout(bedChannels: bedChannels, objects: objects)
        }

        // Emit metadata events at exact sub-block sample positions.
        let frameStartSample = Int64(frameIndex) * Int64(samplesPerFrame)
        let bedPlaneCount = bedChannels.count
        for (objectIndex, object) in objects.enumerated() {
            var offsetInFrame: Int64 = 0
            for (subBlock, sampleCountForBlock) in subBlockCounts.enumerated() {
                defer { offsetInFrame += Int64(sampleCountForBlock) }
                guard let state = object.subBlocks[subBlock] else { continue }
                var event = AtmosMetadataEvent(
                    elementID: bedPlaneCount + objectIndex,
                    samplePosition: frameStartSample + offsetInFrame
                )
                if frameIndex == 0, subBlock == 0 { event.active = true }
                event.position = state.position
                event.snap = state.snap
                event.size = state.size
                event.decorrelation = state.decorrelation
                event.importance = 1
                event.gain = state.gainDB
                events.append(event)
            }
        }

        // Resolve each plane's audio element for this frame.
        var planeAudio: [IABMaster.PlaneAudio] = []
        planeAudio.reserveCapacity(bedChannels.count + objects.count)
        for channel in bedChannels {
            planeAudio.append(try resolveAudio(channel.audioDataID, in: audioDirectory, frameIndex: frameIndex))
        }
        for object in objects {
            planeAudio.append(try resolveAudio(object.audioDataID, in: audioDirectory, frameIndex: frameIndex))
        }
        return planeAudio
    }

    private static func resolveAudio(
        _ audioDataID: Int,
        in directory: [Int: (offset: Int, isDLC: Bool)],
        frameIndex: Int
    ) throws -> IABMaster.PlaneAudio {
        if audioDataID == 0 {
            return IABMaster.PlaneAudio(elementOffset: -1, isDLC: false)
        }
        guard let entry = directory[audioDataID] else {
            throw DTSError.malformed("IAFrame \(frameIndex) references missing AudioDataID \(audioDataID)")
        }
        guard entry.offset <= Int(Int32.max) else {
            throw DTSError.valueOutOfRange(field: "AudioData element offset", value: String(entry.offset))
        }
        return IABMaster.PlaneAudio(elementOffset: Int32(entry.offset), isDLC: entry.isDLC)
    }

    private static func parseElement(
        _ reader: inout BitReader,
        subBlockCount: Int,
        bedChannels: inout [ParsedBedChannel],
        objects: inout [ParsedObject],
        audioDirectory: inout [Int: (offset: Int, isDLC: Bool)]
    ) throws {
        guard reader.isByteAligned else {
            throw DTSError.malformed("IAElement does not start on a byte boundary")
        }
        let elementStart = reader.bitOffset / 8
        let elementID = try plex(&reader, startWidth: 8, field: "IAElement ElementID")
        let elementSize = try plex(&reader, startWidth: 8, field: "IAElement ElementSize")
        let contentStartBit = reader.bitOffset
        let endBit = contentStartBit + elementSize * 8
        guard endBit <= reader.bitLimit else {
            throw DTSError.truncated(field: "IAElement body", bitOffset: contentStartBit)
        }

        switch elementID {
        case 0x10: // BED_DEFINITION
            try parseBedDefinition(&reader, endBit: endBit, bedChannels: &bedChannels)
        case 0x40: // OBJECT_DEFINITION
            if let object = try parseObjectDefinition(&reader, subBlockCount: subBlockCount) {
                objects.append(object)
            }
        case 0x400, 0x200: // AUDIO_DATA_PCM / AUDIO_DATA_DLC
            let audioDataID = try plex(&reader, startWidth: 8, field: "AudioDataID")
            guard audioDataID != 0 else {
                throw DTSError.malformed("AudioData element carries the reserved AudioDataID 0")
            }
            guard audioDirectory.updateValue(
                (offset: elementStart, isDLC: elementID == 0x200),
                forKey: audioDataID
            ) == nil else {
                throw DTSError.malformed("IAFrame contains duplicate AudioDataID \(audioDataID)")
            }
        default:
            break // Unknown elements shall be skipped (ST 2098-2 section 10.1.1).
        }

        try reader.seek(to: endBit, field: "IAElement boundary")
    }

    private static func parseBedDefinition(
        _ reader: inout BitReader,
        endBit: Int,
        bedChannels: inout [ParsedBedChannel]
    ) throws {
        let metaID = try plex(&reader, startWidth: 8, field: "BedDefinition MetaID")
        let ordinal = Set(bedChannels.map(\.bedID)).count
        let bedID = "IAB-bed-\(metaID)-\(ordinal)"
        let conditional = try reader.read(1, field: "ConditionalBed")
        var useCase = 0xff
        if conditional == 1 {
            useCase = Int(try reader.read(8, field: "BedUseCase"))
        }
        // Render unconditional beds and beds marked Always Use; a bed bound to
        // a specific cinema Soundfield Configuration is not activated for this
        // renderer's target environment.
        let activated = conditional == 0 || useCase == 0xff
        let channelCount = try plex(&reader, startWidth: 4, field: "BedDefinition ChannelCount")
        var parsed: [ParsedBedChannel] = []
        var seen = Set<Int>()
        for _ in 0..<channelCount {
            let channelID = try plex(&reader, startWidth: 4, field: "ChannelID")
            guard seen.insert(channelID).inserted else {
                throw DTSError.malformed("IAB bed repeats ChannelID \(channelID)")
            }
            let audioDataID = try plex(&reader, startWidth: 8, field: "bed AudioDataID")
            let gainPrefix = try reader.read(2, field: "ChannelGainPrefix")
            switch gainPrefix {
            case 0:
                break // gain 1.0
            case 2:
                let gainCode = try reader.read(10, field: "ChannelGain")
                guard gainCode == 0 else {
                    throw DTSError.unsupported(
                        "IAB bed ChannelGain code \(gainCode); non-unity per-frame bed gains are not implemented"
                    )
                }
            default:
                throw DTSError.unsupported("IAB bed ChannelGainPrefix \(gainPrefix)")
            }
            let decorExists = try reader.read(1, field: "ChannelDecorInfoExists")
            if decorExists == 1 {
                _ = try reader.read(4, field: "bed decor reserved")
                let decorPrefix = try reader.read(2, field: "ChannelDecorCoefPrefix")
                if decorPrefix > 1 { _ = try reader.read(8, field: "ChannelDecorCoef") }
            }
            parsed.append(ParsedBedChannel(channelID: channelID, audioDataID: audioDataID, bedID: bedID))
        }
        let reserved = try reader.read(10, field: "BedDefinition reserved")
        guard reserved == 0x180 else {
            throw DTSError.malformed("BedDefinition reserved field is 0x\(String(reserved, radix: 16)), expected 0x180")
        }
        try reader.alignToByte(field: "BedDefinition AlignBits")
        let audioDescription = try reader.read(8, field: "bed AudioDescription")
        if audioDescription & 0x80 != 0 {
            while try reader.read(8, field: "bed AudioDescriptionText") != 0 {}
        }
        // Child elements (conditional replacement beds / BedRemap) are only
        // activated for specific cinema environments; the Always Use parent is
        // the rendered bed, so children are skipped via the element boundary.
        _ = try plex(&reader, startWidth: 8, field: "BedDefinition SubElementCount")
        _ = endBit
        if activated {
            bedChannels.append(contentsOf: parsed)
        }
    }

    private static func parseObjectDefinition(
        _ reader: inout BitReader,
        subBlockCount: Int
    ) throws -> ParsedObject? {
        let metaID = try plex(&reader, startWidth: 8, field: "ObjectDefinition MetaID")
        let audioDataID = try plex(&reader, startWidth: 8, field: "object AudioDataID")
        let conditional = try reader.read(1, field: "ConditionalObject")
        var useCase = 0xff
        if conditional == 1 {
            _ = try reader.read(1, field: "ConditionalObject reserved")
            useCase = Int(try reader.read(8, field: "ObjectUseCase"))
        }
        _ = try reader.read(1, field: "ObjectDefinition reserved")

        var subBlocks: [ParsedObjectSubBlock?] = []
        subBlocks.reserveCapacity(subBlockCount)
        for subBlock in 0..<subBlockCount {
            let panInfoExists = subBlock == 0 ? 1 : try reader.read(1, field: "PanInfoExists")
            guard panInfoExists == 1 else {
                subBlocks.append(nil)
                continue
            }
            let gainPrefix = try reader.read(2, field: "ObjectGainPrefix")
            let gainDB: Double
            switch gainPrefix {
            case 0:
                gainDB = 0
            case 1:
                // Zero linear gain. -960 dB quantizes to exactly zero in the
                // renderer's Q30 pan gains and stays JSON-encodable.
                gainDB = -960
            case 2:
                let gainCode = try reader.read(10, field: "ObjectGain")
                gainDB = gainCode == 0x3ff
                    ? -960
                    : -Double(gainCode) * 6.020599913279624 / 64
            default:
                throw DTSError.malformed("reserved ObjectGainPrefix 3")
            }
            let reserved = try reader.read(3, field: "ObjectDefinition sub-block reserved")
            guard reserved == 0b001 else {
                throw DTSError.malformed("ObjectDefinition reserved bits are \(reserved), expected 0b001")
            }
            let x = try distanceXY(Int(try reader.read(16, field: "ObjectPosX")), field: "ObjectPosX")
            let y = try distanceXY(Int(try reader.read(16, field: "ObjectPosY")), field: "ObjectPosY")
            let z = Double(try reader.read(16, field: "ObjectPosZ")) / 65_535
            let snap = try reader.read(1, field: "ObjectSnap") == 1
            if snap {
                let toleranceExists = try reader.read(1, field: "ObjectSnapTolExists")
                if toleranceExists == 1 { _ = try reader.read(12, field: "ObjectSnapTolerance") }
                _ = try reader.read(1, field: "ObjectSnap Res2")
            }
            let zoneControl = try reader.read(1, field: "ObjectZoneControl")
            if zoneControl == 1 {
                for _ in 0..<9 {
                    let zonePrefix = try reader.read(2, field: "ZoneGainPrefix")
                    if zonePrefix > 1 { _ = try reader.read(10, field: "ZoneGain") }
                }
            }
            let spreadMode = try reader.read(2, field: "ObjectSpreadMode")
            let size: Double
            switch spreadMode {
            case 0: size = Double(try reader.read(8, field: "ObjectSpread")) / 255
            case 1: size = 0
            case 2: size = Double(try reader.read(12, field: "ObjectSpread")) / 4_095
            default:
                let spreadX = Double(try reader.read(12, field: "ObjectSpreadX")) / 4_095
                let spreadY = Double(try reader.read(12, field: "ObjectSpreadY")) / 4_095
                let spreadZ = Double(try reader.read(12, field: "ObjectSpreadZ")) / 4_095
                size = max(spreadX, max(spreadY, spreadZ))
            }
            _ = try reader.read(4, field: "ObjectDefinition decor reserved")
            let decorPrefix = try reader.read(2, field: "ObjectDecorCoefPrefix")
            let decorrelation: Double
            switch decorPrefix {
            case 0: decorrelation = 0
            case 1: decorrelation = 1
            case 2: decorrelation = Double(try reader.read(8, field: "ObjectDecorCoef")) / 255
            default: throw DTSError.malformed("reserved ObjectDecorCoefPrefix 3")
            }
            subBlocks.append(ParsedObjectSubBlock(
                gainDB: gainDB,
                position: AtmosPosition(x: 2 * x - 1, y: 1 - 2 * y, z: z),
                snap: snap,
                size: size,
                decorrelation: decorrelation
            ))
        }
        try reader.alignToByte(field: "ObjectDefinition AlignBits")
        let audioDescription = try reader.read(8, field: "object AudioDescription")
        if audioDescription & 0x80 != 0 {
            while try reader.read(8, field: "object AudioDescriptionText") != 0 {}
        }
        _ = try plex(&reader, startWidth: 8, field: "ObjectDefinition SubElementCount")
        // Child ObjectDefinitions are conditional alternates for specific
        // environments and are skipped via the parent element boundary.

        let activated = conditional == 0 || useCase == 0xff
        guard activated else { return nil }
        return ParsedObject(metaID: metaID, audioDataID: audioDataID, subBlocks: subBlocks)
    }

    private static func makeLayout(
        bedChannels: [ParsedBedChannel],
        objects: [ParsedObject]
    ) throws -> Layout {
        guard !bedChannels.isEmpty else {
            throw DTSError.malformed("IAB program has no activated bed")
        }
        var atmosBed: [AtmosBedChannel] = []
        var seenChannelIDs = Set<String>()
        for (index, channel) in bedChannels.enumerated() {
            guard seenChannelIDs.insert("\(channel.bedID):\(channel.channelID)").inserted else {
                throw DTSError.malformed("IAB bed repeats ChannelID \(channel.channelID)")
            }
            guard let mapping = speakerMapping(forChannelID: channel.channelID) else {
                throw DTSError.unsupported("IAB bed ChannelID 0x\(String(channel.channelID, radix: 16))")
            }
            atmosBed.append(AtmosBedChannel(
                dolbyName: mapping.label,
                elementID: index,
                audioChannelIndex: index,
                dtsSpeaker: mapping.speaker,
                bedID: channel.bedID
            ))
        }
        var objectIndexByMetaID: [Int: Int] = [:]
        var atmosObjects: [AtmosObjectChannel] = []
        for (index, object) in objects.enumerated() {
            guard objectIndexByMetaID.updateValue(index, forKey: object.metaID) == nil else {
                throw DTSError.malformed("IAB program repeats object MetaID \(object.metaID)")
            }
            atmosObjects.append(AtmosObjectChannel(
                elementID: bedChannels.count + index,
                audioChannelIndex: bedChannels.count + index
            ))
        }
        return Layout(
            bedChannelIDs: bedChannels.map(\.channelID),
            bedIdentities: bedChannels.map(\.bedID),
            objectMetaIDs: objects.map(\.metaID),
            objectIndexByMetaID: objectIndexByMetaID,
            bedChannels: atmosBed,
            objects: atmosObjects
        )
    }

    // MARK: - AudioData decoding

    private static func decodeAudioElement(
        bytes: Data,
        elementOffset: Int,
        isDLC: Bool,
        sampleCount: Int,
        bitDepthCode: Int,
        frameRateCode: Int
    ) throws -> [Int32] {
        var cursor = ByteCursor(bytes: bytes, offset: elementOffset)
        let elementID = try cursor.plex8()
        guard elementID == (isDLC ? 0x200 : 0x400) else {
            throw DTSError.malformed("AudioData element ID changed between parse and decode")
        }
        let elementSize = try cursor.plex8()
        let contentStart = cursor.offset
        guard contentStart + elementSize <= bytes.count else {
            throw DTSError.truncated(field: "AudioData element", bitOffset: contentStart * 8)
        }
        _ = try cursor.plex8() // AudioDataID, already directory-resolved

        if isDLC {
            return try IABDLCDecoder.decode(
                data: bytes,
                byteOffset: cursor.offset,
                byteLimit: contentStart + elementSize,
                sampleCount: sampleCount,
                frameRateCode: frameRateCode
            )
        }

        let bytesPerSample = bitDepthCode == 0 ? 2 : 3
        guard cursor.offset + sampleCount * bytesPerSample <= contentStart + elementSize else {
            throw DTSError.truncated(field: "AudioDataPCM samples", bitOffset: cursor.offset * 8)
        }
        var samples = [Int32](repeating: 0, count: sampleCount)
        bytes.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            var offset = cursor.offset
            if bytesPerSample == 3 {
                for index in 0..<sampleCount {
                    let value = UInt32(source[offset]) | UInt32(source[offset + 1]) << 8 | UInt32(source[offset + 2]) << 16
                    samples[index] = value & 0x800000 == 0 ? Int32(value) : Int32(Int64(value) - 0x1000000)
                    offset += 3
                }
            } else {
                // 16-bit masters are promoted to left-justified 24-bit samples.
                for index in 0..<sampleCount {
                    let value = UInt16(source[offset]) | UInt16(source[offset + 1]) << 8
                    samples[index] = Int32(Int16(bitPattern: value)) << 8
                    offset += 2
                }
            }
        }
        return samples
    }

    // MARK: - Field helpers

    /// ST 2098-2 section 5.2 Plex decoding on the shared MSB-first bit reader.
    static func plex(_ reader: inout BitReader, startWidth: Int, field: String) throws -> Int {
        var width = startWidth
        while true {
            let value = try reader.read(width, field: field)
            if value != (1 << width) - 1 {
                guard value <= UInt64(Int.max) else {
                    throw DTSError.valueOutOfRange(field: field, value: String(value))
                }
                return Int(value)
            }
            width *= 2
            guard width <= 32 else {
                throw DTSError.malformed("Plex escape chain for \(field) exceeds 32 bits")
            }
        }
    }

    /// ST 2098-2 section 5.4 DistanceXY: maps [2^(n-1)-1, 2^n-1] linearly onto [0,1].
    private static func distanceXY(_ code: Int, field: String) throws -> Double {
        guard code >= 32_767, code <= 65_535 else {
            throw DTSError.valueOutOfRange(field: field, value: String(code))
        }
        return Double(code - 32_767) / 32_768
    }

    private static func speakerMapping(
        forChannelID id: Int
    ) -> (label: String, speaker: DTSSpeakerPosition)? {
        // ST 2098-2 Table 19; labels use the Dolby bed names shared with DAMF.
        switch id {
        case 0x0: ("L", .left)
        case 0x2: ("C", .center)
        case 0x4: ("R", .right)
        case 0x5: ("Lss", .leftSideSurround)
        case 0x6: ("Ls", .leftSurround)
        case 0x7: ("Lrs", .leftRearSurround)
        case 0x8: ("Rrs", .rightRearSurround)
        case 0x9: ("Rss", .rightSideSurround)
        case 0xA: ("Rs", .rightSurround)
        case 0xB: ("Lts", .leftHeightSide)
        case 0xC: ("Rts", .rightHeightSide)
        case 0xD: ("LFE", .lfe1)
        default: nil
        }
    }

    /// ST 2098-2 Table 18 (48 kHz sample count per IAFrame).
    static func frameSampleCount(frameRateCode: Int) throws -> Int {
        switch frameRateCode {
        case 0x0: 2_000
        case 0x1: 1_920
        case 0x2: 1_600
        case 0x3: 1_000
        case 0x4: 960
        case 0x5: 800
        case 0x6: 500
        case 0x7: 480
        case 0x8: 400
        case 0x9: 2_002
        default: throw DTSError.malformed("reserved IAB frame rate code \(frameRateCode)")
        }
    }

    /// ST 2098-2 Table 23 (48 kHz samples per pan sub block, in stream order).
    static func panSubBlockSampleCounts(frameRateCode: Int) throws -> [Int] {
        switch frameRateCode {
        case 0x0: Array(repeating: 250, count: 8)
        case 0x1: Array(repeating: 240, count: 8)
        case 0x2: Array(repeating: 200, count: 8)
        case 0x3: Array(repeating: 250, count: 4)
        case 0x4: Array(repeating: 240, count: 4)
        case 0x5: Array(repeating: 200, count: 4)
        case 0x6: Array(repeating: 250, count: 2)
        case 0x7: Array(repeating: 240, count: 2)
        case 0x8: Array(repeating: 200, count: 2)
        case 0x9: [251, 250, 250, 250, 251, 250, 250, 250]
        default: throw DTSError.malformed("reserved IAB frame rate code \(frameRateCode)")
        }
    }

    private static func frameRate(code: Int) -> Double? {
        switch code {
        case 0x0: 24
        case 0x1: 25
        case 0x2: 30
        case 0x3: 48
        case 0x4: 50
        case 0x5: 60
        case 0x6: 96
        case 0x7: 100
        case 0x8: 120
        case 0x9: 24_000.0 / 1_001.0
        default: nil
        }
    }

    private static func fileByteCount(_ url: URL) throws -> UInt64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw DTSError.io("MXF size is unavailable")
            }
            return size.uint64Value
        } catch let error as DTSError {
            throw error
        } catch {
            throw DTSError.io("cannot inspect \(url.path): \(error.localizedDescription)")
        }
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

/// Byte-aligned Plex(8) cursor used on the audio decode path where every
/// field before the sample data occupies whole bytes.
struct ByteCursor {
    let bytes: Data
    var offset: Int

    mutating func plex8() throws -> Int {
        var width = 1
        while true {
            guard offset + width <= bytes.count else {
                throw DTSError.truncated(field: "Plex(8)", bitOffset: offset * 8)
            }
            var value = 0
            var allOnes = true
            for index in 0..<width {
                let byte = bytes[offset + index]
                value = (value << 8) | Int(byte)
                if byte != 0xff { allOnes = false }
            }
            offset += width
            if !allOnes { return value }
            width *= 2
            guard width <= 4 else {
                throw DTSError.malformed("Plex(8) escape chain exceeds 32 bits")
            }
        }
    }
}
