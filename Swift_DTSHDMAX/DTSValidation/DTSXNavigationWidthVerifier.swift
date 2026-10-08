import Foundation

public struct DTSXNavigationWidthVectorReport: Sendable, Equatable, Codable {
    public let name: String
    public let segmentCount: Int
    public let publicWidth: Int
    public let privateWidth: Int
    public let privatePCMIsBitExact: Bool
    public let publicPCMIsBitExact: Bool
}

public struct DTSXNavigationWidthVerificationReport: Sendable, Equatable, Codable {
    public let vectors: [DTSXNavigationWidthVectorReport]
    public let rejectsUncoupledPrivateFrame: Bool
    public var isVerified: Bool {
        rejectsUncoupledPrivateFrame && !vectors.isEmpty && vectors.allSatisfy {
            $0.privateWidth == max(8, $0.publicWidth)
                && $0.privatePCMIsBitExact && $0.publicPCMIsBitExact
        }
    }
}

/// In-memory boundary vectors: these do not create short playback files.
/// Decode the private entropy from the header-declared NAVI location rather
/// than using the isolated decoder's inferred width as the correctness oracle.
public enum DTSXNavigationWidthVerifier {
    public static func verify() throws -> DTSXNavigationWidthVerificationReport {
        let count = XLLSyntax.frameSampleCount
        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .sevenOne)
        let core = try PCMBuffer(
            format: PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .fiveOneSide),
            planes: Array(repeating: [Int32](repeating: 0, count: count), count: 6)
        )
        func planes(channels: Int, amplitude: Int32, sparse: Bool = false) -> [[Int32]] {
            (0..<channels).map { channel in
                (0..<count).map { sample in
                    if sparse && sample % 127 != channel { return 0 }
                    let code = (sample * 7_919 + channel * 10_007) % 65_521
                    return Int32(Int64(amplitude) * Int64(code - 32_760) / 32_760)
                }
            }
        }
        let cases: [(String, Int32, Int32, Int, Bool)] = [
            ("zero-at-minimum-width", 0, 0, 2, false),
            ("private-widens-quiet-public", 0, 127, 2, false),
            ("public-widens-zero-heights", 8_000_000, 0, 2, false),
            ("sparse-private-transient", 511, 7_000_000, 2, true),
            ("wide-public-and-private", 8_000_000, 4_000_000, 2, false),
            ("four-segment-width", 32_767, 4_000_000, 4, false),
            ("eight-segment-width", 8_000_000, 4_000_000, 8, false)
        ]
        let publicEncoder = XLLEncoder(codingMode: .terminalOfficialRice)
        let privateEncoder = DTSXPrivateFrameEncoder(codingMode: .terminalRiceOfficial)
        var reports: [DTSXNavigationWidthVectorReport] = []
        for (name, publicAmplitude, privateAmplitude, segments, sparse) in cases {
            let pcm = try PCMBuffer(format: format, planes: planes(channels: 8, amplitude: publicAmplitude))
            let heights = planes(channels: 4, amplitude: privateAmplitude, sparse: sparse)
            let encoded = try publicEncoder.encode(
                frame: pcm,
                useSevenOneHierarchy: true,
                coreReconstruction: core,
                coreAssociationPolicy: .fullPrimaryChannels,
                privateExtensionProvider: { plan in
                    try privateEncoder.encode(
                        codedPlanes: heights,
                        segmentationPlan: plan,
                        forcesNavigation: true
                    )
                },
                forcedSegmentCount: segments
            )
            let publicAST = try XLLFrameASTParser.parse(encoded.data)
            let privateAST = try DTSXPrivateFrameAST.parse(publicAST.privateData[...])
            let navigation = try privateAST.parseNavigation(
                segmentCount: segments,
                sharedSegmentSizeBitCount: publicAST.segmentSizeBitCount
            )
            let privateDecoded = try DTSXPrivateIsolatedFrameDecoder.decodeGeneric(
                privateAST,
                entropyPrefixByteCount: 2 + navigation.serializedByteCount,
                segmentCount: segments,
                segmentSampleCount: count / segments
            )
            let publicDecoded = try XLLCoreReconstructor.reconstruct(
                XLLDecoder().decodeChannelSets(frame: encoded.data), core: core
            )
            reports.append(DTSXNavigationWidthVectorReport(
                name: name,
                segmentCount: segments,
                publicWidth: publicAST.segmentSizeBitCount,
                privateWidth: navigation.bitWidth,
                privatePCMIsBitExact: privateDecoded.codedPlanes == heights,
                publicPCMIsBitExact: try PCMComparator.compare(pcm, publicDecoded).isBitExact
            ))
        }
        // A standalone private frame has no enclosing width to constrain it.
        // Such a payload must be rejected when attached to a wider public NAVI.
        let incompatiblePrivate = try privateEncoder.encode(
            codedPlanes: planes(channels: 4, amplitude: 127), forcesNavigation: true
        )
        var rejectsUncoupled = false
        do {
            _ = try publicEncoder.encode(
                frame: PCMBuffer(format: format, planes: planes(channels: 8, amplitude: 8_000_000)),
                useSevenOneHierarchy: true,
                coreReconstruction: core,
                coreAssociationPolicy: .fullPrimaryChannels,
                privateExtension: incompatiblePrivate,
                forcedSegmentCount: 2
            )
        } catch DTSError.malformed(let reason) {
            rejectsUncoupled = reason.contains("NAVI width")
        }
        return DTSXNavigationWidthVerificationReport(
            vectors: reports, rejectsUncoupledPrivateFrame: rejectsUncoupled
        )
    }
}
