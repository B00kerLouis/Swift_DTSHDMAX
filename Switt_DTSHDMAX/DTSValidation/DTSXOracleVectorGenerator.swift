import Foundation

public struct DTSXOracleEncoderSettings: Sendable, Equatable, Codable {
    public let encoderVersion: String
    public let inputLayout: String
    public let sampleRate: Int
    public let bitDepth: Int
    public let outputFormat: String
    public let encodingMode: String
    public let coreBitrateKbps: Int
    public let preconditioningEnabled: Bool
    public let automaticPBREnabled: Bool
    public let dialogNormalizationDBFS: Int
    public let evidenceLogs: [String]
}

public struct DTSXOracleVectorChannelFile: Sendable, Equatable, Codable {
    public let channel: DTS714Channel
    public let relativePath: String
    public let sampleCount: Int
    public let pcmSHA256: String
    public let waveByteCount: UInt64
    public let waveSHA256: String
}

public struct DTSXOracleVector: Sendable, Equatable, Codable {
    public let identifier: String
    public let description: String
    public let activeChannels: [DTS714Channel]
    public let aggregatePCM_SHA256: String
    public let channels: [DTSXOracleVectorChannelFile]
}

public struct DTSXOracleVectorManifest: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let bitDepth: Int
    public let sampleCount: Int
    public let frameSampleCount: Int
    public let frameCount: Int
    public let channelOrder: [DTS714Channel]
    public let aggregatePCMEncoding: String
    public let authoringProfile: DTS714AuthoringProfile
    public let officialEncoderSettings: DTSXOracleEncoderSettings
    public let vectors: [DTSXOracleVector]
}

public struct DTSXOracleVectorGenerationReport: Sendable, Equatable, Codable {
    public let outputDirectory: String
    public let manifestPath: String
    public let manifestSHA256: String
    public let vectorCount: Int
    public let waveFileCount: Int
}

public enum DTSXOracleVectorGenerator {
    public static let frameSampleCount = 512
    public static let frameCount = 4
    public static let sampleCount = frameSampleCount * frameCount

    private struct VectorDefinition {
        let identifier: String
        let description: String
        let activeChannels: [DTS714Channel]
        let planes: [[Int32]]
    }

    public static func generate(outputDirectory: URL) throws -> DTSXOracleVectorGenerationReport {
        let profile = try DTS714AuthoringProfile.official.validated()
        let output = outputDirectory.standardizedFileURL
        let fileManager = FileManager.default
        let parent = output.deletingLastPathComponent()
        guard !output.lastPathComponent.isEmpty else {
            throw DTSError.invalidArgument("DTS:X Oracle vector output directory must have a final path component")
        }
        try prepareDestination(output, parent: parent, fileManager: fileManager)

        let temporary = parent.appendingPathComponent(
            ".\(output.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        } catch {
            throw DTSError.io("cannot create temporary Oracle directory \(temporary.path): \(error.localizedDescription)")
        }
        defer { try? fileManager.removeItem(at: temporary) }

        let definitions = makeDefinitions()
        var vectors: [DTSXOracleVector] = []
        vectors.reserveCapacity(definitions.count)
        for definition in definitions {
            vectors.append(try write(definition, root: temporary))
        }

        let manifest = DTSXOracleVectorManifest(
            schemaVersion: 1,
            sampleRate: DTS714PCMBuffer.sampleRate,
            bitDepth: DTS714PCMBuffer.bitDepth,
            sampleCount: sampleCount,
            frameSampleCount: frameSampleCount,
            frameCount: frameCount,
            channelOrder: DTS714Channel.allCases,
            aggregatePCMEncoding: DTS714SourceSet.canonicalEncoding + "; channel-major concatenation",
            authoringProfile: profile,
            officialEncoderSettings: DTSXOracleEncoderSettings(
                encoderVersion: "1.2.1.90:11",
                inputLayout: "7.1.4",
                sampleRate: DTS714PCMBuffer.sampleRate,
                bitDepth: DTS714PCMBuffer.bitDepth,
                outputFormat: "Blu-ray/UHD .dtshd",
                encodingMode: "DTS:X Master Audio",
                coreBitrateKbps: 1_509,
                preconditioningEnabled: false,
                automaticPBREnabled: true,
                dialogNormalizationDBFS: -31,
                evidenceLogs: [
                    "Research/test_X/ALL_MUTE_X/ALL_MUTE.dtshd_log.txt",
                    "Research/reference-streams/DTSX/Dolby_Natures_Fury_HDMAX_BD.dtshd_log.txt"
                ]
            ),
            vectors: vectors
        )
        let manifestURL = temporary.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            throw DTSError.io("cannot write Oracle manifest \(manifestURL.path): \(error.localizedDescription)")
        }
        let manifestSHA256 = try SHA256Hasher.hash(fileAt: manifestURL)

        do {
            try fileManager.moveItem(at: temporary, to: output)
        } catch {
            throw DTSError.io("cannot publish Oracle directory \(output.path): \(error.localizedDescription)")
        }
        let publishedManifest = output.appendingPathComponent("manifest.json")
        return DTSXOracleVectorGenerationReport(
            outputDirectory: output.path,
            manifestPath: publishedManifest.path,
            manifestSHA256: manifestSHA256,
            vectorCount: vectors.count,
            waveFileCount: vectors.reduce(0) { $0 + $1.channels.count }
        )
    }

    private static func prepareDestination(
        _ output: URL,
        parent: URL,
        fileManager: FileManager
    ) throws {
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw DTSError.io("cannot create Oracle parent directory \(parent.path): \(error.localizedDescription)")
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: output.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else {
            throw DTSError.invalidArgument("Oracle output path exists and is not a directory: \(output.path)")
        }
        let existing: [URL]
        do {
            existing = try fileManager.contentsOfDirectory(
                at: output,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DTSError.io("cannot inspect Oracle output directory \(output.path): \(error.localizedDescription)")
        }
        guard existing.isEmpty else {
            throw DTSError.invalidArgument("Oracle output directory must be empty: \(output.path)")
        }
        do {
            try fileManager.removeItem(at: output)
        } catch {
            throw DTSError.io("cannot replace empty Oracle output directory \(output.path): \(error.localizedDescription)")
        }
    }

    private static func write(_ definition: VectorDefinition, root: URL) throws -> DTSXOracleVector {
        let directory = root.appendingPathComponent(definition.identifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            throw DTSError.io("cannot create Oracle vector directory \(directory.path): \(error.localizedDescription)")
        }
        for (index, channel) in DTS714Channel.allCases.enumerated() {
            let label = DTS714SourceSet.sourceFileLabel(for: channel)
            try WaveFile.writeMono24(
                definition.planes[index],
                to: directory.appendingPathComponent("input.\(label).wav")
            )
        }

        let sourceReport = try DTS714SourceSet.inspect(directory: directory)
        let files = try sourceReport.channels.map { channelReport in
            let url = URL(fileURLWithPath: channelReport.sourcePath)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
            catch {
                throw DTSError.io("cannot inspect \(url.path): \(error.localizedDescription)")
            }
            guard let byteCount = attributes[.size] as? NSNumber else {
                throw DTSError.io("cannot determine file size for \(url.path)")
            }
            return DTSXOracleVectorChannelFile(
                channel: channelReport.channel,
                relativePath: "\(definition.identifier)/\(url.lastPathComponent)",
                sampleCount: channelReport.sampleCount,
                pcmSHA256: channelReport.pcmSHA256,
                waveByteCount: byteCount.uint64Value,
                waveSHA256: try SHA256Hasher.hash(fileAt: url)
            )
        }
        return DTSXOracleVector(
            identifier: definition.identifier,
            description: definition.description,
            activeChannels: definition.activeChannels,
            aggregatePCM_SHA256: sourceReport.sourcePCMHash,
            channels: files
        )
    }

    private static func makeDefinitions() -> [VectorDefinition] {
        var definitions: [VectorDefinition] = [
            VectorDefinition(
                identifier: "all-mute",
                description: "All twelve inputs are zero for four 512-sample access units.",
                activeChannels: [],
                planes: emptyPlanes()
            )
        ]
        for channel in DTS714Channel.allCases {
            definitions.append(impulseDefinition(channel: channel, sample: 8_388_607, polarity: "positive"))
            definitions.append(impulseDefinition(channel: channel, sample: -8_388_608, polarity: "negative"))
        }
        let heightChannels: [DTS714Channel] = [
            .leftFrontHeight, .rightFrontHeight, .leftRearHeight, .rightRearHeight
        ]
        for channel in heightChannels {
            var planes = emptyPlanes()
            planes[index(of: channel)] = (0..<sampleCount).map { $0.isMultiple(of: 2) ? 0 : 1 }
            definitions.append(VectorDefinition(
                identifier: "lsb-toggle-\(slug(channel))",
                description: "\(channel.rawValue) alternates between zero and one 24-bit LSB; all other inputs are zero.",
                activeChannels: [channel],
                planes: planes
            ))
        }

        let frontSignal = deterministicSignal(seed: 0x6a09_e667)
        definitions.append(pairBaseline(
            identifier: "pair-lfh-only",
            description: "Front-height pair baseline: only Lfh carries the deterministic signal.",
            first: .leftFrontHeight,
            signal: frontSignal
        ))
        definitions.append(pairVariant(
            identifier: "pair-lfh-rfh-identical",
            description: "Single-variable variant of pair-lfh-only: Rfh adds the identical signal.",
            first: .leftFrontHeight,
            second: .rightFrontHeight,
            firstSignal: frontSignal,
            secondSignal: frontSignal
        ))
        definitions.append(pairVariant(
            identifier: "pair-lfh-rfh-opposed",
            description: "Front heights carry equal-magnitude opposite-polarity deterministic signals.",
            first: .leftFrontHeight,
            second: .rightFrontHeight,
            firstSignal: frontSignal,
            secondSignal: frontSignal.map(-)
        ))

        let rearSignal = deterministicSignal(seed: 0xbb67_ae85)
        definitions.append(pairBaseline(
            identifier: "pair-lrh-only",
            description: "Rear-height pair baseline: only Lrh carries the deterministic signal.",
            first: .leftRearHeight,
            signal: rearSignal
        ))
        definitions.append(pairVariant(
            identifier: "pair-lrh-rrh-identical",
            description: "Single-variable variant of pair-lrh-only: Rrh adds the identical signal.",
            first: .leftRearHeight,
            second: .rightRearHeight,
            firstSignal: rearSignal,
            secondSignal: rearSignal
        ))
        definitions.append(pairVariant(
            identifier: "pair-lrh-rrh-opposed",
            description: "Rear heights carry equal-magnitude opposite-polarity deterministic signals.",
            first: .leftRearHeight,
            second: .rightRearHeight,
            firstSignal: rearSignal,
            secondSignal: rearSignal.map(-)
        ))

        var heightQuad = emptyPlanes()
        for channel in heightChannels { heightQuad[index(of: channel)] = frontSignal }
        definitions.append(VectorDefinition(
            identifier: "height-quad-identical",
            description: "All four height inputs carry the same deterministic signal.",
            activeChannels: heightChannels,
            planes: heightQuad
        ))
        return definitions
    }

    private static func impulseDefinition(
        channel: DTS714Channel,
        sample: Int32,
        polarity: String
    ) -> VectorDefinition {
        var planes = emptyPlanes()
        planes[index(of: channel)][frameSampleCount] = sample
        return VectorDefinition(
            identifier: "impulse-\(polarity)-\(slug(channel))",
            description: "\(channel.rawValue) has one \(polarity) full-scale impulse at sample 512; all other samples are zero.",
            activeChannels: [channel],
            planes: planes
        )
    }

    private static func pairBaseline(
        identifier: String,
        description: String,
        first: DTS714Channel,
        signal: [Int32]
    ) -> VectorDefinition {
        var planes = emptyPlanes()
        planes[index(of: first)] = signal
        return VectorDefinition(
            identifier: identifier,
            description: description,
            activeChannels: [first],
            planes: planes
        )
    }

    private static func pairVariant(
        identifier: String,
        description: String,
        first: DTS714Channel,
        second: DTS714Channel,
        firstSignal: [Int32],
        secondSignal: [Int32]
    ) -> VectorDefinition {
        var planes = emptyPlanes()
        planes[index(of: first)] = firstSignal
        planes[index(of: second)] = secondSignal
        return VectorDefinition(
            identifier: identifier,
            description: description,
            activeChannels: [first, second],
            planes: planes
        )
    }

    private static func deterministicSignal(seed: UInt32) -> [Int32] {
        var state = seed
        return (0..<sampleCount).map { sampleIndex in
            state = state &* 1_664_525 &+ 1_013_904_223
            var sample = Int32(state & 0x000f_ffff) - 0x0008_0000
            if sampleIndex.isMultiple(of: frameSampleCount) {
                sample = Int32((sampleIndex / frameSampleCount + 1) * 65_537)
            }
            return sample
        }
    }

    private static func emptyPlanes() -> [[Int32]] {
        Array(
            repeating: [Int32](repeating: 0, count: sampleCount),
            count: DTS714Channel.allCases.count
        )
    }

    private static func index(of channel: DTS714Channel) -> Int {
        DTS714Channel.allCases.firstIndex(of: channel)!
    }

    private static func slug(_ channel: DTS714Channel) -> String {
        channel.rawValue.lowercased()
    }
}
