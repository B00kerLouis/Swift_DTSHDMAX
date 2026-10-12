import Foundation

public enum DTSXDynamicEncoderVerifier {
    /// Diagnostic transport-panner model, qualified independently against
    /// official decoded position vectors. It is not a playback acceptance flag.
    public static func previewGains(position: DTSXObjectPosition) -> [Double] {
        DTSXDynamicSpatialModel.image(position: position,layout: .sevenOneFour)
    }
    /// Independent field checks, shared-width boundaries, PCM, silent/tail
    /// classes and corruption rejection. No official playback claim.
    public static func verify() throws -> [String: Int] {
        guard DTSXDynamicLayout.allCases.count == 2,DTSXDynamicLayout(rawValue: "7.1") == nil,
              DTSXDynamicLayout.allCases.allSatisfy({ $0.dynamicObjectCount == 4 }) else {
            throw DTSError.malformed("Removed object-only layout remains exposed")
        }
        let invalidPosition = Data("{\"azimuthCode\":500,\"elevationCode\":60,\"distanceCode\":63}".utf8)
        guard (try? JSONDecoder().decode(DTSXObjectPosition.self,from: invalidPosition)) == nil else {
            throw DTSError.malformed("Position decoding bypasses transport bounds")
        }
        var cases = 0, compared = 0, corruptions = 0
        for layout in DTSXDynamicLayout.allCases {
            for mode in DTSEncodeMode.allCases {
                for segments in [2,4,8] {
                    for width in [7,8,10,14] {
                        let positions = try (0..<layout.dynamicObjectCount).map {
                            try DTSXObjectPosition(azimuthCode: 20+$0*25, elevationCode: 65+$0*3)
                        }
                        let channels = layout.recordCount + 4
                        var planes: [[Int32]] = []
                        for channel in 0..<channels {
                            var plane: [Int32] = []
                            for sample in 0..<512 {
                                let raw = (sample*7919+channel*10007)%65521-32760
                                plane.append(width == 7 ? 0 : Int32(raw * (width == 14 ? 127 : 1)))
                            }
                            planes.append(plane)
                        }
                        let plan = try XLLSegmentationPlan(segmentCount: segments, segmentSampleCount: 512/segments,
                            segmentSizeBitCount: width, navigationByteCount: 2, segmentEntropyByteCounts: Array(repeating: [1], count: segments))
                        let frame = try DTSXDynamicPrivateFrame.encode(layout: layout, positions: positions,
                            dynamicFoldCodes: positions.map { $0.foldCodes(for: layout) }, planes: planes, plan: plan, mode: mode)
                        // Independent field extraction: the fourth byte's low
                        // nibble is a count, never an IMAX/standard label.
                        var declaration = try BitReader(data: frame.data)
                        try declaration.skip(28,field: "Declaration-count offset")
                        let declarationCount = Int(try declaration.read(4,field: "Declared records minus one"))+1
                        guard try frame.decode() == planes,
                              declarationCount == layout.recordCount,
                              frame.metadata.heightBedColumns == [1,2,6,7],
                              Array(frame.metadata.positions.suffix(layout.dynamicObjectCount)) == positions,
                              frame.metadata.reservedTFC == (layout == .sevenOneFive),
                              frame.groups.count == 2 else { throw DTSError.malformed("Dynamic vector role/PCM mismatch") }
                        let finalized = try XLLSegmentationPlan(segmentCount: segments, segmentSampleCount: 512/segments,
                            segmentSizeBitCount: max(width,frame.navigationWidth), navigationByteCount: 2, segmentEntropyByteCounts: Array(repeating: [1], count: segments))
                        try frame.validate(plan: finalized)
                        var damaged = frame.data; damaged[8] ^= 1
                        do { _ = try DTSXDynamicPrivateFrame.parse(damaged); throw DTSError.malformed("Corrupt object metadata accepted") }
                        catch { guard (try? DTSXDynamicPrivateFrame.parse(damaged)) == nil else { throw error }; corruptions += 1 }
                        cases += 1; compared += channels*512
                    }
                }
            }
        }
        var aggregator = DTSXSpatialAggregator(count: 4)
        let points = [AtmosPosition(x: -1,y: 1,z: 0),AtmosPosition(x: 1,y: 1,z: 1)]
        let first = aggregator.update(points: points, energy: [2,1])
        let reordered = aggregator.update(points: points.reversed(), energy: [1,2], sourceIDs: [1,0])
        guard first == reordered.reversed() else { throw DTSError.malformed("Aggregate slots changed with source order") }
        let anchors: [(AtmosPosition,DTSXDynamicLayout,Int,Int)] = [
            (AtmosPosition(x: -1,y: 1,z: 0),.sevenOneFour,100,60),
            (AtmosPosition(x: 1,y: 1,z: 0),.sevenOneFour,140,60),
            (AtmosPosition(x: -0.5,y: 0.5,z: 1),.sevenOneFour,90,90),
            (AtmosPosition(x: 0,y: 1,z: 1),.sevenOneFive,120,77)
        ]
        for (room,layout,a,e) in anchors {
            let position = try DTSXObjectPosition(room: room,layout: layout)
            guard position.azimuthCode == a,position.elevationCode == e,position.distanceCode == 63 else {
                throw DTSError.malformed("Room-to-spherical speaker anchor is inaccurate")
            }
        }
        guard try DTSXObjectPosition(room: AtmosPosition(x: 0,y: 0,z: 0)).distanceCode == 0,
              try DTSXObjectPosition(room: AtmosPosition(x: 0,y: 0.5,z: 0)).distanceCode == 31 else {
            throw DTSError.malformed("Interior object distance was replaced by a unit-distance source")
        }
        let left = try DTSXObjectPosition(azimuthCode: 100,elevationCode: 60)
        let topLeft = try DTSXObjectPosition(azimuthCode: 90,elevationCode: 90)
        guard left.foldCodes(for: .sevenOneFour) == [61,0,0,0,0,0,0,0],
              topLeft.foldCodes(for: .sevenOneFour) == [55,0,0,0,0,0,0,0],
              topLeft.foldCodes(for: .sevenOneFive) == [61,0,0,0,0,0,0,0] else {
            throw DTSError.malformed("Object compatibility folds do not match the declared speaker image/profile")
        }
        let columns = try [(100,60),(140,60),(20,90),(220,90)].map {
            DTSXDynamicSpatialModel.image(position: try DTSXObjectPosition(azimuthCode: $0.0,elevationCode: $0.1),layout: .sevenOneFour)
        }
        let expected = [0.25,0.5,0.1,0.15]
        let image = DTSXDynamicSpatialModel.rendered(expected,columns: columns)
        let fitted = DTSXDynamicSpatialModel.fit(target: image,columns: columns,nearest: 0)
        guard DTSXDynamicSpatialModel.error(target: image,weights: fitted,columns: columns) < 1e-18 else {
            throw DTSError.malformed("Four-object nonnegative image fit does not reconstruct its spanned field")
        }
        let moving = try (0..<4).map { try DTSXObjectPosition(azimuthCode: 40+$0*40,elevationCode: 75) }
        var meta = try DTSXDynamicMetadata.encode(layout: .sevenOneFive,positions: moving,
                                                dynamicFoldCodes: moving.map { $0.foldCodes(for: .sevenOneFive) })
        // Five 18-bit declarations follow the 64-bit layout header. Mutate
        // reserved record zero's azimuth while closing a valid outer CRC.
        let bit = 64+5*18+3+7+1+1+2+6+6
        meta[bit/8] ^= UInt8(1 << (7-bit%8))
        var writer = BitWriter(); try writer.write(bytes: meta.dropLast(2),field: "Reserved role mutation")
        try DTSCRC16.appendChecksum(to: &writer,protectedByteOffset: 0,component: "Reserved role mutation")
        guard (try? DTSXDynamicMetadata.parse(writer.data())) == nil else { throw DTSError.malformed("Moving IMAX reserved record was accepted") }
        var carrierCases = 0
        for layout in DTSXDynamicLayout.allCases {
            // Motion updates coefficients without adding/removing reference
            // columns, including silent priming and a short tail.
            let count = 1025
            var fixed = Array(repeating: Array(repeating: Int32(0),count: count),count: layout.fixedPlaneCount)
            if layout == .sevenOneFive { fixed[12] = Array(repeating: 1234,count: count) }
            let audio = [Array(repeating: Int32(100_000),count: count)]
                + Array(repeating: Array(repeating: Int32(0),count: count),count: 3)
            let right = try DTSXObjectPosition(azimuthCode: 140,elevationCode: 60)
            let poses = [left,right,left].map { Array(repeating: $0,count: 4) }
            let source = try DTSXDynamicPCMBuffer(layout: layout,fixedPlanes: fixed,dynamicPlanes: audio,positions: poses)
            let folds = DTSXDynamicFoldPlan(source: source)
            let session = DTSXDynamicStreamSession(source: source,mode: .auto,folds: folds)
            let plan = try XLLSegmentationPlan(segmentCount: 2,segmentSampleCount: 256,segmentSizeBitCount: 14,
                navigationByteCount: 2,segmentEntropyByteCounts: [[1],[1]])
            for frame in 0..<session.frameCount {
                let encoded = try DTSXDynamicPrivateFrame.parse(session.encodeFrame(at: frame,plan: plan))
                guard Array(encoded.metadata.foldCodes.suffix(4)) == folds.frameCodes[max(0,frame-2)],
                      Array(encoded.metadata.gainCodes.suffix(4)) == Array(repeating: DTSXDynamicFoldPlan.objectGainCode,count: 4),
                      Array(encoded.metadata.positions.suffix(4)) == poses[max(0,frame-2)],
                      encoded.metadata.reservedTFC == (layout == .sevenOneFive) else {
                    throw DTSError.malformed("Moving reference rows or reserved IMAX identity differ")
                }
                let decoded = try encoded.decode()
                if frame < 2 {
                    guard decoded.allSatisfy({ $0.allSatisfy({ $0 == 0 }) }) else { throw DTSError.malformed("Carrier priming is audible") }
                } else {
                    let offset = layout.reservedIMAXObjectCount
                    let value = Int32(DTSXDynamicFoldPlan.codedSample(100_000))
                    let expected = frame == 4 ? [value]+Array(repeating: Int32(0),count: 511)
                        : Array(repeating: value,count: 512)
                    guard decoded[offset] == expected else { throw DTSError.malformed("Carrier change altered object PCM or tail") }
                    if layout == .sevenOneFive {
                        let tfc = frame == 4 ? [Int32(1234)]+Array(repeating: Int32(0),count: 511)
                            : Array(repeating: Int32(1234),count: 512)
                        guard decoded[0] == tfc else { throw DTSError.malformed("Carrier change altered reserved TFC PCM") }
                    }
                }
            }
            _ = try session.finish()
            let masks = folds.frameCodes.map { frame in frame.map { row in row.enumerated().reduce(0) {
                $0 | ($1.element > 0 ? (1 << $1.offset) : 0)
            } } }
            guard masks.allSatisfy({ $0 == [247,247,247,247] }),
                  folds.frameCodes[0] != folds.frameCodes[1],
                  DTSXDynamicMetadata.referenceGainQ15(1) == 0 else {
                throw DTSError.malformed("Reference-column identity changed during motion")
            }
            var reference = DTSXDynamicReferenceState()
            reference.retarget(folds.frameCodes[0]);reference.advance()
            let previous = reference.gains[0][0]
            reference.retarget(folds.frameCodes[1]);reference.advance()
            guard abs(reference.gains[0][0]-previous) < 0.002 else {
                throw DTSError.malformed("Compatibility reference transition stepped")
            }
            carrierCases += 1
        }
        return ["cases":cases,"comparedSamples":compared,"metadataCorruptionsRejected":corruptions,
                "spatialAnchorCases":anchors.count,"interiorDistanceCases":2,"imageFitCases":1,
                "continuousCarrierCases":carrierCases,
                "reservedRoleCorruptionsRejected":1,"officialPlaybackQualified":0]
    }

    /// Exactly 90 seconds, with distinct tones, impulses, silence and motion.
    /// A nonzero static TFC vector proves reserved/dynamic isolation.
    public static func generate(directory: URL) throws -> [DTSXDynamicEncodingReport] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let count = 90*48_000
        var reports: [DTSXDynamicEncodingReport] = []
        for layout in DTSXDynamicLayout.allCases {
            var fixed = Array(repeating: Array(repeating: Int32(0), count: count), count: layout.fixedPlaneCount)
            var moving = Array(repeating: Array(repeating: Int32(0), count: count), count: layout.dynamicObjectCount)
            for sample in 0..<count {
                let time = Double(sample)/48_000
                let envelope = min(1, max(0, min(time-1,89-time)))
                for object in moving.indices {
                    moving[object][sample] = Int32((80_000*envelope*sin(2 * .pi * Double(211+object*97)*time)).rounded())
                }
                if layout == .sevenOneFive { fixed[12][sample] = Int32((90_000*envelope*sin(2 * .pi * 173*time)).rounded()) }
                if sample % 48_000 == 0 && sample > 48_000 { fixed[(sample/48_000)%layout.fixedPlaneCount][sample] += 100_000 }
            }
            let positions = try (0..<(count+511)/512).map { frame -> [DTSXObjectPosition] in
                try moving.indices.map { object in
                    let angle = Double(frame)*512/48_000*0.2+Double(object)*2 * .pi/Double(moving.count)
                    return try DTSXObjectPosition(room: AtmosPosition(x: sin(angle),y: cos(angle),z: 0.5+0.4*sin(angle*0.7)))
                }
            }
            let source = try DTSXDynamicPCMBuffer(layout: layout,fixedPlanes: fixed,dynamicPlanes: moving,positions: positions)
            let name = "Vector_\(layout.rawValue)_plus\(layout.dynamicObjectCount)"
            reports.append(try DTSXDynamicHDMAEncoder().encode(source: source,to: directory.appendingPathComponent(name+".dtshd"),
                frameRate: .fps24,stemsDirectory: directory.appendingPathComponent(name+"_stems")))
        }
        return reports
    }
}
