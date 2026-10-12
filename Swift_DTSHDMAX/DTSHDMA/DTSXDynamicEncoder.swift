import Foundation

public struct DTSXDynamicEncodingReport: Sendable, Equatable, Codable {
    public let layout: DTSXDynamicLayout
    public let dynamicObjectCount: Int
    public let reservedIMAXObjectCount: Int
    public let sourceSampleCount: Int
    public let accessUnitCount: Int
    public let minimumProgrammeGainQ30: Int64
    public let maximumInputCompositeMagnitude: Int64
    public let positionChangeCount: Int
    public let dynamicFoldCodes: [[Int]]
    public let segmentCounts: [String: Int]
    public let nativePrivatePCMVerified: Bool
    public let officialPlaybackQualified: Bool
    public let spatialAggregation: DTSXSpatialAggregationReport?
    public let deliveryArtifacts: DTSHDMADeliveryArtifactReport?
}

/// Constant carriers separate bed recovery from presentation motion. Official
/// decoders smooth changing fold rows; an AU-static public fold then leaves
/// impulses in the restored bed. Each row minimizes the energy-weighted error
/// of the programme's compatible image over the actual quantized Q15 table.
struct DTSXDynamicFoldPlan: Sendable {
    let codes: [[Int]]
    let gains: [[Int64]]
    init(source: DTSXDynamicPCMBuffer) {
        var rows: [[Int]] = []
        for object in source.dynamicPlanes.indices {
            var mass = 0.0
            var weighted = Array(repeating: 0.0, count: 8)
            for frame in source.positions.indices {
                let start = frame*512, end = min(start+512,source.sampleCount)
                var energy = 0.0
                for sample in start..<end {
                    let value = Double(source.dynamicPlanes[object][sample])
                    energy += value*value
                }
                guard energy > 0 else { continue }
                let image = source.positions[frame][object].foldCodes(for: source.layout)
                mass += energy
                for channel in 0..<8 { weighted[channel] += energy*Double(DTSXDynamicMetadata.gainQ15(image[channel])) }
            }
            let row = mass > 0 ? weighted.map { value in
                (0...61).min { abs(Double(DTSXDynamicMetadata.gainQ15($0))-value/mass)
                    < abs(Double(DTSXDynamicMetadata.gainQ15($1))-value/mass) }!
            } : source.positions[0][object].foldCodes(for: source.layout)
            rows.append(row)
        }
        codes = rows; gains = rows.map { $0.map(DTSXDynamicMetadata.gainQ15) }
    }
}

final class DTSXDynamicStreamSession: @unchecked Sendable {
    let source: DTSXDynamicPCMBuffer
    let mode: DTSEncodeMode
    let frameCount: Int
    private let lock = NSLock()
    private var completed: [Bool]
    private var partitions: [String: Int] = [:]
    private let silentStartup: Bool
    private let folds: DTSXDynamicFoldPlan
    init(source: DTSXDynamicPCMBuffer, mode: DTSEncodeMode, folds: DTSXDynamicFoldPlan) {
        self.source = source; self.mode = mode
        self.folds = folds
        frameCount = source.positions.count + 2
        completed = Array(repeating: false, count: frameCount)
        silentStartup = (source.fixedPlanes+source.dynamicPlanes).allSatisfy {
            $0.prefix(min(1024,source.sampleCount)).allSatisfy { $0 == 0 }
        }
    }
    func preferredPublicSegmentCount(at index: Int) -> Int? {
        if index < 2 { return 2 }
        if index < 4 && silentStartup { return 4 }
        let start = (index-2)*512, end = min(start+512,source.sampleCount)
        let privateFixed = Array(source.fixedPlanes[8..<source.fixedPlanes.count])
        if (privateFixed+source.dynamicPlanes).allSatisfy({ $0[start..<end].allSatisfy { $0 == 0 } }) { return 2 }
        return nil
    }
    func encodeFrame(at index: Int, plan: XLLSegmentationPlan) throws -> Data {
        guard completed.indices.contains(index) else { throw DTSError.invalidArgument("Object AU index") }
        let sourceIndex = max(0, index-2), start = (index-2) * 512
        func plane(_ values: [Int32]) -> [Int32] {
            guard start >= 0 else { return Array(repeating: 0, count: 512) }
            let end = min(start+512, source.sampleCount)
            return Array(values[start..<end]) + Array(repeating: 0, count: 512-(end-start))
        }
        let reserved = source.layout == .sevenOneFive ? [plane(source.fixedPlanes[12])] : []
        let heights = source.fixedPlanes[8..<12].map(plane)
        let audio = reserved + source.dynamicPlanes.map(plane) + heights
        let result = try DTSXDynamicPrivateFrame.encode(layout: source.layout, positions: source.positions[sourceIndex],
                                                       dynamicFoldCodes: folds.codes,
                                                       planes: audio, plan: plan, mode: mode)
        lock.lock(); defer { lock.unlock() }
        guard !completed[index] else { throw DTSError.malformed("Object private provider called twice for one AU") }
        completed[index] = true; partitions[String(plan.segmentCount), default: 0] += 1
        return result.data
    }
    func finish() throws -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        guard completed.allSatisfy({ $0 }) else { throw DTSError.malformed("Incomplete object stream") }
        return partitions
    }
}

/// Experimental native Core/ExSS/XLL object delivery. It requires separate
/// official-player and Bitstream Tools acceptance; a local PCM loop is not
/// evidence of a qualified DTS:X presentation.
public struct DTSXDynamicHDMAEncoder: Sendable {
    public let encodeMode: DTSEncodeMode
    public init(encodeMode: DTSEncodeMode = .auto) { self.encodeMode = encodeMode }

    /// Uses one measured programme gain across fixed planes, aggregates and
    /// exact stated folds, avoiding frame-local limiting and gain steps.
    public func condition(_ input: DTSXDynamicPCMBuffer) throws -> (DTSXDynamicPCMBuffer, Int64, Int64) {
        try condition(input, folds: DTSXDynamicFoldPlan(source: input))
    }

    private func condition(_ input: DTSXDynamicPCMBuffer, folds: DTSXDynamicFoldPlan) throws -> (DTSXDynamicPCMBuffer, Int64, Int64) {
        var maximum: Int64 = 1
        for sample in 0..<input.sampleCount {
            let fixed = input.fixedPlanes.map { Int64($0[sample]) }
            var bed = Array(fixed.prefix(8))
            do {
                let destinations = input.layout == .sevenOneFive ? [0,1,4,5] : [0,1,6,7]
                let gain = DTSXDynamicMetadata.gainQ15(input.layout == .sevenOneFive ? 61 : 55)
                for height in 0..<4 { bed[destinations[height]] += (fixed[height+8] * gain + 16384) >> 15 }
            }
            if input.layout == .sevenOneFive {
                for (channel, code) in [(0,46),(1,46),(2,58)] {
                    bed[channel] += (fixed[12] * DTSXDynamicMetadata.gainQ15(code) + 16384) >> 15
                }
            }
            var objectsMagnitude: Int64 = 0
            for object in input.dynamicPlanes.indices {
                let value = Int64(input.dynamicPlanes[object][sample]); objectsMagnitude += abs(value)
                let coefficients = folds.gains[object]
                for channel in 0..<8 { bed[channel] += (value * coefficients[channel] + 16384) >> 15 }
            }
            maximum = max(maximum, fixed.map { abs($0) }.max() ?? 0,
                          input.dynamicPlanes.map { abs(Int64($0[sample])) }.max() ?? 0,
                          bed.map { abs($0) }.max() ?? 0, abs(bed[4]+bed[6]), abs(bed[5]+bed[7]),
                          (fixed.map { abs($0) }.max() ?? 0) + objectsMagnitude)
        }
        let scale: Int64 = 1 << 30
        let limit: Int64 = 8_388_607 - DTS714RenderGuard.coreCodecErrorRecoveryReserve
        let gain = maximum <= limit ? scale : max(1, (limit-64) * scale / maximum)
        func conditioned(_ planes: [[Int32]]) -> [[Int32]] {
            gain == scale ? planes : planes.map { $0.map { Int32((Int64($0)*gain + (1 << 29)) >> 30) } }
        }
        return (try DTSXDynamicPCMBuffer(layout: input.layout, fixedPlanes: conditioned(input.fixedPlanes),
                                         dynamicPlanes: conditioned(input.dynamicPlanes), positions: input.positions,
                                         aggregation: input.aggregation), gain, maximum)
    }

    public func encode(source input: DTSXDynamicPCMBuffer, to output: URL, frameRate: DTSFrameRate,
                       stemsDirectory: URL? = nil, deliveryInput: DTSHDMADeliveryInput? = nil,
                       progress: ((Int, Int) -> Void)? = nil) throws -> DTSXDynamicEncodingReport {
        guard output.pathExtension.lowercased() == "dtshd" else { throw DTSError.invalidArgument("Object output requires .dtshd") }
        let folds = DTSXDynamicFoldPlan(source: input)
        let (source, gain, maximum) = try condition(input, folds: folds)
        if let stemsDirectory {
            try DTSXDynamicRenderer.writeStems(source, directory: stemsDirectory)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(folds.codes).write(to: stemsDirectory.appendingPathComponent("fold-codes.json"),options: .atomic)
        }
        var bed = Array(source.fixedPlanes.prefix(8))
        for sample in 0..<source.sampleCount {
            var values = bed.map { Int64($0[sample]) }
            do {
                let destinations = source.layout == .sevenOneFive ? [0,1,4,5] : [0,1,6,7]
                let coefficient = DTSXDynamicMetadata.gainQ15(source.layout == .sevenOneFive ? 61 : 55)
                for height in 0..<4 { values[destinations[height]] += (Int64(source.fixedPlanes[height+8][sample])*coefficient + 16384) >> 15 }
            }
            if source.layout == .sevenOneFive {
                for (channel, code) in [(0,46),(1,46),(2,58)] {
                    values[channel] += (Int64(source.fixedPlanes[12][sample])*DTSXDynamicMetadata.gainQ15(code) + 16384) >> 15
                }
            }
            for object in source.dynamicPlanes.indices {
                let coefficients = folds.gains[object], value = Int64(source.dynamicPlanes[object][sample])
                for channel in 0..<8 { values[channel] += (value * coefficients[channel] + 16384) >> 15 }
            }
            guard values.allSatisfy({ (-8_388_608...8_388_607).contains($0) }) else { throw DTSError.malformed("Object compatibility fold clipped") }
            for channel in 0..<8 { bed[channel][sample] = Int32(values[channel]) }
        }
        // PCMBuffer's WAVE order has rear before side; source planes use the
        // authoring order with side before rear.
        let pcm = try PCMBuffer(format: PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .sevenOne),
                                planes: [0,1,2,3,6,7,4,5].map { bed[$0] })
        if let stemsDirectory { try WaveFile.write(pcm, to: stemsDirectory.appendingPathComponent("CompatibilityBed.wav")) }
        let session = DTSXDynamicStreamSession(source: source, mode: encodeMode, folds: folds)
        let writer = try DTSHDFileContainer.StreamingWriter(outputURL: output, format: pcm.format,
                                                           sourceSampleCount: source.sampleCount, frameRate: frameRate)
        do {
            try DTSHDMAEncoder(configuration: DTSHDMAEncoderConfiguration(
                format: pcm.format, profile: .dtsHDMA, tailPolicy: .zeroPad,
                xllCodingMode: encodeMode.publicXLLCodingMode, officialHierarchyGrammarEnforced: true
            )).encodeDynamic(pcm, session: session, writingAccessUnitsTo: { try writer.append(accessUnit: $0) }, progress: progress)
            try writer.finish()
            let artifacts = try deliveryInput.map {
                try DTSHDMADeliveryArtifactWriter.writeCompleted(pcm: pcm,input: $0,outputURL: output,frameRate: frameRate)
            }
            var changes = 0
            for frame in 1..<source.positions.count {
                changes += zip(source.positions[frame-1], source.positions[frame]).filter { $0 != $1 }.count
            }
            return DTSXDynamicEncodingReport(layout: source.layout, dynamicObjectCount: source.layout.dynamicObjectCount,
                reservedIMAXObjectCount: source.layout.reservedIMAXObjectCount, sourceSampleCount: source.sampleCount,
                accessUnitCount: session.frameCount, minimumProgrammeGainQ30: gain,
                maximumInputCompositeMagnitude: maximum, positionChangeCount: changes,
                dynamicFoldCodes: folds.codes,
                segmentCounts: try session.finish(), nativePrivatePCMVerified: true, officialPlaybackQualified: false,
                spatialAggregation: source.aggregation, deliveryArtifacts: artifacts)
        } catch { writer.cancel(); throw error }
    }
}
