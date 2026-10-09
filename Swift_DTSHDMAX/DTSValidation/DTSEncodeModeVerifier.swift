import Foundation

public struct DTSEncodeModeVerificationReport: Sendable, Codable {
    public let defaultIsAuto: Bool
    public let standardHasNoPrediction: Bool
    public let automaticallySelectedPartitions: [Int]
    public let privateProviderCalledOncePerFrame: Bool
    public let deterministic: Bool
    public let publicAndPrivatePCMExact: Bool
    public var isVerified: Bool {
        defaultIsAuto && standardHasNoPrediction
            && Set(automaticallySelectedPartitions) == Set([2, 4, 8])
            && privateProviderCalledOncePerFrame && deterministic && publicAndPrivatePCMExact
    }
}

/// Real candidate search, not a forced-partition test. These bounded vectors
/// never become presentation playback files; complete programmes qualify UI.
public enum DTSEncodeModeVerifier {
    public static func verify() throws -> DTSEncodeModeVerificationReport {
        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .sevenOne)
        let core = try PCMBuffer(
            format: PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .fiveOneSide),
            planes: [[Int32]](repeating: [Int32](repeating: 0, count: 512), count: 6)
        )
        let privateEncoder = DTSXPrivateFrameEncoder(codingMode: .terminalPredictiveOfficial)
        var counts: [Int] = []
        var once = true
        var deterministic = true
        var exact = true
        for group in [512, 128, 64] {
            let planes = (0..<8).map { channel -> [Int32] in
                var state = UInt32(0x9e37_79b9 &+ UInt32(channel) &* 17)
                return (0..<512).map { sample in
                    state = state &* 1_664_525 &+ 1_013_904_223
                    if group == 512 { return 0 }
                    let magnitude: Int64 = (sample / group).isMultiple(of: 2) ? 64 : 1_000_000
                    return Int32((Int64(state >> 16) - 32_768) * magnitude / 32_768)
                }
            }
            let pcm = try PCMBuffer(format: format, planes: planes)
            let heights = Array(planes.suffix(4))
            func encode() throws -> XLLEncodedFrame {
                var calls = 0
                let encoded = try XLLEncoder(codingMode: .terminalAutomaticPredictive).encode(
                    frame: pcm, useSevenOneHierarchy: true, coreReconstruction: core,
                    coreAssociationPolicy: .fullPrimaryChannels,
                    privateExtensionProvider: { plan in
                        calls += 1
                        return try privateEncoder.encode(codedPlanes: heights, segmentationPlan: plan, forcesNavigation: true)
                    }
                )
                once = once && calls == 1
                return encoded
            }
            let encoded = try encode()
            let repeated = try encode()
            deterministic = deterministic && encoded.data == repeated.data
            let ast = try XLLFrameASTParser.parse(encoded.data)
            counts.append(ast.segmentCount)
            let privateAST = try DTSXPrivateFrameAST.parse(ast.privateData[...])
            let navigation = try privateAST.parseNavigation(segmentCount: ast.segmentCount, sharedSegmentSizeBitCount: ast.segmentSizeBitCount)
            let decodedPrivate = try DTSXPrivateIsolatedFrameDecoder.decodeGeneric(
                privateAST, entropyPrefixByteCount: 2 + navigation.serializedByteCount,
                segmentCount: ast.segmentCount, segmentSampleCount: ast.segmentSampleCount
            )
            let publicPCM = try XLLCoreReconstructor.reconstruct(XLLDecoder().decodeChannelSets(frame: encoded.data), core: core)
            let comparison = try PCMComparator.compare(pcm, publicPCM)
            exact = exact && decodedPrivate.codedPlanes == heights && comparison.isBitExact
        }
        let standardPCM = try PCMBuffer(format: format, planes: (0..<8).map { channel in
            (0..<512).map { sample in
                Int32((sin(2 * Double.pi * Double((sample + 1) * (channel + 1)) / 512) * 1_000_000).rounded())
            }
        })
        let standardData = try XLLEncoder(codingMode: DTSEncodeMode.standard.publicXLLCodingMode).encode(frame: standardPCM)
        let standard = try XLLDecoder().decodeChannelSets(frame: standardData.data)
        let directHeights = Array(standardPCM.planes.suffix(4))
        let privateData = try DTSXPrivateFrameEncoder(codingMode: DTSEncodeMode.standard.privateXLLXCodingMode).encode(codedPlanes: directHeights)
        let header = try DTSXPrivateFrameAST.parse(privateData[...]).parsePredictionHeaderCandidate()
        return DTSEncodeModeVerificationReport(
            defaultIsAuto: DTSXNativeHDMAEncoder().publicXLLCodingMode == .terminalAutomaticPredictive
                && DTSXNativeHDMAEncoder().privateXLLXCodingMode == .terminalPredictiveOfficial,
            standardHasNoPrediction: standard.channelSets.allSatisfy {
                $0.adaptivePredictionOrders.allSatisfy { $0 == 0 } && $0.fixedPredictionOrders.allSatisfy { $0 == 0 }
            } && header.adaptivePredictionOrders.allSatisfy { $0 == 0 } && header.fixedPredictionOrders.allSatisfy { $0 == 0 },
            automaticallySelectedPartitions: counts, privateProviderCalledOncePerFrame: once,
            deterministic: deterministic, publicAndPrivatePCMExact: exact
        )
    }
}
