import Foundation

/// Deterministic renderer from a DAMF Atmos scene to a DTS channel bed.
///
/// Every bed channel and every object PCM plane is read from the master, and
/// object positions/gains follow the sparse metadata events at exact sample
/// boundaries (all supplied masters use rampLength 0, i.e. stepped automation).
/// Panning is equal-power over the DTS 7.1 speaker grid; the height coordinate
/// is projected onto the listener plane and height bed channels fold into the
/// side/rear surround pair at -3.0103 dB each. Gains are quantized to Q30 once
/// per state change so the integer accumulation is exactly reproducible.
///
/// This is a neutral reference render for encoder verification, not Dolby's
/// certified spatial coder.
public enum AtmosToDTSRenderer {
    /// WAVE 7.1 plane order produced: L R C LFE Lsr Rsr Lss Rss.
    private enum Plane: Int, CaseIterable {
        case left = 0, right, center, lfe, leftRear, rightRear, leftSide, rightSide
    }

    private struct ActiveObject {
        let objectIndex: Int
        let channel: Int
        var gains: [(Plane, Int64)]
    }

    private static let q30: Int64 = 1 << 30
    /// round(2^30 / sqrt(2)) - the same -3.0103 dB constant as DTSBedRenderer.
    private static let q30HalfPower: Int64 = 759_250_125

    public static func renderSevenOne(
        master: AtmosMaster,
        blockSampleCount: Int = 4096,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> PCMBuffer {
        guard master.audioFormat.container != .iabMXF else {
            throw DTSError.invalidArgument("IAB masters render via renderSevenOne(iab:)")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: master.audioURL) }
        catch { throw DTSError.io("cannot open \(master.audioURL.path): \(error.localizedDescription)") }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: master.audioFormat.audioDataOffset) }
        catch { throw DTSError.io("cannot seek DAMF audio: \(error.localizedDescription)") }
        return try render(
            master: master,
            blockSampleCount: blockSampleCount,
            progress: progress
        ) { byteCount in
            do { return try handle.read(upToCount: byteCount) ?? Data() }
            catch { throw DTSError.io("cannot read Atmos audio block: \(error.localizedDescription)") }
        }
    }

    /// Renders an IMF IAB master by decoding each IAFrame's AudioDataPCM/DLC
    /// elements into interleaved plane frames on the fly.
    public static func renderSevenOne(
        iab: IABMaster,
        blockSampleCount: Int = 4096,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> PCMBuffer {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: iab.master.audioURL) }
        catch { throw DTSError.io("cannot open \(iab.master.audioURL.path): \(error.localizedDescription)") }
        defer { try? handle.close() }
        var frameIndex = 0
        var pending = Data()
        return try render(
            master: iab.master,
            blockSampleCount: blockSampleCount,
            progress: progress
        ) { byteCount in
            while pending.count < byteCount, frameIndex < iab.frames.count {
                pending.append(try IMFIABReader.decodeFrameAudio(
                    iab: iab,
                    frameIndex: frameIndex,
                    handle: handle
                ))
                frameIndex += 1
            }
            guard pending.count >= byteCount else { return pending }
            let block = Data(pending.prefix(byteCount))
            pending.removeFirst(byteCount)
            return block
        }
    }

    private static func render(
        master: AtmosMaster,
        blockSampleCount: Int,
        progress: ((Int64, Int64) -> Void)?,
        readBlock: (Int) throws -> Data
    ) throws -> PCMBuffer {
        guard master.audioFormat.sampleRate == 48_000, master.audioFormat.bitDepth == 24 else {
            throw DTSError.unsupported("Atmos render requires a 48 kHz packed 24-bit master")
        }
        guard master.audioFormat.sampleCount <= UInt64(Int.max) else {
            throw DTSError.valueOutOfRange(field: "DAMF sample count", value: "\(master.audioFormat.sampleCount)")
        }
        let totalSamples = Int(master.audioFormat.sampleCount)
        let channelCount = master.audioFormat.channelCount
        let bytesPerFrame = master.audioFormat.bytesPerPacket
        guard bytesPerFrame == channelCount * 3 else {
            throw DTSError.unsupported("DAMF audio is not packed 24-bit interleaved")
        }

        // Static bed routing: each bed channel feeds one or two output planes.
        var bedRouting: [(channel: Int, targets: [(Plane, Int64)])] = []
        for bed in master.bedChannels {
            let targets: [(Plane, Int64)]
            switch bed.dtsSpeaker {
            case .left: targets = [(.left, q30)]
            case .right: targets = [(.right, q30)]
            case .center: targets = [(.center, q30)]
            case .lfe1: targets = [(.lfe, q30)]
            case .leftSideSurround: targets = [(.leftSide, q30)]
            case .rightSideSurround: targets = [(.rightSide, q30)]
            case .leftRearSurround: targets = [(.leftRear, q30)]
            case .rightRearSurround: targets = [(.rightRear, q30)]
            case .leftSurround: targets = [(.leftSide, q30)]
            case .rightSurround: targets = [(.rightSide, q30)]
            case .centerSurround: targets = [(.leftRear, q30HalfPower), (.rightRear, q30HalfPower)]
            case .leftHeightSide: targets = [(.leftSide, q30HalfPower), (.leftRear, q30HalfPower)]
            case .rightHeightSide: targets = [(.rightSide, q30HalfPower), (.rightRear, q30HalfPower)]
            }
            bedRouting.append((bed.audioChannelIndex, targets))
        }

        // Object state machine over the sorted sparse event list.
        let objectIndexByID = Dictionary(
            uniqueKeysWithValues: master.objects.enumerated().map { ($0.element.elementID, $0.offset) }
        )
        var states = master.objects.map { AtmosObjectState(elementID: $0.elementID) }
        var activeObjects: [ActiveObject] = []
        var activeObjectPositions = Array(repeating: -1, count: master.objects.count)

        func refreshGains(for objectIndex: Int) {
            let gains = panGains(for: states[objectIndex])
            let activePosition = activeObjectPositions[objectIndex]
            if gains.isEmpty {
                guard activePosition >= 0 else { return }
                let lastPosition = activeObjects.count - 1
                if activePosition != lastPosition {
                    let moved = activeObjects[lastPosition]
                    activeObjects[activePosition] = moved
                    activeObjectPositions[moved.objectIndex] = activePosition
                }
                activeObjects.removeLast()
                activeObjectPositions[objectIndex] = -1
            } else if activePosition >= 0 {
                activeObjects[activePosition].gains = gains
            } else {
                activeObjectPositions[objectIndex] = activeObjects.count
                activeObjects.append(ActiveObject(
                    objectIndex: objectIndex,
                    channel: master.objects[objectIndex].audioChannelIndex,
                    gains: gains
                ))
            }
        }

        for index in states.indices { refreshGains(for: index) }
        let events = master.metadataEvents.compactMap { event -> (AtmosMetadataEvent, Int)? in
            guard let objectIndex = objectIndexByID[event.elementID] else { return nil }
            return (event, objectIndex)
        }
        var eventCursor = 0

        var output = Array(
            repeating: [Int32](repeating: 0, count: totalSamples),
            count: Plane.allCases.count
        )

        var accumulators = Array(repeating: Int64(0), count: Plane.allCases.count)
        var blockStart = 0
        while blockStart < totalSamples {
            let blockCount = min(blockSampleCount, totalSamples - blockStart)
            let byteCount = blockCount * bytesPerFrame
            try autoreleasepool {
                let bytes = try readBlock(byteCount)
                guard bytes.count == byteCount else {
                    throw DTSError.truncated(field: "Atmos audio block", bitOffset: bytes.count * 8)
                }

                bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let base = raw.bindMemory(to: UInt8.self).baseAddress!
                    var sample = 0
                    while sample < blockCount {
                        let absoluteSample = Int64(blockStart + sample)
                        // Apply every state change that lands exactly here.
                        while eventCursor < events.count,
                              events[eventCursor].0.samplePosition <= absoluteSample {
                            let (event, objectIndex) = events[eventCursor]
                            states[objectIndex].apply(event)
                            refreshGains(for: objectIndex)
                            eventCursor += 1
                        }
                        // Samples until the next state change or block end.
                        var runEnd = blockCount
                        if eventCursor < events.count {
                            let nextEvent = events[eventCursor].0.samplePosition - Int64(blockStart)
                            if nextEvent < Int64(runEnd) { runEnd = Int(nextEvent) }
                        }

                        for index in sample..<runEnd {
                            let frame = base + index * bytesPerFrame
                            for accumulator in accumulators.indices { accumulators[accumulator] = 0 }

                            for (channel, targets) in bedRouting {
                                let value = Int64(packed24(frame + channel * 3))
                                for (plane, gain) in targets {
                                    accumulators[plane.rawValue] += value * gain
                                }
                            }
                            for object in activeObjects {
                                let value = Int64(packed24(frame + object.channel * 3))
                                for (plane, gain) in object.gains {
                                    accumulators[plane.rawValue] += value * gain
                                }
                            }
                            let outputSample = blockStart + index
                            for plane in accumulators.indices {
                                let product = accumulators[plane]
                                let rounded = product >= 0
                                    ? (product + (q30 >> 1)) >> 30
                                    : -((-product + (q30 >> 1)) >> 30)
                                output[plane][outputSample] = Int32(
                                    min(Int64(8_388_607), max(Int64(-8_388_608), rounded))
                                )
                            }
                        }
                        sample = runEnd
                    }
                }
            }
            blockStart += blockCount
            progress?(Int64(blockStart), Int64(totalSamples))
        }

        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .sevenOne)
        return try PCMBuffer(format: format, planes: output)
    }

    /// Equal-power pan of one object state onto the 7.1 grid. Returns Q30
    /// (plane, gain) pairs; inactive or silent objects return an empty list.
    private static func panGains(for state: AtmosObjectState) -> [(Plane, Int64)] {
        guard state.active, let position = state.position else { return [] }
        let linearGain = pow(10.0, state.gain / 20.0)
        guard linearGain > 0 else { return [] }

        let x = min(1.0, max(-1.0, position.x))
        let y = min(1.0, max(-1.0, position.y))

        // Row crossfade: front (y=1) / side (y=0) / rear (y=-1).
        let front = y >= 0 ? (y).squareRoot() : 0
        let side = y >= 0 ? (1 - y).squareRoot() : (1 + y).squareRoot()
        let rear = y >= 0 ? 0 : (-y).squareRoot()

        // Front row pans L-C-R; side and rear rows pan pairwise.
        var weights = Array(repeating: 0.0, count: Plane.allCases.count)
        if front > 0 {
            if x <= 0 {
                weights[Plane.left.rawValue] += front * (-x).squareRoot()
                weights[Plane.center.rawValue] += front * (1 + x).squareRoot()
            } else {
                weights[Plane.center.rawValue] += front * (1 - x).squareRoot()
                weights[Plane.right.rawValue] += front * x.squareRoot()
            }
        }
        let pairLeft = ((1 - x) / 2).squareRoot()
        let pairRight = ((1 + x) / 2).squareRoot()
        if side > 0 {
            weights[Plane.leftSide.rawValue] += side * pairLeft
            weights[Plane.rightSide.rawValue] += side * pairRight
        }
        if rear > 0 {
            weights[Plane.leftRear.rawValue] += rear * pairLeft
            weights[Plane.rightRear.rawValue] += rear * pairRight
        }

        if state.snap {
            // Snap moves all energy to the strongest speaker.
            var best = 0
            for plane in weights.indices where weights[plane] > weights[best] { best = plane }
            for plane in weights.indices { weights[plane] = plane == best ? 1 : 0 }
        }

        var gains: [(Plane, Int64)] = []
        for plane in Plane.allCases {
            let quantized = Int64((weights[plane.rawValue] * linearGain * Double(q30)).rounded())
            if quantized != 0 { gains.append((plane, quantized)) }
        }
        return gains
    }

    private static func packed24(_ pointer: UnsafePointer<UInt8>) -> Int32 {
        let raw = UInt32(pointer[0]) | (UInt32(pointer[1]) << 8) | (UInt32(pointer[2]) << 16)
        return (raw & 0x0080_0000) == 0 ? Int32(raw) : Int32(Int64(raw) - 0x0100_0000)
    }
}
