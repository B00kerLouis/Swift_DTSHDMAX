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
    public let containerNavigationBoundaryOffsetsVerified: Bool
    public let compactSilenceNavigationWidthsVerified: Bool
    public var isVerified: Bool {
        rejectsUncoupledPrivateFrame && containerNavigationBoundaryOffsetsVerified
            && compactSilenceNavigationWidthsVerified
            && !vectors.isEmpty && vectors.allSatisfy {
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
        var reports: [DTSXNavigationWidthVectorReport] = []
        let modes: [(XLLCodingMode, DTSXPrivateCodingMode)] = [
            (.terminalOfficialRice, .terminalRiceOfficial),
            (.terminalOfficialPredictive, .terminalRiceOfficial),
            (.terminalOfficialRice, .terminalPredictiveOfficial),
            (.terminalOfficialPredictive, .terminalPredictiveOfficial),
            (.terminalAutomaticPredictive, .terminalPredictiveOfficial)
        ]
        for (modeIndex, mode) in modes.enumerated() {
        let publicEncoder = XLLEncoder(codingMode: mode.0)
        let privateEncoder = DTSXPrivateFrameEncoder(codingMode: mode.1)
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
                name: "mode-\(modeIndex)-\(name)",
                segmentCount: segments,
                publicWidth: publicAST.segmentSizeBitCount,
                privateWidth: navigation.bitWidth,
                privatePCMIsBitExact: privateDecoded.codedPlanes == heights,
                publicPCMIsBitExact: try PCMComparator.compare(pcm, publicDecoded).isBitExact
            ))
        }
        }
        // A standalone private frame has no enclosing width to constrain it.
        // Such a payload must be rejected when attached to a wider public NAVI.
        let incompatiblePrivate = try DTSXPrivateFrameEncoder(codingMode: .terminalRiceOfficial).encode(
            codedPlanes: planes(channels: 4, amplitude: 127), forcesNavigation: true
        )
        var rejectsUncoupled = false
        do {
            _ = try XLLEncoder(codingMode: .terminalOfficialRice).encode(
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
            vectors: reports, rejectsUncoupledPrivateFrame: rejectsUncoupled,
            containerNavigationBoundaryOffsetsVerified: try verifyContainerNavigationBoundaries(),
            compactSilenceNavigationWidthsVerified: try verifyCompactSilenceNavigationWidths()
        )
    }

    private static func verifyContainerNavigationBoundaries() throws -> Bool {
        let offsets = [0, 0x00ff_fffc, 0x0100_0000, 0x01ff_fffc,
                       0x0200_0000, 0x7fff_fffc, 0x8000_0000, Int(UInt32.max)]
        let payload = try DTSHDFileContainer.navigationTablePayload(accessUnitOffsets: offsets)
        var reader = try BitReader(data: payload)
        guard try reader.read(32, field: "file NAVI count") == UInt64(offsets.count),
              try reader.read(16, field: "file NAVI interval") == 1,
              try reader.read(8, field: "file NAVI offset width") == 4 else { return false }
        for offset in offsets {
            guard try reader.read(32, field: "file NAVI offset") == UInt64(offset) else { return false }
        }
        guard try reader.read(8, field: "file NAVI padding") == 0,
              reader.bitOffset == payload.count * 8 else { return false }
        for invalid in [[0, -1], [0, 0], [0, Int(UInt32.max) + 1]] {
            do {
                _ = try DTSHDFileContainer.navigationTablePayload(accessUnitOffsets: invalid)
                return false
            } catch DTSError.valueOutOfRange { }
        }
        return true
    }

    private static func verifyCompactSilenceNavigationWidths() throws -> Bool {
        let encoder = DTSXPrivateFrameEncoder(codingMode: .terminalPredictiveOfficial)
        let zeros = [[Int32]](repeating: [Int32](repeating: 0, count: 512), count: 4)
        let routing = try DTSXPrivateRouting(codedPlaneToHeightPermutation: [0, 1, 2, 3], branchCode: 0)
        for segments in [2, 4] {
            for width in 7...XLLSyntax.segmentSizeBitCount {
                let plan = try XLLSegmentationPlan(
                    segmentCount: segments, segmentSampleCount: 512 / segments,
                    segmentSizeBitCount: width, navigationByteCount: (width * segments * 2 + 7) / 8 + 2,
                    segmentEntropyByteCounts: [[Int]](repeating: [1, 1], count: segments)
                )
                let data = segments == 2
                    ? try encoder.encodeTerminalMidstreamTwoSegmentSilence(codedPlanes: zeros, routing: routing, segmentationPlan: plan)
                    : try encoder.encodeTerminalNoNavigationFourSegmentSilence(codedPlanes: zeros, routing: routing, segmentationPlan: plan)
                let ast = try DTSXPrivateFrameAST.parse(data[...])
                let navigation = try ast.parseNavigation(segmentCount: segments, sharedSegmentSizeBitCount: width)
                let decoded = try DTSXPrivateFrameDecoder.decode(ast, segmentCount: segments, segmentSampleCount: 512 / segments)
                guard ast.headerCRCIsValid, try ast.parsePredictionCRC().isValid,
                      navigation.bitWidth == max(8, width),
                      navigation.segmentByteCounts == [2] + Array(repeating: 1, count: segments - 1),
                      decoded.codedPlanes == zeros else { return false }
                if width == 11, segments == 2 {
                    // Former fixed 0x20 "control" still decodes zero locally,
                    // but is invalid when the enclosing public width is seven.
                    do {
                        _ = try ast.parseNavigation(segmentCount: 2, sharedSegmentSizeBitCount: 7)
                        return false
                    } catch DTSError.malformed { }
                }
            }
        }
        return true
    }
}
