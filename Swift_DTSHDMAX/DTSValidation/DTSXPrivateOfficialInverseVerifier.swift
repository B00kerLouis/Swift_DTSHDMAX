import Foundation

public struct DTSXPrivateOfficialInverseFrame: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let originalFrameByteCount: Int
    public let reencodedFrameByteCount: Int
    public let originalFrameSHA256: String
    public let reencodedFrameSHA256: String
    public let originalRouting: DTSXPrivateRouting
    public let reencodedRouting: DTSXPrivateRouting
    public let originalPrimarySixBitCode: Int
    public let reencodedPrimarySixBitCode: Int
    public let originalPredictionBoundaryByteCount: Int
    public let reencodedPredictionBoundaryByteCount: Int
    public let originalPredictionSyntaxBitCount: Int
    public let reencodedPredictionSyntaxBitCount: Int
    public let originalPredictionZeroPaddingBitCount: Int
    public let reencodedPredictionZeroPaddingBitCount: Int
    public let originalAdaptivePredictionOrders: [Int]
    public let reencodedAdaptivePredictionOrders: [Int]
    public let originalFixedPredictionOrders: [Int?]
    public let reencodedFixedPredictionOrders: [Int?]
    public let originalReflectionCoefficientRawIndices: [[Int]]
    public let reencodedReflectionCoefficientRawIndices: [[Int]]
    public let reflectionCoefficientIndicesEqual: Bool
    public let originalNavigationSegmentByteCounts: [Int]?
    public let reencodedNavigationSegmentByteCounts: [Int]?
    public let originalNavigationBitWidth: Int?
    public let reencodedNavigationBitWidth: Int?
    public let originalTrailingFrameByteCount: Int?
    public let reencodedTrailingFrameByteCount: Int?
    public let originalEntropySegments: [DTSXPrivateEntropySegmentSyntax]
    public let reencodedEntropySegments: [DTSXPrivateEntropySegmentSyntax]
    public let originalPrefixHex: String
    public let reencodedPrefixHex: String
    public let firstDifferingByteOffset: Int?
    public let differingByteCount: Int
    public let firstDifferingByteOffsets: [Int]
    public let byteExact: Bool
}

public struct DTSXPrivateOfficialInverseReport: Sendable, Equatable, Codable {
    public let indexPath: String
    public let payloadPath: String
    public let requestedFrameOffset: Int
    public let requestedMaximumFrameCount: Int?
    public let examinedFrameCount: Int
    public let branchZeroFrameCount: Int
    public let branchOneFrameCount: Int
    public let branchTwoFrameCount: Int
    public let branchThreeFrameCount: Int
    public let decodedBranchZeroFrameCount: Int
    public let decodedBranchOneFrameCount: Int
    public let decodedBranchTwoFrameCount: Int
    public let decodedBranchThreeFrameCount: Int
    public let officialGrammarEligibleFrameCount: Int
    public let reencodedFrameCount: Int
    public let byteExactFrameCount: Int
    public let equalFrameByteCountFrameCount: Int
    public let equalPredictionOrdersFrameCount: Int
    public let equalPredictionBoundaryFrameCount: Int
    public let equalReflectionCoefficientFrameCount: Int
    public let equalNavigationFrameCount: Int
    public let equalNavigationBitWidthFrameCount: Int
    public let equalTrailingFrameByteCountFrameCount: Int
    public let originalPredictionReservedByteFrequencies: [DTSXValueFrequency]
    public let reencodedPredictionReservedByteFrequencies: [DTSXValueFrequency]
    public let originalNavigationBitWidthFrequencies: [DTSXValueFrequency]
    public let reencodedNavigationBitWidthFrequencies: [DTSXValueFrequency]
    public let originalTrailingFrameByteCountFrequencies: [DTSXValueFrequency]
    public let reencodedTrailingFrameByteCountFrequencies: [DTSXValueFrequency]
    public let originalTotalByteCount: Int
    public let reencodedTotalByteCount: Int
    public let reencodedToOriginalByteRatio: Double
    public let failures: [String]
    public let firstDifferences: [DTSXPrivateOfficialInverseFrame]

    public var hasIndependentOfficialInverseEvidence: Bool {
        officialGrammarEligibleFrameCount > 0 && byteExactFrameCount > 0
    }
}

/// Re-encodes PCM decoded from official recovered decorrelation branches and compares every
/// serialized field. This is intentionally a reference-set verifier, not a
/// product dependency: production encoding never reads or copies oracle bytes.
public enum DTSXPrivateOfficialInverseVerifier {
    public static func verify(
        indexURL: URL,
        payloadURL: URL,
        outputURL: URL,
        maximumFrameCount: Int? = nil,
        frameOffset: Int = 0
    ) throws -> DTSXPrivateOfficialInverseReport {
        if let maximumFrameCount, maximumFrameCount <= 0 {
            throw DTSError.invalidArgument("maximum official inverse frame count must be positive")
        }
        guard frameOffset >= 0 else {
            throw DTSError.invalidArgument("official inverse frame offset must not be negative")
        }
        let loaded = try DTSXPrivateArtifactLoader.load(
            indexURL: indexURL,
            payloadURL: payloadURL
        )
        let offsetRecords = Array(loaded.records.dropFirst(frameOffset))
        let records = maximumFrameCount.map { Array(offsetRecords.prefix($0)) }
            ?? offsetRecords

        var branchZeroFrameCount = 0
        var branchOneFrameCount = 0
        var branchTwoFrameCount = 0
        var branchThreeFrameCount = 0
        var decodedBranchZeroFrameCount = 0
        var decodedBranchOneFrameCount = 0
        var decodedBranchTwoFrameCount = 0
        var decodedBranchThreeFrameCount = 0
        var eligibleFrameCount = 0
        var reencodedFrameCount = 0
        var exactFrameCount = 0
        var equalByteCountFrameCount = 0
        var equalPredictionOrdersFrameCount = 0
        var equalPredictionBoundaryFrameCount = 0
        var equalReflectionCoefficientFrameCount = 0
        var equalNavigationFrameCount = 0
        var equalNavigationBitWidthFrameCount = 0
        var equalTrailingFrameByteCountFrameCount = 0
        var originalPredictionReservedByteCounts: [Int: Int] = [:]
        var reencodedPredictionReservedByteCounts: [Int: Int] = [:]
        var originalNavigationBitWidthCounts: [Int: Int] = [:]
        var reencodedNavigationBitWidthCounts: [Int: Int] = [:]
        var originalTrailingFrameByteCounts: [Int: Int] = [:]
        var reencodedTrailingFrameByteCounts: [Int: Int] = [:]
        var originalTotalByteCount = 0
        var reencodedTotalByteCount = 0
        var failures: [String] = []
        var firstDifferences: [DTSXPrivateOfficialInverseFrame] = []

        for record in records {
            let original = Data(loaded.frameBytes(record))
            originalTotalByteCount += original.count
            do {
                let ast = try DTSXPrivateFrameAST.parse(original[...])
                let branchCode = ast.candidateSecondaryBranchCode
                guard (0...3).contains(branchCode) else { continue }
                switch branchCode {
                case 0:
                    branchZeroFrameCount += 1
                case 1:
                    branchOneFrameCount += 1
                case 2:
                    branchTwoFrameCount += 1
                case 3:
                    branchThreeFrameCount += 1
                default:
                    break
                }
                let prediction = try ast.parsePredictionHeaderCandidate()
                let navigation = try? ast.parseNavigation(
                    segmentCount: record.xllSyntax?.segmentCount ?? 2
                )
                originalPredictionReservedByteCounts[
                    reservedPredictionByteCount(prediction),
                    default: 0
                ] += 1
                if let navigation {
                    originalNavigationBitWidthCounts[navigation.bitWidth, default: 0] += 1
                    originalTrailingFrameByteCounts[
                        navigation.trailingFrameByteCount,
                        default: 0
                    ] += 1
                }
                let grammarEligible = ast.matchesObservedStandardProfile
                    && ast.headerCRCIsValid
                    && prediction.matchesObservedGenericProfile
                    && prediction.crc.isValid
                    && (navigation?.crcIsValid ?? (original.count == 48))
                if grammarEligible { eligibleFrameCount += 1 }

                let decoded = try DTSXPrivateFrameDecoder.decode(
                    ast,
                    segmentCount: record.xllSyntax?.segmentCount ?? 2,
                    segmentSampleCount: record.xllSyntax?.segmentSampleCount ?? 256,
                    collectEntropyDiagnostics: true
                )
                let segmentationPlan = try XLLSegmentationPlan(
                    segmentCount: record.xllSyntax?.segmentCount ?? 2,
                    segmentSampleCount: record.xllSyntax?.segmentSampleCount ?? 256
                )
                switch branchCode {
                case 0:
                    decodedBranchZeroFrameCount += 1
                case 1:
                    decodedBranchOneFrameCount += 1
                case 2:
                    decodedBranchTwoFrameCount += 1
                case 3:
                    decodedBranchThreeFrameCount += 1
                default:
                    break
                }
                let routing = try ast.routing
                let reencoded = try DTSXPrivateFrameEncoder(
                    allowsExperimentalHybridRice: true
                ).encodeUsingQualifiedPrediction(
                    codedPlanes: decoded.codedPlanes,
                    routing: routing,
                    prediction: prediction,
                    // Some no-NAVI zero-code forms can satisfy the loose
                    // structural NAVI probe by coincidence. The decoder's
                    // CRC-closed side-info classification is authoritative
                    // for this inverse reconstruction.
                    navigation: decoded.noNavigationZeroSideInfo == nil
                        ? navigation
                        : nil,
                    entropySegments: decoded.entropySegments,
                    noNavigationZeroSideInfo: decoded.noNavigationZeroSideInfo,
                    segmentationPlan: segmentationPlan
                )
                reencodedFrameCount += 1
                reencodedTotalByteCount += reencoded.count

                let rebuiltAST = try DTSXPrivateFrameAST.parse(reencoded[...])
                let rebuiltPrediction = try rebuiltAST.parsePredictionHeaderCandidate()
                let rebuiltNavigation = try? rebuiltAST.parseNavigation(
                    segmentCount: segmentationPlan.segmentCount
                )
                let rebuiltDecoded = try DTSXPrivateFrameDecoder.decode(
                    rebuiltAST,
                    segmentCount: segmentationPlan.segmentCount,
                    segmentSampleCount: segmentationPlan.segmentSampleCount,
                    collectEntropyDiagnostics: true
                )
                let rebuiltRouting = try rebuiltAST.routing
                guard rebuiltDecoded.codedPlanes == decoded.codedPlanes else {
                    throw DTSError.malformed(
                        "qualified XLL-X inverse changed decoded coded-plane PCM"
                    )
                }
                reencodedPredictionReservedByteCounts[
                    reservedPredictionByteCount(rebuiltPrediction),
                    default: 0
                ] += 1
                if let rebuiltNavigation {
                    reencodedNavigationBitWidthCounts[
                        rebuiltNavigation.bitWidth,
                        default: 0
                    ] += 1
                    reencodedTrailingFrameByteCounts[
                        rebuiltNavigation.trailingFrameByteCount,
                        default: 0
                    ] += 1
                }
                let exact = original == reencoded
                if exact { exactFrameCount += 1 }
                if original.count == reencoded.count { equalByteCountFrameCount += 1 }
                if prediction.adaptivePredictionOrders
                        == rebuiltPrediction.adaptivePredictionOrders,
                   prediction.fixedPredictionOrders
                        == rebuiltPrediction.fixedPredictionOrders {
                    equalPredictionOrdersFrameCount += 1
                }
                if prediction.boundaryByteOffset == rebuiltPrediction.boundaryByteOffset {
                    equalPredictionBoundaryFrameCount += 1
                }
                if prediction.reflectionCoefficientRawIndices
                        == rebuiltPrediction.reflectionCoefficientRawIndices {
                    equalReflectionCoefficientFrameCount += 1
                }
                if navigation?.segmentByteCounts == rebuiltNavigation?.segmentByteCounts {
                    equalNavigationFrameCount += 1
                }
                if navigation?.bitWidth == rebuiltNavigation?.bitWidth {
                    equalNavigationBitWidthFrameCount += 1
                }
                if navigation?.trailingFrameByteCount
                        == rebuiltNavigation?.trailingFrameByteCount {
                    equalTrailingFrameByteCountFrameCount += 1
                }

                if !exact, firstDifferences.count < 32 {
                    firstDifferences.append(DTSXPrivateOfficialInverseFrame(
                        frameIndex: record.frameIndex,
                        originalFrameByteCount: original.count,
                        reencodedFrameByteCount: reencoded.count,
                        originalFrameSHA256: SHA256Hasher.hash(original),
                        reencodedFrameSHA256: SHA256Hasher.hash(reencoded),
                        originalRouting: routing,
                        reencodedRouting: rebuiltRouting,
                        originalPrimarySixBitCode: Int(ast.primarySixBitCode),
                        reencodedPrimarySixBitCode: Int(rebuiltAST.primarySixBitCode),
                        originalPredictionBoundaryByteCount: prediction.boundaryByteOffset,
                        reencodedPredictionBoundaryByteCount:
                            rebuiltPrediction.boundaryByteOffset,
                        originalPredictionSyntaxBitCount: prediction.syntaxBitCount,
                        reencodedPredictionSyntaxBitCount: rebuiltPrediction.syntaxBitCount,
                        originalPredictionZeroPaddingBitCount: prediction.zeroPaddingBitCount,
                        reencodedPredictionZeroPaddingBitCount:
                            rebuiltPrediction.zeroPaddingBitCount,
                        originalAdaptivePredictionOrders: prediction.adaptivePredictionOrders,
                        reencodedAdaptivePredictionOrders:
                            rebuiltPrediction.adaptivePredictionOrders,
                        originalFixedPredictionOrders: prediction.fixedPredictionOrders,
                        reencodedFixedPredictionOrders: rebuiltPrediction.fixedPredictionOrders,
                        originalReflectionCoefficientRawIndices:
                            prediction.reflectionCoefficientRawIndices,
                        reencodedReflectionCoefficientRawIndices:
                            rebuiltPrediction.reflectionCoefficientRawIndices,
                        reflectionCoefficientIndicesEqual:
                            prediction.reflectionCoefficientRawIndices
                                == rebuiltPrediction.reflectionCoefficientRawIndices,
                        originalNavigationSegmentByteCounts: navigation?.segmentByteCounts,
                        reencodedNavigationSegmentByteCounts:
                            rebuiltNavigation?.segmentByteCounts,
                        originalNavigationBitWidth: navigation?.bitWidth,
                        reencodedNavigationBitWidth: rebuiltNavigation?.bitWidth,
                        originalTrailingFrameByteCount: navigation?.trailingFrameByteCount,
                        reencodedTrailingFrameByteCount:
                            rebuiltNavigation?.trailingFrameByteCount,
                        originalEntropySegments: decoded.entropySegments,
                        reencodedEntropySegments: rebuiltDecoded.entropySegments,
                        originalPrefixHex: hexPrefix(original, byteCount: 64),
                        reencodedPrefixHex: hexPrefix(reencoded, byteCount: 64),
                        firstDifferingByteOffset: firstDifference(original, reencoded),
                        differingByteCount: differingByteCount(original, reencoded),
                        firstDifferingByteOffsets: differingByteOffsets(
                            original,
                            reencoded,
                            limit: 32
                        ),
                        byteExact: false
                    ))
                }
            } catch {
                if failures.count < 64 {
                    failures.append("frame \(record.frameIndex): \(String(describing: error))")
                }
            }
        }

        let report = DTSXPrivateOfficialInverseReport(
            indexPath: indexURL.standardizedFileURL.path,
            payloadPath: payloadURL.standardizedFileURL.path,
            requestedFrameOffset: frameOffset,
            requestedMaximumFrameCount: maximumFrameCount,
            examinedFrameCount: records.count,
            branchZeroFrameCount: branchZeroFrameCount,
            branchOneFrameCount: branchOneFrameCount,
            branchTwoFrameCount: branchTwoFrameCount,
            branchThreeFrameCount: branchThreeFrameCount,
            decodedBranchZeroFrameCount: decodedBranchZeroFrameCount,
            decodedBranchOneFrameCount: decodedBranchOneFrameCount,
            decodedBranchTwoFrameCount: decodedBranchTwoFrameCount,
            decodedBranchThreeFrameCount: decodedBranchThreeFrameCount,
            officialGrammarEligibleFrameCount: eligibleFrameCount,
            reencodedFrameCount: reencodedFrameCount,
            byteExactFrameCount: exactFrameCount,
            equalFrameByteCountFrameCount: equalByteCountFrameCount,
            equalPredictionOrdersFrameCount: equalPredictionOrdersFrameCount,
            equalPredictionBoundaryFrameCount: equalPredictionBoundaryFrameCount,
            equalReflectionCoefficientFrameCount: equalReflectionCoefficientFrameCount,
            equalNavigationFrameCount: equalNavigationFrameCount,
            equalNavigationBitWidthFrameCount: equalNavigationBitWidthFrameCount,
            equalTrailingFrameByteCountFrameCount: equalTrailingFrameByteCountFrameCount,
            originalPredictionReservedByteFrequencies:
                frequencies(originalPredictionReservedByteCounts),
            reencodedPredictionReservedByteFrequencies:
                frequencies(reencodedPredictionReservedByteCounts),
            originalNavigationBitWidthFrequencies:
                frequencies(originalNavigationBitWidthCounts),
            reencodedNavigationBitWidthFrequencies:
                frequencies(reencodedNavigationBitWidthCounts),
            originalTrailingFrameByteCountFrequencies:
                frequencies(originalTrailingFrameByteCounts),
            reencodedTrailingFrameByteCountFrequencies:
                frequencies(reencodedTrailingFrameByteCounts),
            originalTotalByteCount: originalTotalByteCount,
            reencodedTotalByteCount: reencodedTotalByteCount,
            reencodedToOriginalByteRatio: originalTotalByteCount == 0
                ? 0 : Double(reencodedTotalByteCount) / Double(originalTotalByteCount),
            failures: failures,
            firstDifferences: firstDifferences
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(report).write(
                to: outputURL.standardizedFileURL,
                options: .atomic
            )
        } catch {
            throw DTSError.io(
                "cannot write official XLL-X inverse report: \(error.localizedDescription)"
            )
        }
        return report
    }

    private static func firstDifference(_ lhs: Data, _ rhs: Data) -> Int? {
        let commonCount = min(lhs.count, rhs.count)
        for index in 0..<commonCount where lhs[index] != rhs[index] { return index }
        return lhs.count == rhs.count ? nil : commonCount
    }

    private static func differingByteCount(_ lhs: Data, _ rhs: Data) -> Int {
        let commonCount = min(lhs.count, rhs.count)
        var count = abs(lhs.count - rhs.count)
        for index in 0..<commonCount where lhs[index] != rhs[index] { count += 1 }
        return count
    }

    private static func differingByteOffsets(
        _ lhs: Data,
        _ rhs: Data,
        limit: Int
    ) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(limit)
        let commonCount = min(lhs.count, rhs.count)
        for index in 0..<commonCount where lhs[index] != rhs[index] {
            offsets.append(index)
            if offsets.count == limit { return offsets }
        }
        guard lhs.count != rhs.count else { return offsets }
        for index in commonCount..<max(lhs.count, rhs.count) {
            offsets.append(index)
            if offsets.count == limit { break }
        }
        return offsets
    }

    private static func hexPrefix(_ data: Data, byteCount: Int) -> String {
        data.prefix(byteCount).map { String(format: "%02x", $0) }.joined()
    }

    private static func reservedPredictionByteCount(
        _ prediction: DTSXPrivatePredictionHeaderCandidate
    ) -> Int {
        let syntaxEndBitOffset = prediction.syntaxStartBitOffset + prediction.syntaxBitCount
        return prediction.boundaryByteOffset - (syntaxEndBitOffset + 7) / 8
    }

    private static func frequencies(_ counts: [Int: Int]) -> [DTSXValueFrequency] {
        counts.map { DTSXValueFrequency(value: $0.key, count: $0.value) }
            .sorted { $0.value < $1.value }
    }
}
