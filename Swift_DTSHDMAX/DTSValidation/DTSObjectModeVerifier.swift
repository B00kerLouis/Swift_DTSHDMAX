// Copyright (c) B00kerLouis.
import Foundation

/// Small deterministic file vectors qualify routing and invocation isolation.
/// They are not programme playback files or a DTS:X acceptance claim.
public enum DTSObjectModeVerifier {
    public static func verify() throws -> [String: Int] {
        let base = ["-i","scene.atmos","-o","output.dtshd"]
        let defaults = try DTSHDMACommandLine.parseAutomaticOptions(base)
        guard defaults.objectMode == .dynamic,defaults.encodeMode == .auto,defaults.dtsxVision == .sevenOneFour,
              HDMAX.supportedObjectModes() == ["dynamic","channelbase"] else {
            throw DTSError.malformed("Object mode defaults or Framework command surface differ")
        }
        var parserCases = 0
        for vision in DTSXVision.allCases {
            for coding in DTSEncodeMode.allCases {
                let options = try DTSHDMACommandLine.parseAutomaticOptions(base + ["--dtsx-vision",vision.rawValue,
                    "--encode-mode",coding.rawValue])
                guard options.objectMode == DTSObjectMode.defaultMode(for: vision) else {
                    throw DTSError.malformed("Vision-specific default object mode differs")
                }
                parserCases += 1
            }
        }
        for object in DTSObjectMode.allCases {
            for vision in DTSXVision.allCases {
                for coding in DTSEncodeMode.allCases {
                    let options = try DTSHDMACommandLine.parseAutomaticOptions(base + ["--object-mode",object.rawValue.uppercased(),
                        "--dtsx-vision",vision.rawValue,"--encode-mode",coding.rawValue])
                    guard options.objectMode == object,options.dtsxVision == vision,options.encodeMode == coding else {
                        throw DTSError.malformed("Object mode, vision and prediction selectors interfere")
                    }
                    parserCases += 1
                }
            }
        }
        let invalid = [["--object-mode"],["--object-mode","unknown"],
            ["--object-mode","dynamic","--object-mode","channelbase"],["--dynamic-objects","8"],["--layout","7.1"]]
        for options in invalid {
            guard (try? DTSHDMACommandLine.parseAutomaticOptions(base+options)) == nil else {
                throw DTSError.malformed("Invalid or removed object options accepted")
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hdmax-object-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = try writeFixture(folder: folder)
        let master = try AtmosInputReader.read(url: manifest)
        var residualCases = 0
        for vision in DTSXVision.allCases {
            let layout: DTSXDynamicLayout = vision == .imax ? .sevenOneFive : .sevenOneFour
            let source = try DTSXDynamicRenderer.render(master: master,layout: layout)
            let reference: [[Int32]]
            if vision == .imax { reference = try DTSIMAXRenderer.render(master: master).planes }
            else { reference = try DTS714Renderer.render(master: master).planes }
            var presentation = DTSXDynamicPresentationState()
            for sample in 0..<source.sampleCount {
                if sample.isMultiple(of: 512) {
                    presentation.retarget(source.positions[sample/512].map {
                        DTSXDynamicSpatialModel.image(position: $0,layout: layout)
                    })
                }
                presentation.advance()
                for channel in reference.indices {
                    var rendered = Double(source.fixedPlanes[channel][sample])
                    for slot in 0..<4 { rendered += Double(source.dynamicPlanes[slot][sample])*presentation.gains[slot][channel] }
                    guard abs(rendered-Double(reference[channel][sample])) <= 1 else {
                        throw DTSError.malformed("Dynamic reduction lost the native speaker image")
                    }
                }
            }
            guard source.aggregation?.fixedBedCarriesSpatialResidual == true else {
                throw DTSError.malformed("Dynamic fixed bed omitted its spatial residual")
            }
            residualCases += 1
        }
        var streamCases = 0
        for vision in DTSXVision.allCases {
            for coding in DTSEncodeMode.allCases {
                var originals: [DTSObjectMode: Data] = [:]
                // Alternating modes in one process catches shared gain,
                // aggregation, coding-plan and private-provider state leaks.
                for (run,object) in [DTSObjectMode.dynamic,.channelbase,.dynamic,.channelbase].enumerated() {
                    let output = folder.appendingPathComponent("\(vision.rawValue)-\(coding.rawValue)-\(run).dtshd")
                    let report = try DTSAutomaticEncoder.encode(inputURL: manifest,outputURL: output,
                        encodeMode: coding,dtsxVision: vision,objectMode: object)
                    let bytes = try Data(contentsOf: output)
                    if let previous = originals[object] {
                        guard previous == bytes else { throw DTSError.malformed("Object mode invocation changed a repeated stream") }
                    } else { originals[object] = bytes }
                    guard report.objectMode == object,report.encodeMode == coding,
                          FileManager.default.fileExists(atPath: report.deliveryArtifacts.pbrPath),
                          FileManager.default.fileExists(atPath: report.deliveryArtifacts.logPath) else {
                        throw DTSError.malformed("Object mode report or delivery sidecars missing")
                    }
                    let first = try DTSStreamInspector().inspect(url: output,maximumAccessUnits: 1)[0]
                    guard let start = Int(exactly: first.byteOffset),start <= bytes.count,
                          first.byteCount <= bytes.count-start else { throw DTSError.malformed("Invalid regression AU range") }
                    let au = try DTSOfficialStreamASTParser.parseAccessUnit(bytes.subdata(in: start..<start+first.byteCount))
                    let xll = try XLLFrameASTParser.parse(ExSSParser().parse(frame: au.exss.serialize()).xllData)
                    guard DTSXDynamicPrivateFrame.isDynamic(xll.privateData) == (object == .dynamic) else {
                        throw DTSError.malformed("Object mode selected the other presentation's private syntax")
                    }
                    if object == .dynamic {
                        let frame = try DTSXDynamicPrivateFrame.parse(xll.privateData)
                        let metadata = try DTSXDynamicStreamInspector.inspectMetadata(input: output)
                        guard frame.metadata.reservedTFC == (vision == .imax),report.dynamicEncoding?.dynamicObjectCount == 4,
                              report.dynamicEncoding?.reservedIMAXObjectCount == (vision == .imax ? 1 : 0),
                              metadata.declaredObjectRecordCount == (vision == .imax ? 5 : 4),
                              metadata.dynamicObjectCount == 4,metadata.matchesSelectedHeightFoldProfile,
                              !metadata.audioDecoded,
                              report.objectMetadataDisposition == (vision == .imax ? .aggregatedToFourDynamicObjectsWithReservedIMAXTFC : .aggregatedToFourDynamicObjects) else {
                            throw DTSError.malformed("Dynamic slots or reserved IMAX role differ")
                        }
                    } else {
                        guard report.dynamicEncoding == nil,
                              report.objectMetadataDisposition == (vision == .imax ? .renderedToIMAX : .renderedToSevenOneFour) else {
                            throw DTSError.malformed("Channelbase invoked dynamic aggregation")
                        }
                    }
                    streamCases += 1
                }
                // Direct legacy rendering/encoding remains byte-identical to
                // channelbase dispatch, for both visions and coding modes.
                let direct = folder.appendingPathComponent("direct.dtshd")
                if vision == .imax {
                    _ = try DTSIMAXNativeHDMAEncoder(encodeMode: coding).encode(source: DTSIMAXRenderer.render(master: master),to: direct,frameRate: .fps24)
                } else {
                    _ = try DTSXNativeHDMAEncoder(encodeMode: coding).encode(source: DTS714Renderer.render(master: master),to: direct,frameRate: .fps24)
                }
                guard try Data(contentsOf: direct) == originals[.channelbase] else { throw DTSError.malformed("Channelbase changed established encoder output") }
            }
        }
        let implicit = folder.appendingPathComponent("default.dtshd")
        let explicit = folder.appendingPathComponent("dynamic.dtshd")
        let defaultReport = try DTSAutomaticEncoder.encode(inputURL: manifest,outputURL: implicit)
        _ = try DTSAutomaticEncoder.encode(inputURL: manifest,outputURL: explicit,objectMode: .dynamic)
        guard defaultReport.objectMode == .dynamic,try Data(contentsOf: implicit) == Data(contentsOf: explicit) else {
            throw DTSError.malformed("Typed default does not select dynamic")
        }
        let implicitIMAX = folder.appendingPathComponent("default-imax.dtshd")
        let explicitIMAX = folder.appendingPathComponent("channelbase-imax.dtshd")
        let imaxReport = try DTSAutomaticEncoder.encode(inputURL: manifest,outputURL: implicitIMAX,dtsxVision: .imax)
        _ = try DTSAutomaticEncoder.encode(inputURL: manifest,outputURL: explicitIMAX,dtsxVision: .imax,objectMode: .channelbase)
        guard imaxReport.objectMode == .channelbase,imaxReport.dynamicEncoding == nil,
              try Data(contentsOf: implicitIMAX) == Data(contentsOf: explicitIMAX) else {
            throw DTSError.malformed("Typed IMAX default does not preserve channelbase")
        }
        let pcmURL = folder.appendingPathComponent("plain.wav")
        let pcm = try PCMBuffer(format: PCMFormat(sampleRate: 48_000,bitDepth: 24,layout: .fiveOneSide),
            planes: Array(repeating: Array(repeating: Int32(12345),count: 1025),count: 6))
        try WaveFile.write(pcm,to: pcmURL)
        var plainBytes: Data?
        for object in DTSObjectMode.allCases {
            let output = folder.appendingPathComponent("plain-\(object.rawValue).dtshd")
            let report = try DTSAutomaticEncoder.encode(inputURL: pcmURL,outputURL: output,frameRateOverride: .fps24,objectMode: object)
            let bytes = try Data(contentsOf: output)
            guard report.objectMode == nil,report.dynamicEncoding == nil,report.objectMetadataDisposition == .notApplicable,
                  plainBytes == nil || plainBytes == bytes else { throw DTSError.malformed("Object mode altered ordinary PCM") }
            plainBytes = bytes
        }
        return ["selectorCases":parserCases,"invalidOptionsRejected":invalid.count,"alternatingStreamCases":streamCases,
                "legacyEncoderIdentityCases":4,"typedDefaultIdentityCases":2,"plainPCMIdentityCases":2,
                "fullSpeakerImageResidualCases":residualCases,
                "officialPlaybackQualified":0]
    }

    private static func writeFixture(folder: URL) throws -> URL {
        let count = 2049
        var payload = Data()
        for sample in 0..<count {
            for (frequency,magnitude) in [(997.0,12000.0),(311.0,90000.0),(173.0,70000.0)] {
                let value = Int32((sin(2 * .pi*frequency*Double(sample)/48000)*magnitude).rounded())
                let raw = UInt32(bitPattern: value)
                payload.append(contentsOf: [UInt8(raw&255),UInt8((raw>>8)&255),UInt8((raw>>16)&255)])
            }
        }
        var caf = Data("caff".utf8)
        func big(_ value: UInt64,_ bytes: Int) { for index in (0..<bytes).reversed() { caf.append(UInt8((value >> (index*8))&255)) } }
        big(1,2); big(0,2); caf.append(Data("desc".utf8));big(32,8);big(Double(48000).bitPattern,8)
        caf.append(Data("lpcm".utf8));big(12,4);big(9,4);big(1,4);big(3,4);big(24,4)
        caf.append(Data("data".utf8));big(UInt64(payload.count+4),8);big(0,4);caf.append(payload)
        try caf.write(to: folder.appendingPathComponent("音频.caf"))
        let manifest = folder.appendingPathComponent("场景.atmos")
        try Data("""
        version: 1
        metadata: scene.metadata
        audio: 音频.caf
        offset: 0
        ffoa: 0
        fps: 24
        bed:
          - channel: L
            ID: 1
        objects:
          - ID: 10
          - ID: 11
        """.utf8).write(to: manifest)
        try Data("""
        sampleRate: 48000
        - ID: 10
          samplePos: 0
          active: true
          pos: [0, 1, 0]
        - ID: 11
          samplePos: 0
          active: true
          pos: [0, 1, 1]
        - ID: 10
          samplePos: 700
          pos: [-1, 1, 0]
        """.utf8).write(to: folder.appendingPathComponent("scene.metadata"))
        return manifest
    }
}
