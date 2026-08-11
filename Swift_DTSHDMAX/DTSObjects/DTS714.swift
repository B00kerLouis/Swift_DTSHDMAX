import Foundation

/// Canonical DTS:X 7.1.4 input order used by the DTS:X Encoder Suite logs.
/// It is deliberately separate from `DTSChannelLayout`: public DTS-HD XLL
/// only describes the 7.1 compatibility bed, while the four height feeds are
/// carried by the DTS:X private extension.
public enum DTS714Channel: String, CaseIterable, Sendable, Codable, Hashable {
    case left = "L"
    case right = "R"
    case center = "C"
    case lfe = "LFE"
    case leftSideSurround = "Lss"
    case rightSideSurround = "Rss"
    case leftRearSurround = "Lsr"
    case rightRearSurround = "Rsr"
    case leftFrontHeight = "Lfh"
    case rightFrontHeight = "Rfh"
    case leftRearHeight = "Lrh"
    case rightRearHeight = "Rrh"
}

public struct DTS714PCMBuffer: Sendable, Equatable {
    public static let sampleRate = 48_000
    public static let bitDepth = 24

    public let planes: [[Int32]]

    public init(planes: [[Int32]]) throws {
        guard planes.count == DTS714Channel.allCases.count else {
            throw DTSError.malformed(
                "expected \(DTS714Channel.allCases.count) DTS:X 7.1.4 PCM planes, found \(planes.count)"
            )
        }
        let sampleCount = planes.first?.count ?? 0
        guard planes.allSatisfy({ $0.count == sampleCount }) else {
            throw DTSError.malformed("DTS:X 7.1.4 PCM plane lengths differ")
        }
        for (channel, plane) in planes.enumerated() {
            if let invalid = plane.first(where: { $0 < -8_388_608 || $0 > 8_388_607 }) {
                throw DTSError.valueOutOfRange(
                    field: "DTS:X 7.1.4 pcm.channel[\(channel)]",
                    value: String(invalid)
                )
            }
        }
        self.planes = planes
    }

    public var sampleCount: Int { planes.first?.count ?? 0 }

    public subscript(_ channel: DTS714Channel) -> [Int32] {
        planes[DTS714Channel.allCases.firstIndex(of: channel)!]
    }
}

public struct DTS714Route: Sendable, Equatable, Codable {
    public let channel: DTS714Channel
    /// Q30 linear gain. This keeps bed routing deterministic and avoids a
    /// floating-point gain ambiguity before the object renderer is introduced.
    public let gainQ30: Int64
}

public enum DTS714ChannelMapper {
    public static let unityQ30: Int64 = 1 << 30
    /// The supplied Dolby 7.1.4 re-render applies 511/512 headroom to every
    /// non-LFE contribution. This value is exact in Q30.
    public static let renderHeadroomQ30: Int64 = unityQ30 * 511 / 512
    /// `round((511/512) * 2^30 / sqrt(2))`, the exact coefficient recovered
    /// from the supplied Lts/Rts -> front/rear-height reference samples.
    public static let halfPowerQ30: Int64 = 757_767_215

    /// Maps the known Dolby bed labels into the DTS:X 7.1.4 PCM contract.
    /// A Dolby top-side feed has no one-to-one DTS:X 7.1.4 destination, so it
    /// is energy-split equally between the front and rear height feeds.
    public static func routes(for source: DTSSpeakerPosition) -> [DTS714Route] {
        switch source {
        case .left: [DTS714Route(channel: .left, gainQ30: renderHeadroomQ30)]
        case .right: [DTS714Route(channel: .right, gainQ30: renderHeadroomQ30)]
        case .center: [DTS714Route(channel: .center, gainQ30: renderHeadroomQ30)]
        case .lfe1: [DTS714Route(channel: .lfe, gainQ30: unityQ30)]
        case .leftSideSurround, .leftSurround:
            [DTS714Route(channel: .leftSideSurround, gainQ30: renderHeadroomQ30)]
        case .rightSideSurround, .rightSurround:
            [DTS714Route(channel: .rightSideSurround, gainQ30: renderHeadroomQ30)]
        case .leftRearSurround:
            [DTS714Route(channel: .leftRearSurround, gainQ30: renderHeadroomQ30)]
        case .rightRearSurround:
            [DTS714Route(channel: .rightRearSurround, gainQ30: renderHeadroomQ30)]
        case .leftHeightSide:
            [
                DTS714Route(channel: .leftFrontHeight, gainQ30: halfPowerQ30),
                DTS714Route(channel: .leftRearHeight, gainQ30: halfPowerQ30)
            ]
        case .rightHeightSide:
            [
                DTS714Route(channel: .rightFrontHeight, gainQ30: halfPowerQ30),
                DTS714Route(channel: .rightRearHeight, gainQ30: halfPowerQ30)
            ]
        case .centerSurround:
            [
                DTS714Route(channel: .leftRearSurround, gainQ30: halfPowerQ30),
                DTS714Route(channel: .rightRearSurround, gainQ30: halfPowerQ30)
            ]
        }
    }
}

/// The three requested delivery names. The supplied Nature's Fury DTS:X
/// oracle currently contains one byte-identical elementary stream for all
/// three names, so they share one syntax profile until a differing oracle is
/// supplied.
public enum DTSXDeliveryMode: String, CaseIterable, Sendable, Codable {
    case bluRayDisc = "blue-ray-disc"
    case digitalDelivery = "digital-delivery"
    case scsa

    public init(option: String) throws {
        switch option {
        case "--blue-ray-disc", "-bd": self = .bluRayDisc
        case "--digital-delivery", "--digtal-delivery", "-dd": self = .digitalDelivery
        case "--scsa", "-scsa": self = .scsa
        default:
            throw DTSError.invalidArgument(
                "DTS:X delivery mode must be --blue-ray-disc|-bd, --digital-delivery|-dd, or --scsa|-scsa"
            )
        }
    }
}

    /// A deterministic authoring contract. `dtsx-plan` exposes this before the
    /// encoder stage so an Atmos master can never be accidentally routed into
    /// the ordinary HDMA path.
public struct DTSXEncodingPlan: Sendable, Equatable, Codable {
    public let deliveryMode: DTSXDeliveryMode
    public let inputPath: String
    public let sampleRate: Int
    public let bitDepth: Int
    public let sampleCount: UInt64
    public let bedChannelCount: Int
    public let objectCount: Int
    public let outputChannels: [DTS714Channel]
    public let coreBitrateKbps: Int
    public let privateXLLXEncodingAvailable: Bool

    public init(
        deliveryMode: DTSXDeliveryMode,
        inputPath: String,
        sampleRate: Int,
        bitDepth: Int,
        sampleCount: UInt64,
        bedChannelCount: Int,
        objectCount: Int
    ) throws {
        guard sampleRate == DTS714PCMBuffer.sampleRate, bitDepth == DTS714PCMBuffer.bitDepth else {
            throw DTSError.unsupported("DTS:X 7.1.4 planning requires 48 kHz packed 24-bit PCM")
        }
        guard bedChannelCount > 0, objectCount > 0 else {
            throw DTSError.malformed("DTS:X Atmos input must contain a bed and at least one object")
        }
        self.deliveryMode = deliveryMode
        self.inputPath = inputPath
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.sampleCount = sampleCount
        self.bedChannelCount = bedChannelCount
        self.objectCount = objectCount
        outputChannels = DTS714Channel.allCases
        coreBitrateKbps = 1_509
        // The native branch-zero encoder now serializes prediction, entropy,
        // NAVI and CRC fields from arbitrary four-plane 7.1.4 height PCM and
        // verifies every frame through the independent private decoder.
        privateXLLXEncodingAvailable = true
    }
}

public struct DTSXReferenceArtifact: Sendable, Equatable, Codable {
    public let deliveryMode: DTSXDeliveryMode
    public let dtshdPath: String
    public let dtshdByteCount: UInt64
    /// Published shell-verified SHA-256 for the supplied Nature's Fury oracle.
    /// File equality is checked byte-for-byte below; this value is not derived
    /// by the slow debug-only Swift SHA-256 implementation on every inspection.
    public let canonicalDtshdSHA256: String
    public let dtspbrPath: String
    public let dtspbrByteCount: UInt64
    public let canonicalDtspbrSHA256: String
}

public struct DTSXReferenceSetReport: Sendable, Equatable, Codable {
    public let artifacts: [DTSXReferenceArtifact]
    public let dtshdFilesAreByteIdentical: Bool
    public let dtspbrFilesAreByteIdentical: Bool
    public let dtshdFilesMatchCanonicalReference: Bool
    public let dtspbrFilesMatchCanonicalReference: Bool
}

public enum DTSXReferenceSet {
    private static let canonicalDtshdSHA256 =
        "aac7ab3d927174b1414e008d41bcfcdafbbf18428836058ce2b8cf2e0db0d1c6"
    private static let canonicalDtspbrSHA256 =
        "2a55ff6a771cb1ddff97feb674f10f1d6ece5aafc97af420c9e51ece71f639fb"

    public static func inspect(directory: URL) throws -> DTSXReferenceSetReport {
        let root = directory.standardizedFileURL
        let stems: [(DTSXDeliveryMode, String)] = [
            (.bluRayDisc, "Dolby_Natures_Fury_HDMAX_BD"),
            (.digitalDelivery, "Dolby_Natures_Fury_HDMAX_Digital_Delivery"),
            (.scsa, "Dolby_Natures_Fury_HDMAX_SCSA")
        ]
        let artifacts = try stems.map { mode, stem in
            let dtshd = root.appendingPathComponent(stem).appendingPathExtension("dtshd")
            let dtspbr = root.appendingPathComponent(stem).appendingPathExtension("dtspbr")
            return DTSXReferenceArtifact(
                deliveryMode: mode,
                dtshdPath: dtshd.path,
                dtshdByteCount: try fileByteCount(dtshd),
                canonicalDtshdSHA256: canonicalDtshdSHA256,
                dtspbrPath: dtspbr.path,
                dtspbrByteCount: try fileByteCount(dtspbr),
                canonicalDtspbrSHA256: canonicalDtspbrSHA256
            )
        }
        let dtshdFilesAreByteIdentical = try filesAreByteIdentical(
            URL(fileURLWithPath: artifacts[0].dtshdPath),
            URL(fileURLWithPath: artifacts[1].dtshdPath)
        ) && filesAreByteIdentical(
            URL(fileURLWithPath: artifacts[0].dtshdPath),
            URL(fileURLWithPath: artifacts[2].dtshdPath)
        )
        let dtspbrFilesAreByteIdentical = try filesAreByteIdentical(
            URL(fileURLWithPath: artifacts[0].dtspbrPath),
            URL(fileURLWithPath: artifacts[1].dtspbrPath)
        ) && filesAreByteIdentical(
            URL(fileURLWithPath: artifacts[0].dtspbrPath),
            URL(fileURLWithPath: artifacts[2].dtspbrPath)
        )
        let referenceDtshdHash = try SHA256Hasher.hash(fileAt: URL(fileURLWithPath: artifacts[0].dtshdPath))
        let referenceDtspbrHash = try SHA256Hasher.hash(fileAt: URL(fileURLWithPath: artifacts[0].dtspbrPath))
        return DTSXReferenceSetReport(
            artifacts: artifacts,
            dtshdFilesAreByteIdentical: dtshdFilesAreByteIdentical,
            dtspbrFilesAreByteIdentical: dtspbrFilesAreByteIdentical,
            dtshdFilesMatchCanonicalReference: dtshdFilesAreByteIdentical
                && referenceDtshdHash == canonicalDtshdSHA256,
            dtspbrFilesMatchCanonicalReference: dtspbrFilesAreByteIdentical
                && referenceDtspbrHash == canonicalDtspbrSHA256
        )
    }

    private static func filesAreByteIdentical(_ lhs: URL, _ rhs: URL) throws -> Bool {
        guard try fileByteCount(lhs) == fileByteCount(rhs) else { return false }
        let lhsHandle: FileHandle
        let rhsHandle: FileHandle
        do {
            lhsHandle = try FileHandle(forReadingFrom: lhs)
            rhsHandle = try FileHandle(forReadingFrom: rhs)
        } catch {
            throw DTSError.io("cannot open DTS:X reference files: \(error.localizedDescription)")
        }
        defer {
            try? lhsHandle.close()
            try? rhsHandle.close()
        }
        while true {
            let lhsChunk: Data
            let rhsChunk: Data
            do {
                lhsChunk = try lhsHandle.read(upToCount: 1 << 20) ?? Data()
                rhsChunk = try rhsHandle.read(upToCount: 1 << 20) ?? Data()
            } catch {
                throw DTSError.io("cannot compare DTS:X reference files: \(error.localizedDescription)")
            }
            guard lhsChunk == rhsChunk else { return false }
            if lhsChunk.isEmpty { return true }
        }
    }

    private static func fileByteCount(_ url: URL) throws -> UInt64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw DTSError.io("cannot determine input size: \(url.path)")
            }
            return size.uint64Value
        } catch let error as DTSError {
            throw error
        } catch {
            throw DTSError.io("cannot inspect \(url.path): \(error.localizedDescription)")
        }
    }
}

public struct DTS714ChannelComparison: Sendable, Equatable, Codable {
    public let channel: DTS714Channel
    public let referencePath: String
    public let expectedSampleCount: Int
    public let actualSampleCount: Int
    public let firstMismatchSample: Int?
    public let expectedSample: Int32?
    public let actualSample: Int32?
    public let maximumAbsoluteDifference: Int64
    public let mismatchedSampleCount: Int
    public let meanAbsoluteDifference: Double
    public let rootMeanSquareDifference: Double
    public let isBitExact: Bool
}

public struct DTS714PCMComparison: Sendable, Equatable, Codable {
    public let channels: [DTS714ChannelComparison]
    public let isBitExact: Bool
}

/// Strict description of the twelve mono PCM inputs recorded in the DTS:X
/// Encoder log. They are post-render 7.1.4 feeds for the encoder, rather than
/// PCM extracted from the DTS:X elementary stream.
public struct DTS714SourceChannelReport: Sendable, Equatable, Codable {
    public let channel: DTS714Channel
    public let sourcePath: String
    public let sampleCount: Int
    public let pcmSHA256: String
}

public struct DTS714SourceSetReport: Sendable, Equatable, Codable {
    public let canonicalEncoding: String
    public let sampleRate: Int
    public let bitDepth: Int
    public let channelOrder: [DTS714Channel]
    public let sampleCount: Int
    public let sourcePCMHash: String
    public let channels: [DTS714SourceChannelReport]
}

/// Reports every gate required before a DTS:X `.dtshd` file may be emitted.
/// A byte-identical reference container alone is insufficient: the rendered
/// 7.1.4 PCM and the XLL-X object payload must also be proven closed.
public struct DTSXQualificationReport: Sendable, Equatable, Codable {
    public let deliveryMode: DTSXDeliveryMode
    public let inputPath: String
    public let encodingPlan: DTSXEncodingPlan
    public let sourceSet: DTS714SourceSetReport
    public let renderedPCM: DTS714PCMComparison
    public let referenceSet: DTSXReferenceSetReport
    public let privateXLLXEncodingAvailable: Bool
    public let isQualifiedForDTSXEmission: Bool

    public init(
        deliveryMode: DTSXDeliveryMode,
        inputPath: String,
        encodingPlan: DTSXEncodingPlan,
        sourceSet: DTS714SourceSetReport,
        renderedPCM: DTS714PCMComparison,
        referenceSet: DTSXReferenceSetReport
    ) {
        self.deliveryMode = deliveryMode
        self.inputPath = inputPath
        self.encodingPlan = encodingPlan
        self.sourceSet = sourceSet
        self.renderedPCM = renderedPCM
        self.referenceSet = referenceSet
        privateXLLXEncodingAvailable = encodingPlan.privateXLLXEncodingAvailable
        isQualifiedForDTSXEmission = renderedPCM.isBitExact
            && referenceSet.dtshdFilesAreByteIdentical
            && referenceSet.dtspbrFilesAreByteIdentical
            && referenceSet.dtshdFilesMatchCanonicalReference
            && referenceSet.dtspbrFilesMatchCanonicalReference
            && encodingPlan.privateXLLXEncodingAvailable
    }
}

public enum DTS714SourceSet {
    public static let canonicalEncoding = "s24le mono PCM in DTS:X 7.1.4 encoder input order"

    /// Reconstructs the legacy 7.1 compatibility bed selected by the supplied
    /// DTS:X Encoder Suite log. Front and rear height pairs are folded into
    /// their corresponding horizontal feeds at -3.0103 dB (shown rounded as
    /// 3.0 dB in the log); side surrounds remain
    /// independent. The returned planes use WAVE 7.1 order.
    public static func loadLegacySevenOne(directory: URL) throws -> PCMBuffer {
        try DTS714CompatibilityBedRenderer.render(load(directory: directory))
    }

    /// Loads exactly one mono 48 kHz/24-bit source for each DTS:X input.
    /// Planes are ordered for the DTS:X encoder: L, R, C, LFE, Lss, Rss,
    /// Lsr, Rsr, Lfh, Rfh, Lrh, Rrh.
    public static func load(directory: URL) throws -> DTS714PCMBuffer {
        try readSources(directory: directory).buffer
    }

    public static func inspect(directory: URL) throws -> DTS714SourceSetReport {
        let source = try readSources(directory: directory)
        return DTS714SourceSetReport(
            canonicalEncoding: canonicalEncoding,
            sampleRate: DTS714PCMBuffer.sampleRate,
            bitDepth: DTS714PCMBuffer.bitDepth,
            channelOrder: DTS714Channel.allCases,
            sampleCount: source.buffer.sampleCount,
            sourcePCMHash: hash(planes: source.buffer.planes),
            channels: source.paths.enumerated().map { index, path in
                DTS714SourceChannelReport(
                    channel: DTS714Channel.allCases[index],
                    sourcePath: path.path,
                    sampleCount: source.buffer.planes[index].count,
                    pcmSHA256: hash(planes: [source.buffer.planes[index]])
                )
            }
        )
    }

    private static func readSources(directory: URL) throws -> (buffer: DTS714PCMBuffer, paths: [URL]) {
        let root = directory.standardizedFileURL
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DTSError.io("cannot enumerate DTS:X source directory \(root.path): \(error.localizedDescription)")
        }

        var paths: [URL] = []
        var planes: [[Int32]] = []
        for channel in DTS714Channel.allCases {
            let label = sourceFileLabel(for: channel)
            let acceptedNames = Set([label, channel.rawValue]).map { "\($0).wav" }
            let matches = urls.filter {
                let name = $0.lastPathComponent
                return acceptedNames.contains(name)
                    || acceptedNames.contains(where: { name.hasSuffix(".\($0)") })
            }
            guard matches.count == 1 else {
                throw DTSError.malformed(
                    "expected one DTS:X source WAVE matching \(acceptedNames.sorted().joined(separator: " or ")), found \(matches.count)"
                )
            }
            paths.append(matches[0])
            planes.append(try WaveFile.readMono24(from: matches[0]))
        }
        return (try DTS714PCMBuffer(planes: planes), paths)
    }

    public static func sourceFileLabel(for channel: DTS714Channel) -> String {
        switch channel {
        case .leftRearSurround: "Lrs"
        case .rightRearSurround: "Rrs"
        case .leftFrontHeight: "Ltf"
        case .rightFrontHeight: "Rtf"
        case .leftRearHeight: "Ltr"
        case .rightRearHeight: "Rtr"
        default: channel.rawValue
        }
    }

    private static func hash(planes: [[Int32]]) -> String {
        var hasher = SHA256Hasher()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(1 << 16)
        for plane in planes {
            for value in plane {
                let sample = UInt32(bitPattern: value) & 0x00ff_ffff
                bytes.append(UInt8(sample & 0xff))
                bytes.append(UInt8((sample >> 8) & 0xff))
                bytes.append(UInt8((sample >> 16) & 0xff))
                if bytes.count >= 1 << 16 {
                    hasher.update(bytes)
                    bytes.removeAll(keepingCapacity: true)
                }
            }
        }
        hasher.update(bytes)
        return hasher.finalizeHex()
    }
}

/// Builds the lossless 7.1 compatibility bed carried by the public Core/XLL
/// layers of the supplied 7.1.4 DTS:X profile. The four height feeds remain
/// independently available to XLL-X; this renderer only applies the logged
/// Q15 legacy fold used by non-DTS:X decoders.
public struct DTS714CompatibilityBedChannelDiagnostics: Sendable, Equatable, Codable {
    public let outputChannel: DTS714Channel
    public let sampleCount: Int
    public let maximumAbsoluteUnclippedSample: Int64
    public let positiveHardClipCount: Int
    public let negativeHardClipCount: Int
    public let firstHardClipSample: Int?
    public let maximumPositiveExcess: Int64
    public let maximumNegativeExcess: Int64

    public var hardClipCount: Int { positiveHardClipCount + negativeHardClipCount }
}

public struct DTS714CompatibilityBedDiagnostics: Sendable, Equatable, Codable {
    public let channels: [DTS714CompatibilityBedChannelDiagnostics]

    public var hardClipCount: Int {
        channels.reduce(0) { $0 + $1.hardClipCount }
    }

    public var hasHardClipping: Bool { hardClipCount != 0 }
}

public enum DTS714CompatibilityBedRenderer {
    public static func render(_ source: DTS714PCMBuffer) throws -> PCMBuffer {
        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .sevenOne)
        return try PCMBuffer(
            format: format,
            planes: [
                mixLegacyHeight(source[.left], source[.leftFrontHeight]).plane,
                mixLegacyHeight(source[.right], source[.rightFrontHeight]).plane,
                source[.center],
                source[.lfe],
                mixLegacyHeight(source[.leftRearSurround], source[.leftRearHeight]).plane,
                mixLegacyHeight(source[.rightRearSurround], source[.rightRearHeight]).plane,
                source[.leftSideSurround],
                source[.rightSideSurround]
            ]
        )
    }

    /// Reports every hard clamp that the fixed Q15 legacy-height fold would
    /// apply. The production render remains unchanged; this is deliberately a
    /// measurement surface rather than an implicit limiter.
    public static func diagnose(_ source: DTS714PCMBuffer) -> DTS714CompatibilityBedDiagnostics {
        let channels = [
            (DTS714Channel.left, source[.left], source[.leftFrontHeight]),
            (DTS714Channel.right, source[.right], source[.rightFrontHeight]),
            (DTS714Channel.leftRearSurround, source[.leftRearSurround], source[.leftRearHeight]),
            (DTS714Channel.rightRearSurround, source[.rightRearSurround], source[.rightRearHeight])
        ].map { outputChannel, bed, height in
            mixLegacyHeight(bed, height).diagnostics(outputChannel: outputChannel)
        }
        return DTS714CompatibilityBedDiagnostics(channels: channels)
    }

    private static func mixLegacyHeight(
        _ bed: [Int32],
        _ height: [Int32]
    ) -> LegacyHeightMix {
        precondition(bed.count == height.count)
        // round(2^15 / sqrt(2)); the encoder UI displays this as 3.0 dB.
        // The Q15 quantization is observable in the lossless 7.1 bed: using
        // a higher-precision coefficient changes millions of samples by 1 LSB.
        let heightGainQ15: Int64 = 23_170
        let halfQ15: Int64 = 1 << 14
        var plane: [Int32] = []
        plane.reserveCapacity(bed.count)
        var maximumAbsoluteUnclippedSample: Int64 = 0
        var positiveHardClipCount = 0
        var negativeHardClipCount = 0
        var firstHardClipSample: Int?
        var maximumPositiveExcess: Int64 = 0
        var maximumNegativeExcess: Int64 = 0
        for sample in bed.indices {
            let bedSample = bed[sample]
            let heightSample = height[sample]
            let product = Int64(heightSample) * heightGainQ15
            let contribution = (product + halfQ15) >> 15
            let unclipped = Int64(bedSample) + contribution
            maximumAbsoluteUnclippedSample = max(
                maximumAbsoluteUnclippedSample,
                Swift.abs(unclipped)
            )
            if unclipped > 8_388_607 {
                positiveHardClipCount += 1
                firstHardClipSample = firstHardClipSample ?? sample
                maximumPositiveExcess = max(maximumPositiveExcess, unclipped - 8_388_607)
            } else if unclipped < -8_388_608 {
                negativeHardClipCount += 1
                firstHardClipSample = firstHardClipSample ?? sample
                maximumNegativeExcess = max(maximumNegativeExcess, -8_388_608 - unclipped)
            }
            plane.append(Int32(clamping: min(
                Int64(8_388_607),
                max(Int64(-8_388_608), unclipped)
            )))
        }
        return LegacyHeightMix(
            plane: plane,
            maximumAbsoluteUnclippedSample: maximumAbsoluteUnclippedSample,
            positiveHardClipCount: positiveHardClipCount,
            negativeHardClipCount: negativeHardClipCount,
            firstHardClipSample: firstHardClipSample,
            maximumPositiveExcess: maximumPositiveExcess,
            maximumNegativeExcess: maximumNegativeExcess
        )
    }

    private struct LegacyHeightMix {
        let plane: [Int32]
        let maximumAbsoluteUnclippedSample: Int64
        let positiveHardClipCount: Int
        let negativeHardClipCount: Int
        let firstHardClipSample: Int?
        let maximumPositiveExcess: Int64
        let maximumNegativeExcess: Int64

        func diagnostics(
            outputChannel: DTS714Channel
        ) -> DTS714CompatibilityBedChannelDiagnostics {
            DTS714CompatibilityBedChannelDiagnostics(
                outputChannel: outputChannel,
                sampleCount: plane.count,
                maximumAbsoluteUnclippedSample: maximumAbsoluteUnclippedSample,
                positiveHardClipCount: positiveHardClipCount,
                negativeHardClipCount: negativeHardClipCount,
                firstHardClipSample: firstHardClipSample,
                maximumPositiveExcess: maximumPositiveExcess,
                maximumNegativeExcess: maximumNegativeExcess
            )
        }
    }

}

/// Compares the rendered DTS:X 7.1.4 PCM contract against the twelve mono
/// source files supplied with a DTS:X reference stream. This check is strict:
/// any sample-count or integer-sample difference fails the comparison.
public enum DTS714ReferenceComparator {
    public static func compare(
        rendered: DTS714PCMBuffer,
        referenceDirectory: URL
    ) throws -> DTS714PCMComparison {
        let root = referenceDirectory.standardizedFileURL
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DTSError.io("cannot enumerate 7.1.4 reference directory \(root.path): \(error.localizedDescription)")
        }
        let comparisons = try DTS714Channel.allCases.enumerated().map { index, channel in
            let reference = try referenceWave(for: channel, in: urls)
            let expected = try WaveFile.readMono24(from: reference)
            let actual = rendered.planes[index]
            return makeChannelComparison(
                channel: channel,
                referencePath: reference.path,
                expected: expected,
                actual: actual
            )
        }
        return DTS714PCMComparison(
            channels: comparisons,
            isBitExact: comparisons.allSatisfy(\.isBitExact)
        )
    }

    public static func compare(
        renderedDirectory: URL,
        referenceDirectory: URL
    ) throws -> DTS714PCMComparison {
        let renderedRoot = renderedDirectory.standardizedFileURL
        let referenceRoot = referenceDirectory.standardizedFileURL
        let referenceURLs = try directoryFiles(referenceRoot)
        let comparisons = try DTS714Channel.allCases.map { channel in
            let reference = try referenceWave(for: channel, in: referenceURLs)
            let rendered = renderedRoot.appendingPathComponent("\(channel.rawValue).wav")
            let expected = try WaveFile.readMono24(from: reference)
            let actual = try WaveFile.readMono24(from: rendered)
            return makeChannelComparison(
                channel: channel,
                referencePath: reference.path,
                expected: expected,
                actual: actual
            )
        }
        return DTS714PCMComparison(
            channels: comparisons,
            isBitExact: comparisons.allSatisfy(\.isBitExact)
        )
    }

    private static func directoryFiles(_ root: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DTSError.io("cannot enumerate 7.1.4 reference directory \(root.path): \(error.localizedDescription)")
        }
    }

    private static func referenceWave(for channel: DTS714Channel, in urls: [URL]) throws -> URL {
        // The DTS:X source labels its rear surrounds `Lsr/Rsr`; the supplied
        // Dolby re-render source files use the equivalent Dolby spelling
        // `Lrs/Rrs` in their filenames.
        let sourceLabel: String
        switch channel {
        case .leftRearSurround: sourceLabel = "Lrs"
        case .rightRearSurround: sourceLabel = "Rrs"
        case .leftFrontHeight: sourceLabel = "Ltf"
        case .rightFrontHeight: sourceLabel = "Rtf"
        case .leftRearHeight: sourceLabel = "Ltr"
        case .rightRearHeight: sourceLabel = "Rtr"
        default: sourceLabel = channel.rawValue
        }
        let suffix = ".\(sourceLabel).wav"
        let matches = urls.filter { $0.lastPathComponent.hasSuffix(suffix) }
        guard matches.count == 1 else {
            throw DTSError.malformed("expected one 7.1.4 reference WAVE ending in \(suffix), found \(matches.count)")
        }
        return matches[0]
    }

    private static func makeChannelComparison(
        channel: DTS714Channel,
        referencePath: String,
        expected: [Int32],
        actual: [Int32]
    ) -> DTS714ChannelComparison {
        let commonCount = min(expected.count, actual.count)
        var firstMismatch: Int?
        var largestDifference: Int64 = 0
        var mismatchedSampleCount = 0
        var absoluteDifferenceSum = 0.0
        var squaredDifferenceSum = 0.0
        for sample in 0..<commonCount {
            let difference = Swift.abs(Int64(expected[sample]) - Int64(actual[sample]))
            largestDifference = max(largestDifference, difference)
            if difference != 0 {
                mismatchedSampleCount += 1
                if firstMismatch == nil { firstMismatch = sample }
            }
            let floatingDifference = Double(difference)
            absoluteDifferenceSum += floatingDifference
            squaredDifferenceSum += floatingDifference * floatingDifference
        }
        let missingSampleCount = Swift.abs(expected.count - actual.count)
        mismatchedSampleCount += missingSampleCount
        if missingSampleCount != 0, firstMismatch == nil { firstMismatch = commonCount }
        let mismatch = firstMismatch
        let metricSampleCount = max(1, commonCount)
        return DTS714ChannelComparison(
            channel: channel,
            referencePath: referencePath,
            expectedSampleCount: expected.count,
            actualSampleCount: actual.count,
            firstMismatchSample: mismatch,
            expectedSample: mismatch.flatMap { $0 < expected.count ? expected[$0] : nil },
            actualSample: mismatch.flatMap { $0 < actual.count ? actual[$0] : nil },
            maximumAbsoluteDifference: largestDifference,
            mismatchedSampleCount: mismatchedSampleCount,
            meanAbsoluteDifference: absoluteDifferenceSum / Double(metricSampleCount),
            rootMeanSquareDifference: sqrt(squaredDifferenceSum / Double(metricSampleCount)),
            isBitExact: mismatch == nil
        )
    }
}
