import Foundation

public struct DTSXPrivateControlledPairTransformSummary: Sendable, Equatable, Codable {
    public let name: String
    public let sourcePlane: Int?
    public let destinationPlane: Int
    public let coefficient: Int?
    public let frameCount: Int
}

public struct DTSXPrivateControlledPairAnalysisReport: Sendable, Equatable, Codable {
    public let baselineIndexPath: String
    public let baselinePayloadPath: String
    public let variantIndexPath: String
    public let variantPayloadPath: String
    public let baselinePayloadSHA256: String
    public let variantPayloadSHA256: String
    public let frameCount: Int
    public let identicalFrameCount: Int
    public let changedFrameCount: Int
    public let baselineCandidateHeaderFrameCount: Int
    public let variantCandidateHeaderFrameCount: Int
    public let baselineDecodedFrameCount: Int
    public let variantDecodedFrameCount: Int
    public let baselineUniqueTrailingZeroPrefixFrameCount: Int
    public let variantUniqueTrailingZeroPrefixFrameCount: Int
    public let baselineEntropyPrefixFrequencies: [DTSXValueFrequency]
    public let variantEntropyPrefixFrequencies: [DTSXValueFrequency]
    public let baselineBranchFrequencies: [DTSXValueFrequency]
    public let variantBranchFrequencies: [DTSXValueFrequency]
    public let baselineSideInfoFrequencies: [DTSXHexFrequency]
    public let variantSideInfoFrequencies: [DTSXHexFrequency]
    public let baselineSideInfoCRCValidFrameCount: Int
    public let variantSideInfoCRCValidFrameCount: Int
    public let lfhDirectMatchFrameCount: Int
    public let lfhBestTransformExactFrameCount: Int
    public let lfhBestTransformSampleMatchCount: Int64
    public let lfhComparedSampleCount: Int64
    public let transformExactFrameCounts: [DTSXPrivateControlledPairTransformSummary]
    public let firstFailureFrameIndex: Int?
    public let firstFailureDetail: String?
    public let allChangedFramesDecoded: Bool
}

/// Compares two authorized DTS:X encodes whose common height source is Lfh.
/// The analyzer does not use an external decoder or an assumed pink-noise
/// waveform. It decodes the recovered private entropy candidate in both
/// streams, applies each stream's typed routing word, and tests whether the
/// Lfh plane is preserved directly or through the public XLL-style reversible
/// pair transform. This is evidence collection only; it never mutates a
/// reference payload.
public enum DTSXPrivateControlledPairAnalyzer {
    private static let frameSampleCount = 512
    private static let entropyPrefixCandidates = Array(2...15)
    private static let coefficientCandidates = Array(-64...63)

    private struct DecodedObservation {
        let ast: DTSXPrivateFrameAST
        let decoded: DTSXPrivateIsolatedDecodedFrame
        let selectedPrefix: Int
        let uniqueTrailingZeroPrefix: Bool
    }

    private struct TransformKey: Hashable {
        let name: String
        let sourcePlane: Int?
        let destinationPlane: Int
        let coefficient: Int?
    }

    private struct TransformMatch {
        let key: TransformKey
        let sampleMatchCount: Int
    }

    public static func analyze(
        baselineIndexURL: URL,
        baselinePayloadURL: URL,
        variantIndexURL: URL,
        variantPayloadURL: URL,
        outputURL: URL
    ) throws -> DTSXPrivateControlledPairAnalysisReport {
        let baseline = try DTSXPrivateArtifactLoader.load(
            indexURL: baselineIndexURL,
            payloadURL: baselinePayloadURL
        )
        let variant = try DTSXPrivateArtifactLoader.load(
            indexURL: variantIndexURL,
            payloadURL: variantPayloadURL
        )
        guard baseline.records.count == variant.records.count else {
            throw DTSError.invalidArgument(
                "XLL-X controlled pair analysis requires equal private-frame counts"
            )
        }

        var identicalFrameCount = 0
        var changedFrameCount = 0
        var baselineCandidateCount = 0
        var variantCandidateCount = 0
        var baselineDecodedCount = 0
        var variantDecodedCount = 0
        var baselineUniquePrefixCount = 0
        var variantUniquePrefixCount = 0
        var baselinePrefixCounts: [Int: Int] = [:]
        var variantPrefixCounts: [Int: Int] = [:]
        var baselineBranches: [Int: Int] = [:]
        var variantBranches: [Int: Int] = [:]
        var baselineSideInfo: [String: Int] = [:]
        var variantSideInfo: [String: Int] = [:]
        var baselineSideInfoCRCValidCount = 0
        var variantSideInfoCRCValidCount = 0
        var lfhDirectMatchFrameCount = 0
        var lfhBestTransformExactFrameCount = 0
        var lfhBestTransformSampleMatchCount: Int64 = 0
        var lfhComparedSampleCount: Int64 = 0
        var transformCounts: [TransformKey: Int] = [:]
        var firstFailureFrameIndex: Int?
        var firstFailureDetail: String?

        func recordFailure(_ frameIndex: Int, _ detail: String) {
            guard firstFailureFrameIndex == nil else { return }
            firstFailureFrameIndex = frameIndex
            firstFailureDetail = detail
        }

        for position in baseline.records.indices {
            let baselineRecord = baseline.records[position]
            let variantRecord = variant.records[position]
            guard baselineRecord.frameIndex == variantRecord.frameIndex else {
                throw DTSError.malformed("XLL-X controlled pair frame indices are not aligned")
            }
            let baselineBytes = Data(baseline.frameBytes(baselineRecord))
            let variantBytes = Data(variant.frameBytes(variantRecord))
            if baselineBytes == variantBytes {
                identicalFrameCount += 1
            } else {
                changedFrameCount += 1
            }

            if let ast = try? DTSXPrivateFrameAST.parse(baselineBytes[...]),
               (try? ast.parsePredictionHeaderCandidate()) != nil {
                baselineCandidateCount += 1
                baselineBranches[ast.candidateSecondaryBranchCode, default: 0] += 1
                if let sideInfo = try? sideInfoData(ast) {
                    baselineSideInfo[hex(sideInfo), default: 0] += 1
                    if DTSCRC16.checksum(sideInfo) == 0 { baselineSideInfoCRCValidCount += 1 }
                }
            }
            if let ast = try? DTSXPrivateFrameAST.parse(variantBytes[...]),
               (try? ast.parsePredictionHeaderCandidate()) != nil {
                variantCandidateCount += 1
                variantBranches[ast.candidateSecondaryBranchCode, default: 0] += 1
                if let sideInfo = try? sideInfoData(ast) {
                    variantSideInfo[hex(sideInfo), default: 0] += 1
                    if DTSCRC16.checksum(sideInfo) == 0 { variantSideInfoCRCValidCount += 1 }
                }
            }

            let baselineObservation: DecodedObservation?
            do {
                baselineObservation = try observe(baselineBytes)
                if baselineObservation != nil { baselineDecodedCount += 1 }
            } catch {
                baselineObservation = nil
                recordFailure(baselineRecord.frameIndex, "baseline: \(error)")
            }
            let variantObservation: DecodedObservation?
            do {
                variantObservation = try observe(variantBytes)
                if variantObservation != nil { variantDecodedCount += 1 }
            } catch {
                variantObservation = nil
                recordFailure(variantRecord.frameIndex, "variant: \(error)")
            }

            if let observation = baselineObservation {
                baselinePrefixCounts[observation.selectedPrefix, default: 0] += 1
                if observation.uniqueTrailingZeroPrefix { baselineUniquePrefixCount += 1 }
            }
            if let observation = variantObservation {
                variantPrefixCounts[observation.selectedPrefix, default: 0] += 1
                if observation.uniqueTrailingZeroPrefix { variantUniquePrefixCount += 1 }
            }

            guard baselineBytes != variantBytes,
                  let baselineObservation,
                  let variantObservation else { continue }
            guard let baselineHeightPlane = try? heightPlane(
                decoded: baselineObservation.decoded,
                routing: baselineObservation.ast.routing,
                height: 0
            ) else {
                recordFailure(baselineRecord.frameIndex, "baseline routing does not expose Lfh")
                continue
            }
            guard let variantRouting = try? variantObservation.ast.routing else {
                recordFailure(variantRecord.frameIndex, "variant routing could not be parsed")
                continue
            }
            guard let variantLfhPlane = variantRouting.codedPlaneToHeightPermutation.firstIndex(of: 0),
                  let variantRfhPlane = variantRouting.codedPlaneToHeightPermutation.firstIndex(of: 1) else {
                recordFailure(variantRecord.frameIndex, "variant routing does not expose the front-height pair")
                continue
            }

            let comparison = findMatches(
                baseline: baselineHeightPlane,
                variantPlanes: variantObservation.decoded.codedPlanes,
                temporalPlanes: variantObservation.decoded.temporalPredictionPlanes,
                activePlanes: [variantLfhPlane, variantRfhPlane]
            )
            if comparison.matches.contains(where: { $0.key.name == "direct" }) {
                lfhDirectMatchFrameCount += 1
            }
            lfhComparedSampleCount += Int64(frameSampleCount)
            if !comparison.matches.isEmpty {
                lfhBestTransformSampleMatchCount += Int64(frameSampleCount)
                lfhBestTransformExactFrameCount += 1
                for match in comparison.matches {
                    transformCounts[match.key, default: 0] += 1
                }
            } else {
                lfhBestTransformSampleMatchCount += Int64(comparison.bestDirectSampleMatchCount)
                recordFailure(
                    variantRecord.frameIndex,
                    "no candidate Lfh transform for routing \(variantRouting.codedPlaneToHeightPermutation)"
                )
            }
        }

        let report = DTSXPrivateControlledPairAnalysisReport(
            baselineIndexPath: baselineIndexURL.standardizedFileURL.path,
            baselinePayloadPath: baselinePayloadURL.standardizedFileURL.path,
            variantIndexPath: variantIndexURL.standardizedFileURL.path,
            variantPayloadPath: variantPayloadURL.standardizedFileURL.path,
            baselinePayloadSHA256: SHA256Hasher.hash(baseline.payload),
            variantPayloadSHA256: SHA256Hasher.hash(variant.payload),
            frameCount: baseline.records.count,
            identicalFrameCount: identicalFrameCount,
            changedFrameCount: changedFrameCount,
            baselineCandidateHeaderFrameCount: baselineCandidateCount,
            variantCandidateHeaderFrameCount: variantCandidateCount,
            baselineDecodedFrameCount: baselineDecodedCount,
            variantDecodedFrameCount: variantDecodedCount,
            baselineUniqueTrailingZeroPrefixFrameCount: baselineUniquePrefixCount,
            variantUniqueTrailingZeroPrefixFrameCount: variantUniquePrefixCount,
            baselineEntropyPrefixFrequencies: frequencies(baselinePrefixCounts),
            variantEntropyPrefixFrequencies: frequencies(variantPrefixCounts),
            baselineBranchFrequencies: frequencies(baselineBranches),
            variantBranchFrequencies: frequencies(variantBranches),
            baselineSideInfoFrequencies: hexFrequencies(baselineSideInfo, limit: 128),
            variantSideInfoFrequencies: hexFrequencies(variantSideInfo, limit: 128),
            baselineSideInfoCRCValidFrameCount: baselineSideInfoCRCValidCount,
            variantSideInfoCRCValidFrameCount: variantSideInfoCRCValidCount,
            lfhDirectMatchFrameCount: lfhDirectMatchFrameCount,
            lfhBestTransformExactFrameCount: lfhBestTransformExactFrameCount,
            lfhBestTransformSampleMatchCount: lfhBestTransformSampleMatchCount,
            lfhComparedSampleCount: lfhComparedSampleCount,
            transformExactFrameCounts: transformCounts.map {
                DTSXPrivateControlledPairTransformSummary(
                    name: $0.key.name,
                    sourcePlane: $0.key.sourcePlane,
                    destinationPlane: $0.key.destinationPlane,
                    coefficient: $0.key.coefficient,
                    frameCount: $0.value
                )
            }.sorted {
                if $0.frameCount != $1.frameCount { return $0.frameCount > $1.frameCount }
                if $0.name != $1.name { return $0.name < $1.name }
                if $0.destinationPlane != $1.destinationPlane {
                    return $0.destinationPlane < $1.destinationPlane
                }
                return ($0.coefficient ?? 0) < ($1.coefficient ?? 0)
            },
            firstFailureFrameIndex: firstFailureFrameIndex,
            firstFailureDetail: firstFailureDetail,
            allChangedFramesDecoded: changedFrameCount > 0
                && baselineDecodedCount == baseline.records.count
                && variantDecodedCount == variant.records.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            throw DTSError.io("cannot write XLL-X controlled pair analysis: \(error.localizedDescription)")
        }
        return report
    }

    private static func observe(_ bytes: Data) throws -> DecodedObservation? {
        let ast = try DTSXPrivateFrameAST.parse(bytes[...])
        _ = try ast.parsePredictionHeaderCandidate()
        if (try? ast.parseNavigation()) != nil,
           let navigated = try? DTSXPrivateIsolatedFrameDecoder.decodeGeneric(ast) {
            return DecodedObservation(
                ast: ast,
                decoded: navigated,
                selectedPrefix: 7,
                uniqueTrailingZeroPrefix: navigated.trailingBitsAreAllZero
            )
        }
        var decoded: [(prefix: Int, value: DTSXPrivateIsolatedDecodedFrame)] = []
        decoded.reserveCapacity(entropyPrefixCandidates.count)
        for prefix in entropyPrefixCandidates {
            if let value = try? DTSXPrivateIsolatedFrameDecoder.decodeGeneric(
                ast,
                entropyPrefixByteCount: prefix
            ) {
                decoded.append((prefix, value))
            }
        }
        guard !decoded.isEmpty else { return nil }
        let zeroTrailing = decoded.filter { $0.value.trailingBitsAreAllZero }
        let selected: (prefix: Int, value: DTSXPrivateIsolatedDecodedFrame)
        if zeroTrailing.count == 1 {
            selected = zeroTrailing[0]
        } else if let seven = decoded.first(where: { $0.prefix == 7 }) {
            selected = seven
        } else {
            selected = decoded.max {
                $0.value.entropyEndBitOffset < $1.value.entropyEndBitOffset
            }!
        }
        return DecodedObservation(
            ast: ast,
            decoded: selected.value,
            selectedPrefix: selected.prefix,
            uniqueTrailingZeroPrefix: zeroTrailing.count == 1
        )
    }

    private static func sideInfoData(_ ast: DTSXPrivateFrameAST) throws -> Data {
        let crc = try ast.parsePredictionCRC()
        let start = crc.bodyByteOffset + 2
        let end = min(start + 5, ast.body.count)
        guard start <= end else { throw DTSError.malformed("XLL-X side-info boundary is invalid") }
        return Data(ast.body[start..<end])
    }

    private static func heightPlane(
        decoded: DTSXPrivateIsolatedDecodedFrame,
        routing: DTSXPrivateRouting,
        height: Int
    ) throws -> [Int32] {
        guard let codedPlane = routing.codedPlaneToHeightPermutation.firstIndex(of: height),
              decoded.codedPlanes.indices.contains(codedPlane) else {
            throw DTSError.malformed("XLL-X routing does not identify requested height plane")
        }
        return decoded.codedPlanes[codedPlane]
    }

    private static func findMatches(
        baseline: [Int32],
        variantPlanes: [[Int32]],
        temporalPlanes: [[Int32]],
        activePlanes: [Int]
    ) -> (matches: [TransformMatch], bestDirectSampleMatchCount: Int) {
        var matches: [TransformMatch] = []
        var bestDirectSampleMatchCount = 0
        for destination in activePlanes where variantPlanes.indices.contains(destination) {
            let direct = exactMatchCount(baseline, variantPlanes[destination])
            bestDirectSampleMatchCount = max(bestDirectSampleMatchCount, direct)
            if direct == frameSampleCount {
                matches.append(TransformMatch(
                    key: TransformKey(
                        name: "direct",
                        sourcePlane: nil,
                        destinationPlane: destination,
                        coefficient: nil
                    ),
                    sampleMatchCount: direct
                ))
            }
        }
        for destination in activePlanes where variantPlanes.indices.contains(destination) {
            for source in activePlanes where source != destination
                && variantPlanes.indices.contains(source) {
                for coefficient in coefficientCandidates where coefficient != 0 {
                    if transformedMatchesExactly(
                        baseline: baseline,
                        source: variantPlanes[source],
                        destination: variantPlanes[destination],
                        coefficient: coefficient,
                        subtract: false
                    ) {
                        matches.append(TransformMatch(
                            key: TransformKey(
                                name: "destination-plus-scaled-source",
                                sourcePlane: source,
                                destinationPlane: destination,
                                coefficient: coefficient
                            ),
                            sampleMatchCount: frameSampleCount
                        ))
                    }
                }
            }
        }
        for destination in activePlanes where temporalPlanes.indices.contains(destination) {
            for source in activePlanes where source != destination
                && temporalPlanes.indices.contains(source) {
                for coefficient in coefficientCandidates where coefficient != 0 {
                    if transformedMatchesExactly(
                        baseline: baseline,
                        source: temporalPlanes[source],
                        destination: temporalPlanes[destination],
                        coefficient: coefficient,
                        subtract: false
                    ) {
                        matches.append(TransformMatch(
                            key: TransformKey(
                                name: "temporal-destination-plus-scaled-source",
                                sourcePlane: source,
                                destinationPlane: destination,
                                coefficient: coefficient
                            ),
                            sampleMatchCount: frameSampleCount
                        ))
                    }
                }
            }
        }
        return (matches, bestDirectSampleMatchCount)
    }

    private static func exactMatchCount(_ lhs: [Int32], _ rhs: [Int32]) -> Int {
        guard lhs.count == rhs.count else { return 0 }
        var count = 0
        for index in lhs.indices where lhs[index] == rhs[index] { count += 1 }
        return count
    }

    private static func transformedMatchesExactly(
        baseline: [Int32],
        source: [Int32],
        destination: [Int32],
        coefficient: Int,
        subtract: Bool
    ) -> Bool {
        guard baseline.count == source.count, source.count == destination.count else { return false }
        for index in baseline.indices {
            let scaled = Int32(truncatingIfNeeded: (Int64(source[index]) * Int64(coefficient) + 4) >> 3)
            let reconstructed = subtract
                ? destination[index] &- scaled
                : destination[index] &+ scaled
            if reconstructed != baseline[index] { return false }
        }
        return true
    }

    private static func frequencies(_ values: [Int: Int]) -> [DTSXValueFrequency] {
        values.map { DTSXValueFrequency(value: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.value < $1.value : $0.count > $1.count }
    }

    private static func hexFrequencies(
        _ values: [String: Int],
        limit: Int
    ) -> [DTSXHexFrequency] {
        var result: [DTSXHexFrequency] = values.map {
            DTSXHexFrequency(hex: $0.key, count: $0.value)
        }
        result.sort {
            $0.count == $1.count ? $0.hex < $1.hex : $0.count > $1.count
        }
        return Array(result.prefix(limit))
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct DTSXPrivateBedDifferenceReport: Sendable, Equatable, Codable {
    public let baselinePath: String
    public let variantPath: String
    public let baselineSHA256: String
    public let variantSHA256: String
    public let expectedHeightIndex: Int
    public let compatibilityBedChannel: Int
    public let accessUnitCount: Int
    public let xllFrameCount: Int
    public let publicXLLCRCValidatedFrameCount: Int
    public let privateDecodedFrameCount: Int
    public let privateDecodeFailureCount: Int
    public let privateHeaderCRCValidFrameCount: Int
    public let privatePredictionCRCValidFrameCount: Int
    public let privateNavigationCRCValidFrameCount: Int
    public let privateNavigationAbsentFrameCount: Int
    public let pbrReassemblyComplete: Bool
    public let comparedSampleCount: Int64
    public let expectedContributionMismatchCount: Int64
    public let unchangedChannelMismatchCount: Int64
    public let publicDifferenceMismatchCountsByChannel: [Int64]
    public let firstMismatchFrameIndex: Int?
    public let firstMismatchSample: Int?
    public let firstMismatchExpectedContribution: Int32?
    public let firstMismatchActualContribution: Int32?
    public let firstPrivateDecodeFailure: String?
    public let variantBranchFrequencies: [DTSXValueFrequency]
    public let isBitExact: Bool
}

public struct DTSXPrivateControlledPCMVerificationReport: Sendable, Equatable, Codable {
    public let allMutePath: String
    public let lfhOnlyPath: String
    public let lfhRfhPath: String
    public let allMuteSHA256: String
    public let lfhOnlySHA256: String
    public let lfhRfhSHA256: String
    public let activation: DTSXPrivateBedDifferenceReport
    public let rightFrontAddition: DTSXPrivateBedDifferenceReport
    public let hardwareAcceptance: String
    public let isBitExact: Bool
}

public enum DTSXPrivateControlledPCMVerifier {
    private static let coreWaveToPrimaryOrder = [2, 0, 1, 3, 4, 5]
    private static let primaryAndSecondaryToSourceOrder = [1, 2, 0, 3, 6, 7, 4, 5]
    private static let heightGainQ15: Int64 = 23_170
    private static let halfQ15: Int64 = 1 << 14

    public static func verify(
        allMuteURL: URL,
        lfhOnlyURL: URL,
        lfhRfhURL: URL,
        outputURL: URL
    ) throws -> DTSXPrivateControlledPCMVerificationReport {
        let allMute = allMuteURL.standardizedFileURL
        let lfhOnly = lfhOnlyURL.standardizedFileURL
        let lfhRfh = lfhRfhURL.standardizedFileURL
        let activation = try verifyDifference(
            baselineURL: allMute,
            variantURL: lfhOnly,
            expectedHeightIndex: 0,
            compatibilityBedChannel: 0
        )
        let rightFrontAddition = try verifyDifference(
            baselineURL: lfhOnly,
            variantURL: lfhRfh,
            expectedHeightIndex: 1,
            compatibilityBedChannel: 1
        )
        let report = DTSXPrivateControlledPCMVerificationReport(
            allMutePath: allMute.path,
            lfhOnlyPath: lfhOnly.path,
            lfhRfhPath: lfhRfh.path,
            allMuteSHA256: try SHA256Hasher.hash(fileAt: allMute),
            lfhOnlySHA256: try SHA256Hasher.hash(fileAt: lfhOnly),
            lfhRfhSHA256: try SHA256Hasher.hash(fileAt: lfhRfh),
            activation: activation,
            rightFrontAddition: rightFrontAddition,
            hardwareAcceptance: "not-tested-locally",
            isBitExact: activation.isBitExact && rightFrontAddition.isBitExact
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(report).write(to: outputURL.standardizedFileURL, options: .atomic)
        } catch {
            throw DTSError.io("cannot write controlled PCM verification: (error.localizedDescription)")
        }
        return report
    }

    private static func verifyDifference(
        baselineURL: URL,
        variantURL: URL,
        expectedHeightIndex: Int,
        compatibilityBedChannel: Int
    ) throws -> DTSXPrivateBedDifferenceReport {
        let baselineInfos = try DTSStreamInspector().inspect(
            url: baselineURL,
            maximumAccessUnits: Int.max
        )
        let variantInfos = try DTSStreamInspector().inspect(
            url: variantURL,
            maximumAccessUnits: Int.max
        )
        guard baselineInfos.count == variantInfos.count, !baselineInfos.isEmpty else {
            throw DTSError.malformed("controlled PCM vectors have different access-unit counts")
        }
        guard baselineInfos.allSatisfy({ $0.coreByteCount != nil }),
              variantInfos.allSatisfy({ $0.coreByteCount != nil }) else {
            throw DTSError.unsupported("controlled PCM verification requires Core-bearing DTS:X streams")
        }

        let baselineXLL = try XLLPBRStreamReader.read(inputURL: baselineURL)
        let variantXLL = try XLLPBRStreamReader.read(inputURL: variantURL)
        guard baselineXLL.frames.count == baselineInfos.count,
              variantXLL.frames.count == variantInfos.count,
              baselineXLL.frames.count == variantXLL.frames.count else {
            throw DTSError.malformed("controlled PCM vectors do not have one XLL frame per access unit")
        }
        guard baselineXLL.coreCompatiblePrimingSampleCount
                == variantXLL.coreCompatiblePrimingSampleCount,
              baselineXLL.initialDecodingDelayFrames == variantXLL.initialDecodingDelayFrames else {
            throw DTSError.malformed("controlled PCM vectors have different XLL timelines")
        }

        let baselineHandle = try FileHandle(forReadingFrom: baselineURL)
        let variantHandle = try FileHandle(forReadingFrom: variantURL)
        defer {
            try? baselineHandle.close()
            try? variantHandle.close()
        }
        var baselineCoreDecoder = DTSCoreDecoder()
        var variantCoreDecoder = DTSCoreDecoder()
        let xllDecoder = XLLDecoder()
        var privateDecodedFrameCount = 0
        var privateDecodeFailureCount = 0
        var publicXLLCRCValidatedFrameCount = 0
        var privateHeaderCRCValidFrameCount = 0
        var privatePredictionCRCValidFrameCount = 0
        var privateNavigationCRCValidFrameCount = 0
        var privateNavigationAbsentFrameCount = 0
        var comparedSampleCount: Int64 = 0
        var expectedContributionMismatchCount: Int64 = 0
        var unchangedChannelMismatchCount: Int64 = 0
        var publicDifferenceMismatchCountsByChannel = Array(repeating: Int64(0), count: 8)
        var firstMismatchFrameIndex: Int?
        var firstMismatchSample: Int?
        var firstMismatchExpectedContribution: Int32?
        var firstMismatchActualContribution: Int32?
        var firstPrivateDecodeFailure: String?
        var branchCounts: [Int: Int] = [:]

        for frameIndex in baselineInfos.indices {
            let baselineCore = try baselineCoreDecoder.decode(
                frame: try readCoreFrame(handle: baselineHandle, info: baselineInfos[frameIndex])
            )
            let variantCore = try variantCoreDecoder.decode(
                frame: try readCoreFrame(handle: variantHandle, info: variantInfos[frameIndex])
            )
            let baselinePublic = try reconstructCompatibilityBed(
                xllFrame: baselineXLL.frames[frameIndex].frame,
                coreFrame: baselineCore,
                decoder: xllDecoder
            )
            let variantPublic = try reconstructCompatibilityBed(
                xllFrame: variantXLL.frames[frameIndex].frame,
                coreFrame: variantCore,
                decoder: xllDecoder
            )
            publicXLLCRCValidatedFrameCount += 2
            guard baselinePublic.count == 8,
                  variantPublic.count == 8,
                  baselinePublic.allSatisfy({ $0.count == 512 }),
                  variantPublic.allSatisfy({ $0.count == 512 }) else {
                throw DTSError.malformed("controlled PCM compatibility bed frame is not 8x512")
            }

            let privatePlane: [Int32]?
            do {
                let observation = try decodeHeightPlane(
                    xllFrame: variantXLL.frames[frameIndex].frame,
                    heightIndex: expectedHeightIndex,
                    branchCounts: &branchCounts
                )
                privatePlane = observation.plane
                privateDecodedFrameCount += 1
                privateHeaderCRCValidFrameCount += 1
                privatePredictionCRCValidFrameCount += 1
                if observation.navigationPresent {
                    privateNavigationCRCValidFrameCount += 1
                } else {
                    privateNavigationAbsentFrameCount += 1
                }
            } catch {
                privatePlane = nil
                privateDecodeFailureCount += 1
                if firstPrivateDecodeFailure == nil {
                    firstPrivateDecodeFailure = "frame (frameIndex): (error)"
                }
            }

            for sample in 0..<512 {
                comparedSampleCount += 1
                let expectedContribution = privatePlane.map {
                    q15HeightContribution($0[sample])
                }
                let actualContribution = Int64(variantPublic[compatibilityBedChannel][sample])
                    - Int64(baselinePublic[compatibilityBedChannel][sample])
                if let expectedContribution,
                   actualContribution != Int64(expectedContribution) {
                    expectedContributionMismatchCount += 1
                    recordFirstMismatch(
                        frameIndex: frameIndex,
                        sample: sample,
                        expected: expectedContribution,
                        actual: clip24(actualContribution),
                        firstFrame: &firstMismatchFrameIndex,
                        firstSample: &firstMismatchSample,
                        firstExpected: &firstMismatchExpectedContribution,
                        firstActual: &firstMismatchActualContribution
                    )
                } else if expectedContribution == nil {
                    expectedContributionMismatchCount += 1
                }
                for channel in 0..<8 where channel != compatibilityBedChannel {
                    if variantPublic[channel][sample] != baselinePublic[channel][sample] {
                        unchangedChannelMismatchCount += 1
                    }
                }
                for channel in 0..<8 where variantPublic[channel][sample]
                        != baselinePublic[channel][sample] {
                    publicDifferenceMismatchCountsByChannel[channel] += 1
                }
            }
        }

        let report = DTSXPrivateBedDifferenceReport(
            baselinePath: baselineURL.path,
            variantPath: variantURL.path,
            baselineSHA256: try SHA256Hasher.hash(fileAt: baselineURL),
            variantSHA256: try SHA256Hasher.hash(fileAt: variantURL),
            expectedHeightIndex: expectedHeightIndex,
            compatibilityBedChannel: compatibilityBedChannel,
            accessUnitCount: baselineInfos.count,
            xllFrameCount: variantXLL.frames.count,
            publicXLLCRCValidatedFrameCount: publicXLLCRCValidatedFrameCount,
            privateDecodedFrameCount: privateDecodedFrameCount,
            privateDecodeFailureCount: privateDecodeFailureCount,
            privateHeaderCRCValidFrameCount: privateHeaderCRCValidFrameCount,
            privatePredictionCRCValidFrameCount: privatePredictionCRCValidFrameCount,
            privateNavigationCRCValidFrameCount: privateNavigationCRCValidFrameCount,
            privateNavigationAbsentFrameCount: privateNavigationAbsentFrameCount,
            pbrReassemblyComplete: true,
            comparedSampleCount: comparedSampleCount,
            expectedContributionMismatchCount: expectedContributionMismatchCount,
            unchangedChannelMismatchCount: unchangedChannelMismatchCount,
            publicDifferenceMismatchCountsByChannel: publicDifferenceMismatchCountsByChannel,
            firstMismatchFrameIndex: firstMismatchFrameIndex,
            firstMismatchSample: firstMismatchSample,
            firstMismatchExpectedContribution: firstMismatchExpectedContribution,
            firstMismatchActualContribution: firstMismatchActualContribution,
            firstPrivateDecodeFailure: firstPrivateDecodeFailure,
            variantBranchFrequencies: branchCounts.map {
                DTSXValueFrequency(value: $0.key, count: $0.value)
            }.sorted {
                $0.count == $1.count ? $0.value < $1.value : $0.count > $1.count
            },
            isBitExact: privateDecodeFailureCount == 0
                && publicXLLCRCValidatedFrameCount == variantXLL.frames.count * 2
                && privateHeaderCRCValidFrameCount == variantXLL.frames.count
                && privatePredictionCRCValidFrameCount == variantXLL.frames.count
                && privateNavigationCRCValidFrameCount + privateNavigationAbsentFrameCount
                    == variantXLL.frames.count
                && expectedContributionMismatchCount == 0
                && unchangedChannelMismatchCount == 0
        )
        return report
    }

    private static func readCoreFrame(
        handle: FileHandle,
        info: DTSAccessUnitInfo
    ) throws -> Data {
        guard let coreByteCount = info.coreByteCount else {
            throw DTSError.unsupported("controlled PCM vector access unit has no Core")
        }
        do { try handle.seek(toOffset: info.byteOffset) }
        catch { throw DTSError.io("cannot seek controlled Core frame: (error.localizedDescription)") }
        let frame: Data
        do { frame = try handle.read(upToCount: coreByteCount) ?? Data() }
        catch { throw DTSError.io("cannot read controlled Core frame: (error.localizedDescription)") }
        guard frame.count == coreByteCount else {
            throw DTSError.truncated(field: "controlled Core frame", bitOffset: frame.count * 8)
        }
        return frame
    }

    private static func decodeHeightPlane(
        xllFrame: Data,
        heightIndex: Int,
        branchCounts: inout [Int: Int]
    ) throws -> (plane: [Int32], navigationPresent: Bool) {
        let ast = try XLLFrameASTParser.parse(xllFrame)
        let privateRange = ast.privateDataByteRange
        guard privateRange.count >= 30 else {
            throw DTSError.malformed("controlled XLL frame has no XLL-X private payload")
        }
        let privateFrame = Data(xllFrame[privateRange])
        let privateAST = try DTSXPrivateFrameAST.parse(privateFrame[...])
        guard privateAST.headerCRCIsValid else {
            throw DTSError.checksumMismatch(component: "controlled XLL-X header")
        }
        guard try privateAST.parsePredictionCRC().isValid else {
            throw DTSError.checksumMismatch(component: "controlled XLL-X prediction")
        }
        let navigationPresent: Bool
        if privateFrame.count == 48 {
            navigationPresent = false
        } else {
            _ = try privateAST.parseNavigation()
            navigationPresent = true
        }
        let decoded = try DTSXPrivateFrameDecoder.decode(privateAST)
        let routing = try privateAST.routing
        branchCounts[routing.branchCode, default: 0] += 1
        guard let codedPlane = routing.codedPlaneToHeightPermutation.firstIndex(of: heightIndex),
              decoded.codedPlanes.indices.contains(codedPlane),
              decoded.codedPlanes[codedPlane].count == XLLSyntax.frameSampleCount else {
            throw DTSError.malformed("controlled XLL-X routing does not expose requested height plane")
        }
        return (decoded.codedPlanes[codedPlane], navigationPresent)
    }

    private static func reconstructCompatibilityBed(
        xllFrame: Data,
        coreFrame: PCMBuffer,
        decoder: XLLDecoder
    ) throws -> [[Int32]] {
        let decoded = try decoder.decodeChannelSets(frame: xllFrame)
        guard decoded.channelSets.count == 2,
              decoded.channelSets[0].planes.count == 6,
              decoded.channelSets[1].planes.count == 2,
              coreFrame.planes.count == 6 else {
            throw DTSError.unsupported("controlled PCM verification requires the official 6+2 XLL hierarchy")
        }
        let primary = decoded.channelSets[0]
        let secondary = decoded.channelSets[1]
        let sampleCount = decoded.sampleCount
        guard sampleCount == XLLSyntax.frameSampleCount,
              coreFrame.sampleCount == sampleCount else {
            throw DTSError.malformed("controlled Core/XLL frame sample counts differ")
        }
        let scaleCodes = secondary.downmixEmbedded ? secondary.downmixScaleCodes : []
        let coefficientCodes = secondary.downmixEmbedded ? secondary.downmixCoefficientCodes : []
        guard scaleCodes.isEmpty || scaleCodes.count >= 6,
              coefficientCodes.isEmpty || coefficientCodes.count >= 12 else {
            throw DTSError.malformed("controlled XLL hierarchical downmix metadata is incomplete")
        }
        let inverseScales = try scaleCodes.map(XLLSyntax.inverseDownmixScaleQ16)
        var undoCoefficients = Array(repeating: Int32(0), count: 12)
        if !coefficientCodes.isEmpty {
            for primaryChannel in 0..<6 {
                for secondaryChannel in 0..<2 {
                    let index = primaryChannel * 2 + secondaryChannel
                    undoCoefficients[index] = try XLLSyntax.undoDownmixCoefficientQ15(
                        scaleCode: scaleCodes[primaryChannel],
                        coefficientCode: coefficientCodes[index]
                    )
                }
            }
        }

        var output = Array(repeating: Array(repeating: Int32(0), count: sampleCount), count: 8)
        for sample in 0..<sampleCount {
            var hierarchical = Array(repeating: Int32(0), count: 8)
            for channel in 0..<6 {
                let xll = primary.planes[channel][sample]
                if primary.residualChannelMask & (UInt64(1) << UInt64(channel)) != 0 {
                    hierarchical[channel] = xll
                } else {
                    let coreValue = coreFrame.planes[coreWaveToPrimaryOrder[channel]][sample]
                    let scaledCore = inverseScales.isEmpty
                        ? Int64(coreValue)
                        : multiplyQ16(coreValue, inverseScales[channel])
                    let assemblyShift = try effectiveLSBWidth(
                        channelSet: primary,
                        channel: channel,
                        fixedLSBWidth: decoded.fixedLSBWidth
                    )
                    let coreShift = primary.storageBitDepth - primary.pcmBitDepth + assemblyShift
                    guard coreShift >= 0, coreShift <= primary.storageBitDepth else {
                        throw DTSError.malformed("controlled XLL Core residual shift is outside storage precision")
                    }
                    let rounding = coreShift > 0 ? Int64(1) << Int64(coreShift - 1) : 0
                    let reducedCore = clip24((scaledCore + rounding) >> coreShift)
                    hierarchical[channel] = xll &+ Int32(
                        truncatingIfNeeded: Int64(reducedCore) << Int64(assemblyShift)
                    )
                }
            }
            hierarchical[6] = secondary.planes[0][sample]
            hierarchical[7] = secondary.planes[1][sample]
            if !coefficientCodes.isEmpty {
                for primaryChannel in 0..<6 {
                    for secondaryChannel in 0..<2 {
                        let coefficient = undoCoefficients[primaryChannel * 2 + secondaryChannel]
                        if coefficient != 0 {
                            hierarchical[primaryChannel] = hierarchical[primaryChannel] &- multiplyQ15(
                                hierarchical[6 + secondaryChannel],
                                coefficient
                            )
                        }
                    }
                }
            }
            for channel in 0..<8 {
                output[channel][sample] = hierarchical[primaryAndSecondaryToSourceOrder[channel]]
            }
        }
        return output
    }

    private static func effectiveLSBWidth(
        channelSet: XLLDecodedChannelSet,
        channel: Int,
        fixedLSBWidth: Int
    ) throws -> Int {
        guard channelSet.scalableLSBWidths.indices.contains(channel),
              channelSet.bitWidthAdjustments.indices.contains(channel) else {
            throw DTSError.malformed("controlled XLL scalable-LSB metadata is incomplete")
        }
        if fixedLSBWidth > 0 { return fixedLSBWidth }
        let scalable = channelSet.scalableLSBWidths[channel]
        let adjustment = channelSet.bitWidthAdjustments[channel]
        return scalable > 0 && adjustment > 0
            ? scalable + adjustment - 1
            : scalable + adjustment
    }

    private static func q15HeightContribution(_ sample: Int32) -> Int32 {
        clip24((Int64(sample) * heightGainQ15 + halfQ15) >> 15)
    }

    private static func multiplyQ16(_ first: Int32, _ second: Int32) -> Int64 {
        (Int64(first) * Int64(second) + 32_768) >> 16
    }

    private static func multiplyQ15(_ first: Int32, _ second: Int32) -> Int32 {
        Int32(truncatingIfNeeded: (Int64(first) * Int64(second) + 16_384) >> 15)
    }

    private static func clip24(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }

    private static func recordFirstMismatch(
        frameIndex: Int,
        sample: Int,
        expected: Int32,
        actual: Int32,
        firstFrame: inout Int?,
        firstSample: inout Int?,
        firstExpected: inout Int32?,
        firstActual: inout Int32?
    ) {
        guard firstFrame == nil else { return }
        firstFrame = frameIndex
        firstSample = sample
        firstExpected = expected
        firstActual = actual
    }
}
