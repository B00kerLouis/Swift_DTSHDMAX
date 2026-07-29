import Foundation

/// Deterministic 7.1.4 PCM render stage for DTS:X authoring. It creates the
/// exact channel order consumed by the DTS:X profile, but does not serialize
/// object audio or metadata into the private XLL-X extension.
public enum DTS714Renderer {
    private struct ActiveObject {
        let objectIndex: Int
        let inputChannel: Int
        var gains: [(outputIndex: Int, q30: Int64)]
    }

    private static let q30: Int64 = 1 << 30

    public static func render(
        master: AtmosMaster,
        maximumSampleCount: Int? = nil,
        blockSampleCount: Int = 4_096,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> DTS714PCMBuffer {
        guard master.audioFormat.container != .iabMXF else {
            throw DTSError.invalidArgument("IAB masters render via render(iab:)")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: master.audioURL) }
        catch { throw DTSError.io("cannot open \(master.audioURL.path): \(error.localizedDescription)") }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: master.audioFormat.audioDataOffset) }
        catch { throw DTSError.io("cannot seek Atmos PCM: \(error.localizedDescription)") }
        return try render(
            master: master,
            maximumSampleCount: maximumSampleCount,
            blockSampleCount: blockSampleCount,
            progress: progress
        ) { byteCount in
            do { return try handle.read(upToCount: byteCount) ?? Data() }
            catch { throw DTSError.io("cannot read Atmos PCM: \(error.localizedDescription)") }
        }
    }

    public static func render(
        iab: IABMaster,
        maximumSampleCount: Int? = nil,
        blockSampleCount: Int = 4_096,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> DTS714PCMBuffer {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: iab.master.audioURL) }
        catch { throw DTSError.io("cannot open \(iab.master.audioURL.path): \(error.localizedDescription)") }
        defer { try? handle.close() }
        var frameIndex = 0
        var pending = Data()
        return try render(
            master: iab.master,
            maximumSampleCount: maximumSampleCount,
            blockSampleCount: blockSampleCount,
            progress: progress
        ) { byteCount in
            while pending.count < byteCount, frameIndex < iab.frames.count {
                pending.append(try IMFIABReader.decodeFrameAudio(iab: iab, frameIndex: frameIndex, handle: handle))
                frameIndex += 1
            }
            guard pending.count >= byteCount else { return pending }
            let block = Data(pending.prefix(byteCount))
            pending.removeFirst(byteCount)
            return block
        }
    }

    public static func writeMonoWaves(_ pcm: DTS714PCMBuffer, to directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DTSError.io("cannot create \(directory.path): \(error.localizedDescription)")
        }
        for (index, channel) in DTS714Channel.allCases.enumerated() {
            try WaveFile.writeMono24(pcm.planes[index], to: directory.appendingPathComponent("\(channel.rawValue).wav"))
        }
    }

    private static func render(
        master: AtmosMaster,
        maximumSampleCount: Int?,
        blockSampleCount: Int,
        progress: ((Int64, Int64) -> Void)?,
        readBlock: (Int) throws -> Data
    ) throws -> DTS714PCMBuffer {
        guard blockSampleCount > 0,
              master.audioFormat.sampleRate == DTS714PCMBuffer.sampleRate,
              master.audioFormat.bitDepth == DTS714PCMBuffer.bitDepth,
              master.audioFormat.sampleCount <= UInt64(Int.max) else {
            throw DTSError.unsupported("DTS:X 7.1.4 render requires 48 kHz packed 24-bit PCM")
        }
        if let maximumSampleCount, maximumSampleCount <= 0 {
            throw DTSError.invalidArgument("maximum DTS:X render sample count must be positive")
        }
        let sampleCount = min(
            Int(master.audioFormat.sampleCount),
            maximumSampleCount ?? Int(master.audioFormat.sampleCount)
        )
        let bytesPerFrame = master.audioFormat.bytesPerPacket
        guard bytesPerFrame == master.audioFormat.channelCount * 3 else {
            throw DTSError.unsupported("Atmos PCM is not packed 24-bit interleaved")
        }

        let bedRouting: [(inputChannel: Int, routes: [(outputIndex: Int, q30: Int64)])] = master.bedChannels.map { bed in
            let routes = DTS714ChannelMapper.routes(for: bed.dtsSpeaker).map {
                (DTS714Channel.allCases.firstIndex(of: $0.channel)!, $0.gainQ30)
            }
            return (bed.audioChannelIndex, routes)
        }
        let objectIndexByID = Dictionary(uniqueKeysWithValues: master.objects.enumerated().map { ($0.element.elementID, $0.offset) })
        var states = master.objects.map { AtmosObjectState(elementID: $0.elementID) }
        var activeObjects: [ActiveObject] = []
        var activePositions = Array(repeating: -1, count: master.objects.count)

        func updateActiveObject(_ objectIndex: Int) {
            let gains = objectGains(states[objectIndex])
            let position = activePositions[objectIndex]
            if gains.isEmpty {
                guard position >= 0 else { return }
                let last = activeObjects.count - 1
                if position != last {
                    activeObjects[position] = activeObjects[last]
                    activePositions[activeObjects[position].objectIndex] = position
                }
                activeObjects.removeLast()
                activePositions[objectIndex] = -1
            } else if position >= 0 {
                activeObjects[position].gains = gains
            } else {
                activePositions[objectIndex] = activeObjects.count
                activeObjects.append(ActiveObject(
                    objectIndex: objectIndex,
                    inputChannel: master.objects[objectIndex].audioChannelIndex,
                    gains: gains
                ))
            }
        }

        for index in states.indices { updateActiveObject(index) }
        let events = master.metadataEvents.compactMap { event -> (AtmosMetadataEvent, Int)? in
            guard let index = objectIndexByID[event.elementID] else { return nil }
            return (event, index)
        }
        var eventCursor = 0
        var output = Array(repeating: [Int32](repeating: 0, count: sampleCount), count: DTS714Channel.allCases.count)
        var accumulators = Array(repeating: Int64(0), count: DTS714Channel.allCases.count)

        var blockStart = 0
        while blockStart < sampleCount {
            let blockCount = min(blockSampleCount, sampleCount - blockStart)
            let bytes = try readBlock(blockCount * bytesPerFrame)
            guard bytes.count == blockCount * bytesPerFrame else {
                throw DTSError.truncated(field: "Atmos PCM block", bitOffset: bytes.count * 8)
            }
            try bytes.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    throw DTSError.malformed("Atmos PCM block has no bytes")
                }
                var sample = 0
                while sample < blockCount {
                    let absoluteSample = Int64(blockStart + sample)
                    while eventCursor < events.count, events[eventCursor].0.samplePosition <= absoluteSample {
                        let (event, index) = events[eventCursor]
                        states[index].apply(event)
                        updateActiveObject(index)
                        eventCursor += 1
                    }
                    var runEnd = blockCount
                    if eventCursor < events.count {
                        let next = events[eventCursor].0.samplePosition - Int64(blockStart)
                        if next < Int64(runEnd) { runEnd = Int(next) }
                    }
                    for localSample in sample..<runEnd {
                        for index in accumulators.indices { accumulators[index] = 0 }
                        let frame = base + localSample * bytesPerFrame
                        for (inputChannel, routes) in bedRouting {
                            let value = Int64(packed24(frame + inputChannel * 3))
                            for route in routes {
                                accumulators[route.outputIndex] += value * route.q30
                            }
                        }
                        for object in activeObjects {
                            let value = Int64(packed24(frame + object.inputChannel * 3))
                            for gain in object.gains {
                                accumulators[gain.outputIndex] += value * gain.q30
                            }
                        }
                        let outputSample = blockStart + localSample
                        for index in output.indices {
                            output[index][outputSample] = saturate24(roundQ30(accumulators[index]))
                        }
                    }
                    sample = runEnd
                }
            }
            blockStart += blockCount
            progress?(Int64(blockStart), Int64(sampleCount))
        }
        return try DTS714PCMBuffer(planes: output)
    }

    private static func objectGains(_ state: AtmosObjectState) -> [(outputIndex: Int, q30: Int64)] {
        DTS714VBAPPanner.gains(for: state)
    }

    @inline(__always) private static func roundQ30(_ value: Int64) -> Int64 {
        // The reference renderer rounds to nearest but resolves an exact
        // half-LSB toward zero. For example, 3328 * (511/512) becomes 3321,
        // while the former half-away rule produced 3322.
        let bias = (q30 >> 1) - 1
        return value >= 0 ? (value + bias) >> 30 : -((-value + bias) >> 30)
    }

    @inline(__always) private static func saturate24(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }

    @inline(__always) private static func packed24(_ pointer: UnsafePointer<UInt8>) -> Int32 {
        let raw = UInt32(pointer[0]) | (UInt32(pointer[1]) << 8) | (UInt32(pointer[2]) << 16)
        return (raw & 0x0080_0000) == 0 ? Int32(raw) : Int32(Int64(raw) - 0x0100_0000)
    }
}

private extension DTS714Channel {
    var rawValueIndex: Int { DTS714Channel.allCases.firstIndex(of: self)! }
}
