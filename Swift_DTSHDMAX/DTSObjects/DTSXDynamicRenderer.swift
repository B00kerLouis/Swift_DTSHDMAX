import Foundation

/// Fixed feeds, moving aggregate PCM and one position per 512-sample AU.
/// Aggregation is a spatial reduction; losslessness applies to these planes,
/// rather than to the original IAB object tracks.
public struct DTSXDynamicPCMBuffer: Sendable {
    public let layout: DTSXDynamicLayout
    public let fixedPlanes: [[Int32]]
    public let dynamicPlanes: [[Int32]]
    public let positions: [[DTSXObjectPosition]]
    public let aggregation: DTSXSpatialAggregationReport?
    public var sampleCount: Int { fixedPlanes.first?.count ?? 0 }

    public init(layout: DTSXDynamicLayout, fixedPlanes: [[Int32]], dynamicPlanes: [[Int32]],
                positions: [[DTSXObjectPosition]], aggregation: DTSXSpatialAggregationReport? = nil) throws {
        let count = fixedPlanes.first?.count ?? 0
        guard count > 0, fixedPlanes.count == layout.fixedPlaneCount,
              dynamicPlanes.count == layout.dynamicObjectCount,
              (fixedPlanes + dynamicPlanes).allSatisfy({ $0.count == count }),
              positions.count == (count + 511) / 512,
              positions.allSatisfy({ $0.count == layout.dynamicObjectCount }) else {
            throw DTSError.invalidArgument("Fixed/dynamic PCM dimensions or AU positions do not match the layout")
        }
        self.layout = layout; self.fixedPlanes = fixedPlanes
        self.dynamicPlanes = dynamicPlanes; self.positions = positions; self.aggregation = aggregation
    }
}

/// Invocation-local, warm-started spatial clusters. Source membership survives
/// power changes; a different instantaneous leader cannot permute live slots.
/// Uncovered images remain in the fixed residual while a carrier moves to them.
struct DTSXSpatialAggregator {
    private struct Source {
        var point: AtmosPosition
        var distance: Double
        var energy: Double
        var slot: Int
        var missed = 0
    }
    private var sources: [Int: Source] = [:]
    private var initialized: [Bool]
    private(set) var centres: [AtmosPosition]
    private(set) var distances: [Double]
    // Six degrees per 512 samples permits fast authored motion while preventing
    // a newly dominant image from teleporting a still-audible carrier.
    static let maximumAngularStepDegrees = 6.0

    init(count: Int) {
        centres = (0..<count).map { index in
            let angle = Double(index)*2 * .pi/Double(count)
            return Self.unit(AtmosPosition(x: sin(angle),y: cos(angle),z: 0.5))
        }
        initialized = Array(repeating: false,count: count)
        distances = Array(repeating: 1,count: count)
    }
    static func distance(_ a: AtmosPosition, _ b: AtmosPosition) -> Double {
        pow((a.x-b.x)/2,2)+pow((a.y-b.y)/2,2)+pow(a.z-b.z,2)
    }
    private static func unit(_ p: AtmosPosition) -> AtmosPosition {
        let norm = sqrt(p.x*p.x+p.y*p.y+p.z*p.z)
        return norm > 1e-12 ? AtmosPosition(x: p.x/norm,y: p.y/norm,z: p.z/norm) : AtmosPosition(x: 0,y: 1,z: 0)
    }
    private static func move(_ from: AtmosPosition, to: AtmosPosition) -> AtmosPosition {
        let a = unit(from), b = unit(to)
        let dot = min(1,max(-1,a.x*b.x+a.y*b.y+a.z*b.z))
        let angle = acos(dot), step = maximumAngularStepDegrees * .pi/180
        guard angle > step else { return b }
        // The tangent is deterministic even for antipodal targets. Choosing
        // the upper arc keeps all emitted elevation codes in the legal dome.
        var tangent = AtmosPosition(x: b.x-dot*a.x,y: b.y-dot*a.y,z: b.z-dot*a.z)
        if sqrt(tangent.x*tangent.x+tangent.y*tangent.y+tangent.z*tangent.z) < 1e-10 {
            tangent = AtmosPosition(x: -a.z*a.x,y: -a.z*a.y,z: 1-a.z*a.z)
        }
        tangent = unit(tangent)
        return unit(AtmosPosition(x: a.x*cos(step)+tangent.x*sin(step),
                                 y: a.y*cos(step)+tangent.y*sin(step),
                                 z: max(0,a.z*cos(step)+tangent.z*sin(step))))
    }
    mutating func update(points: [AtmosPosition], energy: [Double], sourceIDs: [Int]? = nil,
                         sourceDistances: [Double]? = nil) -> [Int] {
        let identities = sourceIDs ?? Array(points.indices)
        let radial = sourceDistances ?? Array(repeating: 1,count: points.count)
        precondition(points.count == energy.count && identities.count == points.count && radial.count == points.count)
        let live = Set(points.indices.filter { energy[$0] > 0 }.map { identities[$0] })
        for id in Array(sources.keys) where !live.contains(id) {
            sources[id]!.energy *= 0.9; sources[id]!.missed += 1
            if sources[id]!.missed > 32 { sources.removeValue(forKey: id) }
        }
        for i in points.indices where energy[i] > 0 {
            let previous = sources[identities[i]]
            let weight = previous.map { $0.energy+0.25*(energy[i]-$0.energy) } ?? energy[i]
            sources[identities[i]] = Source(point: Self.unit(points[i]),distance: radial[i],energy: weight,
                                            slot: previous?.slot ?? -1)
        }
        guard !live.isEmpty else { return Array(repeating: -1,count: points.count) }
        let ids = sources.keys.sorted()
        var next = centres
        var occupied = Array(repeating: false,count: centres.count)
        // Follow the existing members before refining the partition. Seeding
        // anew from each AU's loudest source destroys this correspondence.
        func centroid(_ members: [Int]) -> AtmosPosition {
            var x = 0.0,y = 0.0,z = 0.0
            for id in members {
                let source = sources[id]!
                x += source.energy*source.point.x; y += source.energy*source.point.y; z += source.energy*source.point.z
            }
            return Self.unit(AtmosPosition(x: x,y: y,z: z))
        }
        for slot in centres.indices {
            let members = ids.filter { sources[$0]!.slot == slot }
            if !members.isEmpty { next[slot] = centroid(members); occupied[slot] = true }
        }
        var seeds = Set<Int>()
        for slot in centres.indices where !occupied[slot] {
            let candidates = ids.filter { sources[$0]!.slot < 0 && !seeds.contains($0) }
            let best = candidates.max { first,second in
                func score(_ id: Int) -> Double {
                    let source = sources[id]!
                    let coverage = next.indices.filter { occupied[$0] }.map { Self.distance(source.point,next[$0]) }.min() ?? 1
                    return source.energy*coverage
                }
                let a = score(first),b = score(second)
                return a == b ? first > second : a < b
            }
            if let best { next[slot] = sources[best]!.point; occupied[slot] = true; seeds.insert(best) }
        }
        func nearest(_ id: Int) -> Int {
            let source = sources[id]!
            return next.indices.filter { occupied[$0] }.min {
                // Small membership hysteresis removes partition-boundary
                // chatter without preventing a source from changing cluster.
                let a = Self.distance(source.point,next[$0])+($0 == source.slot ? 0 : 0.02)
                let b = Self.distance(source.point,next[$1])+($1 == source.slot ? 0 : 0.02)
                return a == b ? $0 < $1 : a < b
            }!
        }
        for _ in 0..<6 {
            let assignment = Dictionary(uniqueKeysWithValues: ids.map { ($0,nearest($0)) })
            for slot in next.indices where occupied[slot] {
                let members = ids.filter { assignment[$0] == slot }
                if !members.isEmpty { next[slot] = centroid(members) }
            }
        }
        for id in ids { sources[id]!.slot = nearest(id) }
        for slot in centres.indices where occupied[slot] {
            centres[slot] = initialized[slot] ? Self.move(centres[slot],to: next[slot]) : next[slot]
            let members = ids.filter { sources[$0]!.slot == slot }
            let mass = members.reduce(0.0) { $0+sources[$1]!.energy }
            if mass > 0 { distances[slot] = members.reduce(0.0) { $0+sources[$1]!.energy*sources[$1]!.distance }/mass }
        }
        // Even an unoccupied column can participate in the nonnegative fit.
        // Once emitted alongside audible PCM, it must obey the same motion
        // bound when it first acquires cluster members.
        initialized = Array(repeating: true,count: centres.count)
        return points.indices.map { energy[$0] > 0 ? sources[identities[$0]]!.slot : -1 }
    }
}

public enum DTSXDynamicRenderer {
    /// IAB essence stays on external storage. Only one decoded IAB frame plus
    /// one 512-sample work block is retained alongside the output planes.
    /// IMAX TFC is rendered by its own established gain state and removed
    /// from the images fitted to the four moving slots. It never receives a
    /// cluster identity or moving metadata.
    public static func render(iab: IABMaster, layout: DTSXDynamicLayout,
                              maximumSampleCount: Int? = nil,
                              progress: ((Int, Int) -> Void)? = nil) throws -> DTSXDynamicPCMBuffer {
        let handle = try FileHandle(forReadingFrom: iab.master.audioURL)
        defer { try? handle.close() }
        var pending = Data(), frame = 0
        return try render(master: iab.master, layout: layout, maximumSampleCount: maximumSampleCount,
                          progress: progress) { byteCount in
            while pending.count < byteCount && frame < iab.frames.count {
                pending.append(try IMFIABReader.decodeFrameAudio(iab: iab, frameIndex: frame, handle: handle)); frame += 1
            }
            let bytes = Data(pending.prefix(byteCount)); pending.removeFirst(bytes.count)
            return bytes
        }
    }

    /// DAMF/ADM reuse the same local gain and aggregation state as IAB. Only
    /// the bounded input adapter differs; no channelbase renderer is invoked.
    public static func render(master: AtmosMaster, layout: DTSXDynamicLayout,
                              maximumSampleCount: Int? = nil,
                              progress: ((Int, Int) -> Void)? = nil) throws -> DTSXDynamicPCMBuffer {
        guard master.audioFormat.container != .iabMXF else {
            throw DTSError.invalidArgument("IAB masters render via render(iab:)")
        }
        let handle = try FileHandle(forReadingFrom: master.audioURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: master.audioFormat.audioDataOffset)
        return try render(master: master,layout: layout,maximumSampleCount: maximumSampleCount,
                          progress: progress) { try handle.read(upToCount: $0) ?? Data() }
    }

    private static func render(master: AtmosMaster, layout: DTSXDynamicLayout,
                               maximumSampleCount: Int?, progress: ((Int, Int) -> Void)?,
                               readBlock: (Int) throws -> Data) throws -> DTSXDynamicPCMBuffer {
        guard master.audioFormat.sampleCount <= UInt64(Int.max),
              master.audioFormat.sampleRate == 48_000, master.audioFormat.bitDepth == 24,
              master.audioFormat.bytesPerPacket == master.audioFormat.channelCount*3,
              maximumSampleCount == nil || maximumSampleCount! > 0 else { throw DTSError.invalidArgument("Invalid dynamic render input") }
        let count = min(Int(master.audioFormat.sampleCount), maximumSampleCount ?? Int.max)
        guard count > 0 else { throw DTSError.invalidArgument("Empty Atmos programme") }
        let channels = master.audioFormat.channelCount
        var fixed = Array(repeating: Array(repeating: Int32(0), count: count), count: layout.fixedPlaneCount)
        var moving = Array(repeating: Array(repeating: Int32(0), count: count), count: layout.dynamicObjectCount)
        let sourceCount = master.objects.count
        var states = master.objects.map { AtmosObjectState(elementID: $0.elementID) }
        let ids = Dictionary(uniqueKeysWithValues: master.objects.enumerated().map { ($0.element.elementID, $0.offset) })
        var pan = Array(repeating: DTSIMAXObjectGainSmoother(),count: sourceCount)
        var mix = Array(repeating: DTS714ObjectGainSmoother(),count: sourceCount)
        var previouslyAudible = Array(repeating: false,count: sourceCount)
        var aggregator = DTSXSpatialAggregator(count: layout.dynamicObjectCount)
        var presentation = DTSXDynamicPresentationState()
        var positions: [[DTSXObjectPosition]] = []
        var event = 0
        var nearestError = 0.0, fittedError = 0.0, errorMass = 0.0
        var angularError = 0.0, distanceError = 0.0
        let bedRoutes = master.bedChannels.map { bed in
            (bed.audioChannelIndex,DTS714ChannelMapper.routes(for: bed.dtsSpeaker).map {
                (DTS714Channel.allCases.firstIndex(of: $0.channel)!,$0.gainQ30)
            })
        }
        func nativeGains(_ state: AtmosObjectState) -> [(outputIndex: Int,q30: Int64)] {
            layout == .sevenOneFour ? DTS714VBAPPanner.gains(for: state) : DTSIMAXPanner.gains(for: state)
        }
        func roundQ30(_ value: Int64) -> Int64 {
            let half: Int64 = (1 << 29)-1
            return value >= 0 ? (value+half) >> 30 : -((-value+half) >> 30)
        }
        for start in stride(from: 0, to: count, by: 512) {
            let samples = min(512, count - start), byteCount = samples * channels * 3
            let bytes = try readBlock(byteCount)
            guard bytes.count == byteCount else { throw DTSError.truncated(field: "Dynamic Atmos PCM", bitOffset: start * channels * 24) }
            var audio = Array(repeating: Array(repeating: Int32(0), count: samples), count: sourceCount)
            var energy = Array(repeating: 0.0, count: sourceCount)
            var radiusMass = energy
            var targets = Array(repeating: Array(repeating: 0.0,count: layout.fixedPlaneCount),count: sourceCount)
            try bytes.withUnsafeBytes { raw in
                let input = raw.bindMemory(to: UInt8.self)
                for sample in 0..<samples {
                    while event < master.metadataEvents.count && master.metadataEvents[event].samplePosition <= Int64(start + sample) {
                        let update = master.metadataEvents[event]
                        if let index = ids[update.elementID] {
                            states[index].apply(update)
                            if start+sample > 0 {
                                let ordinary = update.rampLength.map { max(1,Int(clamping: $0)) }
                                    ?? max(1,Int((48_000/((master.framesPerSecond ?? 24)*8)).rounded()))
                                pan[index].retarget(nativeGains(states[index]),over: ordinary)
                            }
                        }
                        event += 1
                    }
                    func pcm(_ channel: Int) -> Int32 {
                        let offset = (sample * channels + channel) * 3
                        let raw = Int32(input[offset]) | Int32(input[offset+1]) << 8 | Int32(input[offset+2]) << 16
                        return raw & 0x800000 != 0 ? raw | ~0xffffff : raw
                    }
                    var fixedAccumulator = Array(repeating: Int64(0),count: layout.fixedPlaneCount)
                    for (channel,routes) in bedRoutes {
                        let value = Int64(pcm(channel))
                        for (destination,gain) in routes { fixedAccumulator[destination] += value*gain }
                    }
                    for source in 0..<sourceCount {
                        if start+sample == 0 { pan[source].setImmediately(nativeGains(states[source])) }
                        else { pan[source].advance() }
                        let value = pcm(master.objects[source].audioChannelIndex)
                        guard value != 0 else { continue }
                        let weight = Double(value)*Double(value)
                        var power = 0.0
                        for channel in pan[source].activeIndices {
                            let gain = pan[source].currentGains[channel]
                            if channel == 12 {
                                if layout == .sevenOneFive { fixedAccumulator[12] += Int64(value)*gain }
                                continue
                            }
                            // Preserve the complete authored speaker image first.
                            // The bounded aggregate render is removed below; its
                            // unrepresented image remains on the fixed bed.
                            fixedAccumulator[channel] += Int64(value)*gain
                            let linear = Double(gain)/Double(1 << 30)
                            power += linear*linear
                        }
                        let activePower = weight*power
                        let norm = sqrt(power)
                        if norm > 1e-12 {
                            let q30 = Int64((norm*Double(1 << 30)).rounded())
                            let scaled = roundQ30(Int64(value)*q30)
                            guard scaled >= Int64(Int32.min),scaled <= Int64(Int32.max) else { throw DTSError.malformed("Object gain exceeds working PCM range") }
                            audio[source][sample] = Int32(scaled)
                            for channel in pan[source].activeIndices where channel != 12 {
                                let linear = Double(pan[source].currentGains[channel])/Double(1 << 30)
                                targets[source][channel] += activePower*linear/norm
                            }
                        }
                        energy[source] += activePower
                        let point = states[source].position ?? AtmosPosition(x: 0,y: 0,z: 0)
                        let radius = min(1,max(abs(point.x),abs(point.y),states[source].elevation ? point.z : 0))
                        radiusMass[source] += activePower*radius
                    }
                    for channel in fixed.indices {
                        let value = roundQ30(fixedAccumulator[channel])
                        guard value >= Int64(Int32.min), value <= Int64(Int32.max) else { throw DTSError.malformed("Fixed bed exceeds working PCM range") }
                        fixed[channel][start+sample] = Int32(value)
                    }
                }
            }
            let points = (0..<sourceCount).map { source in
                if energy[source] > 0 {
                    targets[source] = targets[source].map { $0/energy[source] }
                    let norm = sqrt(DTSXDynamicSpatialModel.dot(targets[source],targets[source]))
                    if norm > 1e-12 { targets[source] = targets[source].map { $0/norm } }
                }
                return DTSXDynamicSpatialModel.direction(image: targets[source],radius: 1)
            }
            let radial = energy.indices.map { energy[$0] > 0 ? radiusMass[$0]/energy[$0] : 0 }
            var candidates: [AtmosPosition] = [], candidateEnergy: [Double] = [], candidateIDs: [Int] = [], candidateDistance: [Double] = []
            for source in 0..<sourceCount where energy[source] > 0 {
                let position = try DTSXObjectPosition(direction: points[source],distance: radial[source])
                let pointImage = DTSXDynamicSpatialModel.image(position: position,layout: layout)
                let pointError = zip(pointImage,targets[source]).reduce(0) { $0+pow($1.0-$1.1,2) }
                if pointError <= 0.05 {
                    candidates.append(points[source]); candidateEnergy.append(energy[source])
                    candidateIDs.append(master.objects[source].elementID); candidateDistance.append(radial[source])
                } else {
                    // A broad/central source cannot be represented by one ray
                    // merely by lowering its distance. Supply its real speaker
                    // image directions to the finite four-slot coverage search.
                    for channel in 0..<12 where channel != 3 && targets[source][channel] > 1e-6 {
                        let v = DTSXDynamicSpatialModel.vectors[channel]
                        candidates.append(AtmosPosition(x: v.0,y: v.1,z: v.2))
                        candidateEnergy.append(energy[source]*targets[source][channel]*targets[source][channel])
                        candidateIDs.append(1_000_000_000_000+master.objects[source].elementID*16+channel)
                        candidateDistance.append(radial[source])
                    }
                }
            }
            _ = aggregator.update(points: candidates,energy: candidateEnergy,sourceIDs: candidateIDs,sourceDistances: candidateDistance)
            let quantized = try aggregator.centres.indices.map {
                try DTSXObjectPosition(direction: aggregator.centres[$0],distance: aggregator.distances[$0])
            }
            let assignments = points.map { point in
                aggregator.centres.indices.min { DTSXSpatialAggregator.distance(point,aggregator.centres[$0]) < DTSXSpatialAggregator.distance(point,aggregator.centres[$1]) }!
            }
            positions.append(quantized)
            let columns = quantized.map { DTSXDynamicSpatialModel.image(position: $0,layout: layout) }
            presentation.retarget(columns)
            for slot in 0..<4 {
                let point = aggregator.centres[slot]
                let radius = aggregator.distances[slot]
                let a = atan2(point.x,point.y)*180 / .pi
                let e = atan2(point.z,hypot(point.x,point.y))*180 / .pi
                let da = abs((a-quantized[slot].azimuth+540).truncatingRemainder(dividingBy: 360)-180)
                angularError = max(angularError,da,abs(e-quantized[slot].elevation))
                distanceError = max(distanceError,abs(radius-quantized[slot].distance))
            }
            for source in 0..<sourceCount {
                let fitted = DTSXDynamicSpatialModel.fit(target: targets[source],columns: columns)
                let sparse = fitted.enumerated().compactMap { slot,gain -> (outputIndex: Int,q30: Int64)? in
                    guard gain > 0 else { return nil }
                    return (slot,Int64((gain*Double(1 << 30)).rounded()))
                }
                // Silence has no audible previous image. Install its next fit
                // immediately; source activation/trim already follows the
                // sample-continuous native gain state above. Averaging that
                // envelope into an AU gain would leak pre-activation PCM.
                if start == 0 || !previouslyAudible[source] || energy[source] == 0 {
                    mix[source].setImmediately(sparse)
                } else { mix[source].retarget(sparse,over: 512) }
                previouslyAudible[source] = energy[source] > 0
                if energy[source] > 0 {
                    var nearest = Array(repeating: 0.0,count: 4)
                    let index = max(0,assignments[source])
                    nearest[index] = sqrt(DTSXDynamicSpatialModel.dot(targets[source],targets[source])
                        / max(1e-20,DTSXDynamicSpatialModel.dot(columns[index],columns[index])))
                    nearestError += energy[source]*DTSXDynamicSpatialModel.error(target: targets[source],weights: nearest,columns: columns)
                    fittedError += energy[source]*DTSXDynamicSpatialModel.error(target: targets[source],weights: fitted,columns: columns)
                    errorMass += energy[source]
                }
            }
            for sample in 0..<samples {
                presentation.advance()
                var mixed = Array(repeating: Int64(0),count: 4)
                for source in 0..<sourceCount {
                    if start > 0 { mix[source].advance() }
                    let value = Int64(audio[source][sample])
                    for slot in mix[source].activeIndices {
                        mixed[slot] += value*mix[source].currentGains[slot]
                    }
                }
                for slot in moving.indices {
                    let value = roundQ30(mixed[slot])
                    guard value >= Int64(Int32.min), value <= Int64(Int32.max) else { throw DTSError.malformed("Dynamic aggregate exceeds working PCM range") }
                    moving[slot][start+sample] = Int32(value)
                }
                for channel in 0..<12 {
                    var rendered = 0.0
                    for slot in moving.indices {
                        rendered += Double(moving[slot][start+sample])*presentation.gains[slot][channel]
                    }
                    let residual = (Double(fixed[channel][start+sample])-rendered).rounded()
                    guard residual.isFinite,residual >= Double(Int32.min),residual <= Double(Int32.max) else {
                        throw DTSError.malformed("Dynamic spatial residual exceeds working PCM range")
                    }
                    fixed[channel][start+sample] = Int32(residual)
                }
            }
            progress?(start+samples, count)
        }
        let report = DTSXSpatialAggregationReport(sourceObjectCount: sourceCount,analysedFrameCount: positions.count,
            energyWeightedNearestImageError: nearestError/max(1e-20,errorMass),
            energyWeightedFittedImageError: fittedError/max(1e-20,errorMass),
            maximumAngularQuantizationErrorDegrees: angularError,maximumDistanceQuantizationError: distanceError,
            reservedTFCNonzeroSamples: layout == .sevenOneFive ? fixed[12].lazy.filter { $0 != 0 }.count : 0,
            reservedTFCExcludedFromDynamicAggregation: true,fixedBedCarriesSpatialResidual: true)
        return try DTSXDynamicPCMBuffer(layout: layout,fixedPlanes: fixed,dynamicPlanes: moving,positions: positions,aggregation: report)
    }

    public static func writeStems(_ source: DTSXDynamicPCMBuffer, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = Array(DTS714Channel.allCases.map(\.rawValue).prefix(source.layout.fixedPlaneCount))
            + (source.layout == .sevenOneFive ? ["TFC_reserved_IMAX"] : [])
        for (index, plane) in source.fixedPlanes.enumerated() {
            try WaveFile.writeMono24(plane, to: directory.appendingPathComponent(names[index] + ".wav"))
        }
        for (index, plane) in source.dynamicPlanes.enumerated() {
            try WaveFile.writeMono24(plane, to: directory.appendingPathComponent("Dynamic\(index).wav"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(source.positions).write(to: directory.appendingPathComponent("positions.json"), options: .atomic)
    }
}
