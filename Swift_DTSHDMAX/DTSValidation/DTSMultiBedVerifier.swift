// Copyright (c) B00kerLouis.
import Foundation

/// Bounded source vectors verify layer sums, identities, topology and transport
/// independence. They are not programme playback or hardware acceptance tests.
public enum DTSMultiBedVerifier {
    public static func verify() throws -> [String: Int] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hdmax-beds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let damf = try writeDAMF(folder: folder)
        let adm = try writeADM(folder: folder)
        let pcmIAB = try writeIAB(folder: folder, name: "PCM", dlc: false)
        let dlcIAB = try writeIAB(folder: folder, name: "DLC", dlc: true)
        var renderCases = 0, encodingCases = 0
        for input in [damf, adm, pcmIAB, dlcIAB] {
            let iab = input.pathExtension == "mxf" ? try IMFIABReader.read(url: input) : nil
            let master = try iab?.master ?? AtmosInputReader.read(url: input)
            guard Set(master.bedChannels.compactMap(\.bedID)).count == 2 else {
                throw DTSError.malformed("Source bed identities were merged")
            }
            if iab == nil {
                let block = try AtmosSceneReader.readBlock(master: master, sampleStart: 0, sampleCount: 16)
                guard block.bedPlanes[.center]?.allSatisfy({ $0 == 6000 }) == true else {
                    throw DTSError.malformed("Scene block did not sum both centre beds")
                }
            }
            let fixed = try iab.map { try DTS714Renderer.render(iab: $0) } ?? DTS714Renderer.render(master: master)
            let imax = try iab.map { try DTSIMAXRenderer.render(iab: $0) } ?? DTSIMAXRenderer.render(master: master)
            guard fixed.planes[2].allSatisfy({ $0 == 5988 }), fixed.planes[0].allSatisfy({ $0 == 3992 }),
                  imax.planes[2].allSatisfy({ $0 == 5988 }), imax.planes[0].allSatisfy({ $0 == 3992 }) else {
                throw DTSError.malformed("Fixed/IMAX bed sum differs from the known input")
            }
            renderCases += 2
            for layout in DTSXDynamicLayout.allCases {
                let source = try iab.map { try DTSXDynamicRenderer.render(iab: $0, layout: layout) }
                    ?? DTSXDynamicRenderer.render(master: master, layout: layout)
                guard source.fixedPlanes[2].allSatisfy({ $0 == 5988 }), source.fixedPlanes[0].allSatisfy({ $0 == 3992 }),
                      source.dynamicPlanes.allSatisfy({ $0.allSatisfy { $0 == 0 } }) else {
                    throw DTSError.malformed("Dynamic fixed bed lost a layer")
                }
                renderCases += 1
            }
            for vision in DTSXVision.allCases { for mode in DTSObjectMode.allCases { for coding in DTSEncodeMode.allCases {
                let output = folder.appendingPathComponent("\(input.lastPathComponent)-\(vision.rawValue)-\(mode.rawValue)-\(coding.rawValue).dtshd")
                _ = try DTSAutomaticEncoder.encode(inputURL: input, outputURL: output, frameRateOverride: .fps24,
                    encodeMode: coding, dtsxVision: vision, objectMode: mode)
                let bytes = try Data(contentsOf: output)
                guard bytes.starts(with: Data("DTSHDHDR".utf8)) else { throw DTSError.malformed("Missing multi-bed output") }
                encodingCases += 1
            } } }
        }
        let changed = try writeIAB(folder: folder, name: "Changed", dlc: false, changingTopology: true)
        guard (try? IMFIABReader.read(url: changed)) == nil else { throw DTSError.malformed("Changing bed topology accepted") }
        let duplicate = try writeIAB(folder: folder, name: "Duplicate", dlc: false, duplicateChannel: true)
        guard (try? IMFIABReader.read(url: duplicate)) == nil else { throw DTSError.malformed("Repeated speaker within one bed accepted") }
        let waveCases = try verifyWaveOrders(folder: folder)
        let batch = try DTSParallel.start(count: 32, workerCount: 4) { index -> Int in
            if index == 17 { throw DTSError.malformed("Expected bounded worker error") }
            return index
        }
        guard (try? batch.wait()) == nil else { throw DTSError.malformed("Worker error was lost") }
        batch.waitForCompletion()
        return ["bedRenderCases": renderCases, "modeAndCodingEncodingCases": encodingCases,
            "sceneLayerSumCases": 2, "invalidTopologyCases": 2, "waveOrderAndSignedPCMCases": waveCases,
            "joinedWorkerErrorCases": 1, "workerBudget": DTSParallel.workerCount(for: 100), "officialPlaybackQualified": 0]
    }

    private static func writeDAMF(folder: URL) throws -> URL {
        var caf = Data("caff".utf8)
        appendBE(1, bytes: 2, to: &caf); appendBE(0, bytes: 2, to: &caf)
        caf.append(Data("desc".utf8)); appendBE(32, bytes: 8, to: &caf)
        appendBE(Double(48000).bitPattern, bytes: 8, to: &caf); caf.append(Data("lpcm".utf8))
        for value in [12,15,1,5,24] { appendBE(UInt64(value), bytes: 4, to: &caf) }
        let pcm = packed(values: [1000,2000,3000,4000,0], samples: 1025)
        caf.append(Data("data".utf8)); appendBE(UInt64(pcm.count + 4), bytes: 8, to: &caf)
        appendBE(0, bytes: 4, to: &caf); caf.append(pcm)
        try caf.write(to: folder.appendingPathComponent("音频.caf"))
        let url = folder.appendingPathComponent("场景.atmos")
        try Data("""
        version: 1
        metadata: scene.metadata
        audio: 音频.caf
        offset: 0
        ffoa: 0
        fps: 24
        bedInstances:
          - channels:
            - channel: L
              ID: 1
            - channel: C
              ID: 2
          - channels:
            - channel: L
              ID: 3
            - channel: C
              ID: 4
        objects:
          - ID: 100
        """.utf8).write(to: url)
        try Data("sampleRate: 48000\n- ID: 100\n  samplePos: 0\n  active: false\n".utf8)
            .write(to: folder.appendingPathComponent("scene.metadata"))
        return url
    }

    private static func writeADM(folder: URL) throws -> URL {
        var xml = "<audioFormatExtended>"
        var chna = Data(); appendLE(5, bytes: 2, to: &chna); appendLE(5, bytes: 2, to: &chna)
        for track in 1...5 {
            let hex = String(format: "%08x", track), uid = "ATU_\(hex)", tf = "AT_\(hex)_01", sf = "AS_\(hex)", cf = "AC_\(hex)"
            let name = [1,3].contains(track) ? "RoomCentricLeft" : "RoomCentricCenter"
            let type = track == 5 ? "Objects" : "DirectSpeakers"
            xml += "<audioTrackUID UID=\"\(uid)\"><audioTrackFormatIDRef>\(tf)</audioTrackFormatIDRef></audioTrackUID>"
            xml += "<audioTrackFormat audioTrackFormatID=\"\(tf)\"><audioStreamFormatIDRef>\(sf)</audioStreamFormatIDRef></audioTrackFormat>"
            xml += "<audioStreamFormat audioStreamFormatID=\"\(sf)\"><audioChannelFormatIDRef>\(cf)</audioChannelFormatIDRef></audioStreamFormat>"
            xml += "<audioChannelFormat audioChannelFormatID=\"\(cf)\" audioChannelFormatName=\"\(name)\" typeDefinition=\"\(type)\"></audioChannelFormat>"
            appendLE(UInt64(track), bytes: 2, to: &chna)
            for (text, count) in [(uid,12),(tf,14),(String(format: "AP_%08x", (track+1)/2),11)] {
                let bytes = Data(text.utf8); chna.append(bytes); chna.append(Data(count: count - bytes.count))
            }
            chna.append(0)
        }
        for (bed, tracks) in [(1,[1,2]),(2,[3,4]),(3,[5])] {
            xml += "<audioObject audioObjectID=\"AO_\(bed)\">"
            for track in tracks { xml += String(format: "<audioTrackUIDRef>ATU_%08x</audioTrackUIDRef>", track) }
            xml += "</audioObject>"
        }
        xml += "</audioFormatExtended>"
        var fmt = Data()
        for (value, size) in [(1,2),(5,2),(48000,4),(720000,4),(15,2),(24,2)] { appendLE(UInt64(value), bytes: size, to: &fmt) }
        var body = Data("WAVE".utf8)
        body.append(chunk("fmt ", fmt)); body.append(chunk("data", packed(values: [1000,2000,3000,4000,0], samples: 1025)))
        body.append(chunk("axml", Data(xml.utf8))); body.append(chunk("chna", chna))
        var wave = Data("RIFF".utf8); appendLE(UInt64(body.count), bytes: 4, to: &wave); wave.append(body)
        let url = folder.appendingPathComponent("ADM.wav"); try wave.write(to: url); return url
    }

    private static func writeIAB(folder: URL, name: String, dlc: Bool,
                                 changingTopology: Bool = false, duplicateChannel: Bool = false) throws -> URL {
        var essence = Data()
        for frame in 0..<(changingTopology ? 2 : 1) {
            var children = Data()
            let beds = changingTopology && frame == 1 ? 1 : 2
            for bed in 0..<beds {
                var writer = BitWriter()
                try writer.write(UInt64(bed + 1), bitCount: 8, field: "Bed MetaID")
                try writer.write(0, bitCount: 1, field: "Conditional")
                try writer.write(4, bitCount: 4, field: "Channels")
                for channel in 0..<4 {
                    let channelID = duplicateChannel && channel == 1 ? 0 : [0,2,4,13][channel]
                    try writer.write(UInt64(channelID), bitCount: 4, field: "ChannelID")
                    try writer.write(UInt64(bed * 4 + channel + 1), bitCount: 8, field: "AudioDataID")
                    try writer.write(0, bitCount: 2, field: "Unity gain")
                    try writer.write(0, bitCount: 1, field: "No decorrelation")
                }
                try writer.write(0x180, bitCount: 10, field: "Reserved")
                let padding = (8 - writer.bitCount % 8) % 8
                try writer.write(0, bitCount: padding, field: "Alignment")
                var payload = Data(writer.bytes); payload.append(contentsOf: [0,0])
                children.append(element(0x10, payload))
            }
            for lane in 0..<(beds * 4) {
                let value: Int32 = [1000,2000,0,0,3000,4000,0,0][lane]
                var payload = Data([UInt8(lane + 1)])
                if dlc {
                    var bits = BitWriter()
                    try bits.write(0, bitCount: 16, field: "DLCSize")
                    try bits.write(0, bitCount: 2, field: "48 kHz")
                    try bits.write(8, bitCount: 5, field: "ShiftBits")
                    try bits.write(0, bitCount: 2, field: "No prediction")
                    for _ in 0..<10 {
                        try bits.write(0, bitCount: 1, field: "Direct residual")
                        try bits.write(value == 0 ? 0 : 12, bitCount: 5, field: "Residual width")
                        for _ in 0..<200 where value != 0 {
                            try bits.write(UInt64(value), bitCount: 12, field: "Residual")
                            try bits.write(0, bitCount: 1, field: "Sign")
                        }
                    }
                    var coded = Data(bits.bytes)
                    let size = coded.count - 2
                    coded[0] = UInt8(size >> 8); coded[1] = UInt8(size & 255)
                    payload.append(coded)
                } else { payload.append(packed(values: [value], samples: 2000)) }
                children.append(element(dlc ? 0x200 : 0x400, payload))
            }
            var content = Data([1,0x10,8,UInt8(beds * 5)])
            content.append(children)
            let body = element(8, content)
            essence.append(2); appendBE(UInt64(body.count), bytes: 4, to: &essence); essence.append(body)
        }
        var mxf = Data([6,14,43,52,1,2,1,1,13,1,3,1,22,1,13,1,0x83])
        appendBE(UInt64(essence.count), bytes: 3, to: &mxf); mxf.append(essence)
        let url = folder.appendingPathComponent("\(name).mxf"); try mxf.write(to: url); return url
    }

    private static func verifyWaveOrders(folder: URL) throws -> Int {
        var cases = 0
        for (count, mask) in [(2,UInt32(3)),(6,0x60f),(8,0x63f),(12,0x2d63f),(13,0),(13,0x2f63f)] {
            let values = (0..<count).map { Int32($0.isMultiple(of: 2) ? -8_388_608 + $0 : 8_388_607 - $0) }
            var fmt = Data()
            for (value, size) in [(65534,2),(count,2),(48000,4),(48000*count*3,4),(count*3,2),(24,2),(22,2),(24,2)] {
                appendLE(UInt64(value), bytes: size, to: &fmt)
            }
            appendLE(UInt64(mask), bytes: 4, to: &fmt)
            fmt.append(contentsOf: [1,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113])
            var body = Data("WAVE".utf8); body.append(chunk("fmt ",fmt)); body.append(chunk("data",packed(values: values,samples: 65_537)))
            var bytes = Data("RIFF".utf8); appendLE(UInt64(body.count),bytes: 4,to: &bytes); bytes.append(body)
            let url = folder.appendingPathComponent("wave-\(count)-\(mask).wav"); try bytes.write(to: url)
            let planes: [[Int32]], order: [Int]
            if count == 12 { planes = try WaveFile.readDTS714(from: url).planes; order = [0,1,2,3,6,7,4,5,8,9,10,11] }
            else if count == 13 { planes = try WaveFile.readIMAX(from: url).planes; order = mask == 0 ? Array(0..<13) : [0,1,2,3,6,7,4,5,8,12,9,10,11] }
            else { planes = try WaveFile.read(from: url).planes; order = Array(0..<count) }
            for source in values.indices {
                guard planes[order[source]].allSatisfy({ $0 == values[source] }) else { throw DTSError.malformed("Parallel WAVE unpack changed signed PCM or speaker order") }
            }
            cases += 1
        }
        return cases
    }

    private static func packed(values: [Int32], samples: Int) -> Data {
        var data = Data(); data.reserveCapacity(values.count * samples * 3)
        for _ in 0..<samples { for value in values {
            let word = UInt32(bitPattern: value); data.append(contentsOf: [UInt8(word & 255),UInt8((word >> 8) & 255),UInt8((word >> 16) & 255)])
        } }
        return data
    }
    private static func element(_ id: Int, _ payload: Data) -> Data { plex(id) + plex(payload.count) + payload }
    private static func plex(_ value: Int) -> Data {
        var data = Data()
        if value < 255 { data.append(UInt8(value)) }
        else { data.append(255); appendBE(UInt64(value), bytes: 2, to: &data) }
        return data
    }
    private static func chunk(_ tag: String, _ payload: Data) -> Data {
        var data = Data(tag.utf8); appendLE(UInt64(payload.count),bytes: 4,to: &data); data.append(payload)
        if !payload.count.isMultiple(of: 2) { data.append(0) }; return data
    }
    private static func appendBE(_ value: UInt64, bytes: Int, to data: inout Data) { for shift in (0..<bytes).reversed() { data.append(UInt8((value >> (shift*8)) & 255)) } }
    private static func appendLE(_ value: UInt64, bytes: Int, to data: inout Data) { for shift in 0..<bytes { data.append(UInt8((value >> (shift*8)) & 255)) } }
}
