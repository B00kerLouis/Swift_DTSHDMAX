import Foundation

public struct AtmosObjectState: Codable, Equatable, Sendable {
    public let elementID: Int
    public var active: Bool
    public var position: AtmosPosition?
    public var size: Double
    public var decorrelation: Double
    public var importance: Double
    public var gain: Double
    public var snap: Bool
    public var elevation: Bool
    public var zones: String

    public init(elementID: Int) {
        self.elementID = elementID
        active = false
        position = nil
        size = 0
        decorrelation = 0
        importance = 1
        gain = 0
        snap = false
        elevation = true
        zones = "all"
    }

    mutating func apply(_ event: AtmosMetadataEvent) {
        if let value = event.active { active = value }
        if let value = event.position { position = value }
        if let value = event.size { size = value }
        if let value = event.decorrelation { decorrelation = value }
        if let value = event.importance { importance = value }
        if let value = event.gain { gain = value }
        if let value = event.snap { snap = value }
        if let value = event.elevation { elevation = value }
        if let value = event.zones { zones = value }
    }
}

public struct AtmosSceneBlock: Equatable, Sendable {
    public let sampleRange: Range<Int64>
    public let bedPlanes: [DTSSpeakerPosition: [Int32]]
    public let objectPlanes: [Int: [Int32]]
    public let objectStatesAtStart: [Int: AtmosObjectState]
    public let metadataEvents: [AtmosMetadataEvent]
}

public struct AtmosPositionedObjectSummary: Codable, Equatable, Sendable {
    public let elementID: Int
    public let audioChannelIndex: Int
    public let position: AtmosPosition
}

public struct AtmosObjectSampleSummary: Codable, Equatable, Sendable {
    public let elementID: Int
    public let audioChannelIndex: Int
    public let firstSample: Int32
    public let active: Bool
    public let position: AtmosPosition?
    public let gain: Double
    public let size: Double
    public let snap: Bool
    public let elevation: Bool
}

public struct AtmosSceneBlockSummary: Codable, Equatable, Sendable {
    public let sampleStart: Int64
    public let sampleCount: Int
    public let bedChannelCount: Int
    public let objectChannelCount: Int
    public let activeObjectCount: Int
    public let positionedObjectCount: Int
    public let metadataUpdateCount: Int
    public let bedPeakAbsolute: Int64
    public let objectPeakAbsolute: Int64
    public let firstPositionedObjects: [AtmosPositionedObjectSummary]
    public let nonzeroObjectsAtFirstSample: [AtmosObjectSampleSummary]

    public init(master: AtmosMaster, block: AtmosSceneBlock) {
        sampleStart = block.sampleRange.lowerBound
        sampleCount = Int(block.sampleRange.count)
        bedChannelCount = block.bedPlanes.count
        objectChannelCount = block.objectPlanes.count
        activeObjectCount = block.objectStatesAtStart.values.lazy.filter(\.active).count
        positionedObjectCount = block.objectStatesAtStart.values.lazy.filter { $0.position != nil }.count
        metadataUpdateCount = block.metadataEvents.count
        bedPeakAbsolute = Self.peak(block.bedPlanes.values)
        objectPeakAbsolute = Self.peak(block.objectPlanes.values)
        let indexByID = Dictionary(uniqueKeysWithValues: master.objects.map { ($0.elementID, $0.audioChannelIndex) })
        firstPositionedObjects = block.objectStatesAtStart.values
            .filter { $0.active && $0.position != nil }
            .sorted { $0.elementID < $1.elementID }
            .prefix(8)
            .map {
                AtmosPositionedObjectSummary(
                    elementID: $0.elementID,
                    audioChannelIndex: indexByID[$0.elementID]!,
                    position: $0.position!
                )
            }
        nonzeroObjectsAtFirstSample = block.objectPlanes.compactMap { elementID, samples in
            guard let firstSample = samples.first, firstSample != 0,
                  let state = block.objectStatesAtStart[elementID],
                  let audioChannelIndex = indexByID[elementID] else {
                return nil
            }
            return AtmosObjectSampleSummary(
                elementID: elementID,
                audioChannelIndex: audioChannelIndex,
                firstSample: firstSample,
                active: state.active,
                position: state.position,
                gain: state.gain,
                size: state.size,
                snap: state.snap,
                elevation: state.elevation
            )
        }.sorted { $0.elementID < $1.elementID }
    }

    private static func peak<S: Sequence>(_ planes: S) -> Int64 where S.Element == [Int32] {
        planes.lazy.flatMap { $0 }.reduce(0) { peak, sample in
            max(peak, Swift.abs(Int64(sample)))
        }
    }
}

/// Reads synchronized PCM and object state directly from a DAMF master.
public enum AtmosSceneReader {
    public static func readBlock(
        master: AtmosMaster,
        sampleStart: Int64,
        sampleCount: Int = 512
    ) throws -> AtmosSceneBlock {
        guard sampleStart >= 0, sampleCount > 0 else {
            throw DTSError.invalidArgument("DAMF block range must be positive")
        }
        guard master.audioFormat.container != .iabMXF else {
            throw DTSError.unsupported(
                "IAB masters store per-frame audio elements; block reads require a CAF/WAVE master"
            )
        }
        let sampleEnd = sampleStart + Int64(sampleCount)
        guard UInt64(sampleEnd) <= master.audioFormat.sampleCount else {
            throw DTSError.valueOutOfRange(
                field: "DAMF audio block",
                value: "\(sampleStart)..<\(sampleEnd)"
            )
        }
        let bytesPerFrame = master.audioFormat.bytesPerPacket
        let byteOffset = master.audioFormat.audioDataOffset + UInt64(sampleStart) * UInt64(bytesPerFrame)
        let byteCount = sampleCount * bytesPerFrame
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: master.audioURL) }
        catch { throw DTSError.io("cannot open \(master.audioURL.path): \(error.localizedDescription)") }
        defer { try? handle.close() }
        let bytes: Data
        do {
            try handle.seek(toOffset: byteOffset)
            bytes = try handle.read(upToCount: byteCount) ?? Data()
        } catch {
            throw DTSError.io("cannot read DAMF audio block: \(error.localizedDescription)")
        }
        guard bytes.count == byteCount else {
            throw DTSError.truncated(field: "DAMF audio block", bitOffset: bytes.count * 8)
        }

        var allPlanes = Array(
            repeating: [Int32](),
            count: master.audioFormat.channelCount
        )
        for channel in allPlanes.indices { allPlanes[channel].reserveCapacity(sampleCount) }
        var cursor = 0
        for _ in 0..<sampleCount {
            for channel in allPlanes.indices {
                let raw = UInt32(bytes[cursor])
                    | (UInt32(bytes[cursor + 1]) << 8)
                    | (UInt32(bytes[cursor + 2]) << 16)
                let sample = (raw & 0x0080_0000) == 0
                    ? Int32(raw)
                    : Int32(Int64(raw) - 0x0100_0000)
                allPlanes[channel].append(sample)
                cursor += 3
            }
        }
        var bedPlanes: [DTSSpeakerPosition: [Int32]] = [:]
        for bed in master.bedChannels { bedPlanes[bed.dtsSpeaker] = allPlanes[bed.audioChannelIndex] }
        var objectPlanes: [Int: [Int32]] = [:]
        for object in master.objects { objectPlanes[object.elementID] = allPlanes[object.audioChannelIndex] }

        let objectIDs = Set(master.objects.map(\.elementID))
        var states = Dictionary(uniqueKeysWithValues: objectIDs.map { ($0, AtmosObjectState(elementID: $0)) })
        var updates: [AtmosMetadataEvent] = []
        for event in master.metadataEvents where objectIDs.contains(event.elementID) {
            if event.samplePosition <= sampleStart { states[event.elementID]!.apply(event) }
            if event.samplePosition >= sampleStart, event.samplePosition < sampleEnd { updates.append(event) }
            if event.samplePosition >= sampleEnd { break }
        }
        return AtmosSceneBlock(
            sampleRange: sampleStart..<sampleEnd,
            bedPlanes: bedPlanes,
            objectPlanes: objectPlanes,
            objectStatesAtStart: states,
            metadataEvents: updates
        )
    }
}
