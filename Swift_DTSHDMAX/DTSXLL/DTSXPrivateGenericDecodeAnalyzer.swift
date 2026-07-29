import Foundation

public struct DTSXPrivateGenericMaskDecodeSummary: Sendable, Equatable, Codable {
    public let activeHeightMask: Int
    public let totalFrameCount: Int
    public let candidateHeaderParsedFrameCount: Int
    public let entropyDecodedFrameCount: Int
    public let fullPermutationExactFrameCount: Int
    public let partialPermutationOver1000SampleFrameCount: Int
}

public struct DTSXPrivateGenericPermutationSummary: Sendable, Equatable, Codable {
    /// The permutation maps coded plane 0...3 to source height plane
    /// Lfh/Rfh/Lrh/Rrh indices 0...3.
    public let activeHeightMask: Int
    public let permutation: [Int]
    public let frameCount: Int
    public let sampleExactFrameCount: Int
}

public struct DTSXPrivateSecondaryBranchSummary: Sendable, Equatable, Codable {
    public let branchCode: Int
    public let totalFrameCount: Int
    public let genericProfileEligibleFrameCount: Int
    public let entropyDecodedFrameCount: Int
    public let secondaryPermutationSampleExactFrameCount: Int
}

public struct DTSXPrivateEntropyPrefixSummary: Sendable, Equatable, Codable {
    public let prefixByteCount: Int
    public let entropyDecodedFrameCount: Int
    public let secondaryPermutationSampleExactFrameCount: Int
}

public struct DTSXPrivateEntropyPrefixFrequency: Sendable, Equatable, Codable {
    public let prefixByteCount: Int
    public let frameCount: Int
}

public struct DTSXPrivateEntropyPrefixSelection: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let activeHeightMask: Int
    public let secondaryBranchCode: Int
    public let primarySixBitCode: Int
    public let predictionBoundaryByteOffset: Int
    /// First bytes following the candidate prediction boundary. This keeps the
    /// oracle-selected prefix length tied to observable syntax so a production
    /// decoder rule can be derived without consulting reference PCM.
    public let boundarySuffixHex: String
    public let entropyDecodedPrefixByteCounts: [Int]
    public let trailingZeroPrefixByteCounts: [Int]
    public let exactPrefixByteCounts: [Int]
}

public struct DTSXPrivatePredictionSyntaxStartSummary: Sendable, Equatable, Codable {
    public let branchCode: Int
    public let syntaxStartBitOffset: Int
    public let candidateHeaderParsedFrameCount: Int
    public let genericProfileEligibleFrameCount: Int
}

public struct DTSXPrivatePredictionSyntaxStartSelection: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let branchCode: Int
    public let parsedSyntaxStartBitOffsets: [Int]
    public let eligibleSyntaxStartBitOffsets: [Int]
}

public enum DTSXPrivateGenericFailureStage: String, Sendable, Equatable, Codable {
    case astParse
    case predictionHeader
    case entropy
    case sampleComparison
}

public struct DTSXPrivateGenericDecodeRepresentative: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let activeHeightMask: Int
    public let stage: DTSXPrivateGenericFailureStage
    public let detail: String
    public let predictionOrders: [Int]?
    public let fixedPredictionOrders: [Int?]?
    public let boundaryByteOffset: Int?
    public let entropyPrefixHex: String?
    public let entropyEndBitOffset: Int?
    public let trailingZeroBitCount: Int?
    public let trailingBitsAreAllZero: Bool?
    public let bestSampleMatchCount: Int?
    public let bestPermutation: [Int]?
}

public struct DTSXPrivateGenericFrameFailure: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let activeHeightMask: Int
    public let stage: DTSXPrivateGenericFailureStage
    public let detail: String
}

public struct DTSXPrivateGenericDecodeReport: Sendable, Equatable, Codable {
    public let indexPath: String
    public let payloadPath: String
    public let sourceDirectory: String
    public let payloadSHA256: String
    public let sourcePCM_SHA256: String
    public let frameCount: Int
    public let frameSampleCount: Int
    public let leadingPrimingSampleCount: Int
    public let sourceSampleCount: Int
    public let trailingPaddingSampleCount: Int
    public let candidateHeaderParsedFrameCount: Int
    public let genericProfileEligibleFrameCount: Int
    public let entropyDecodedFrameCount: Int
    public let entropyDecodedFrameIndices: [Int]
    public let decodedFrameTrailingBitsAllZeroCount: Int
    public let sampleExactFrameTrailingBitsAllZeroCount: Int
    public let fullPermutationExactFrameCount: Int
    public let secondaryPermutationValidFrameCount: Int
    public let secondaryPermutationBestScoreFrameCount: Int
    public let secondaryPermutationSampleExactFrameCount: Int
    public let partialPermutationOver1000SampleFrameCount: Int
    public let maskSummaries: [DTSXPrivateGenericMaskDecodeSummary]
    public let permutationSummaries: [DTSXPrivateGenericPermutationSummary]
    public let secondaryBranchSummaries: [DTSXPrivateSecondaryBranchSummary]
    public let entropyPrefixSummaries: [DTSXPrivateEntropyPrefixSummary]
    public let prefixSweepAnySampleExactFrameCount: Int
    public let prefixSweepUniqueSampleExactFrameCount: Int
    public let prefixSweepAmbiguousSampleExactFrameCount: Int
    public let prefixSweepAdditionalSampleExactFrameCount: Int
    /// Branch-zero frames accepted by the strict bitstream-only detector.
    public let autodetectedBranchZeroFrameCount: Int
    public let autodetectedBranchZeroSampleExactFrameCount: Int
    public let autodetectedBranchZeroSampleMismatchFrameCount: Int
    public let uniqueExactPrefixFrequencies: [DTSXPrivateEntropyPrefixFrequency]
    public let entropyPrefixSelections: [DTSXPrivateEntropyPrefixSelection]
    public let predictionSyntaxStartSummaries: [DTSXPrivatePredictionSyntaxStartSummary]
    public let predictionSyntaxStartSelections: [DTSXPrivatePredictionSyntaxStartSelection]
    public let representatives: [DTSXPrivateGenericDecodeRepresentative]
    public let failures: [DTSXPrivateGenericFrameFailure]
    public let allFramesCandidateParsed: Bool
    public let allFramesEntropyDecoded: Bool
    public let allDecodedFramesSampleExact: Bool
    /// This is true only when every private frame is decoded and its four
    /// planes are sample-exact against the source timeline.  The current
    /// reference remains false until the branch-specific prefix is closed.
    public let genericDecoderIsClosed: Bool
}

/// Runs the generalized private-frame decoder against a 7.1.4 source set.
/// This is an evidence/QC tool: it never emits a DTS:X stream and never
/// promotes an oracle replay into an encoder claim.
public enum DTSXPrivateGenericDecodeAnalyzer {
    private static let frameSampleCount = XLLSyntax.frameSampleCount
    private static let leadingPrimingSampleCount = XLLSyntax.coreCompatiblePrimingSampleCount
    private static let heightStartIndex = 8
    private static let heightChannelCount = 4
    private static let fullSampleMatchCount = frameSampleCount * heightChannelCount
    private static let partialMatchThreshold = 1_000
    private static let entropyPrefixCandidates = Array(2...15)
    private static let predictionSyntaxStartCandidates = [0, 7, 14, 21, 28]

    private struct MaskAccumulator {
        var total = 0
        var candidate = 0
        var decoded = 0
        var exact = 0
        var partial = 0
    }

    private struct BranchAccumulator {
        var total = 0
        var eligible = 0
        var decoded = 0
        var exact = 0
    }

    private struct PredictionSyntaxStartKey: Hashable {
        let branchCode: Int
        let bitOffset: Int
    }

    private struct PermutationKey: Hashable {
        let mask: Int
        let permutation: [Int]

        func hash(into hasher: inout Hasher) {
            hasher.combine(mask)
            for value in permutation { hasher.combine(value) }
        }

        static func == (lhs: PermutationKey, rhs: PermutationKey) -> Bool {
            lhs.mask == rhs.mask && lhs.permutation == rhs.permutation
        }
    }

    public static func analyze(
        indexURL: URL,
        payloadURL: URL,
        sourceDirectory: URL,
        outputURL: URL
    ) throws -> DTSXPrivateGenericDecodeReport {
        let loaded = try DTSXPrivateArtifactLoader.load(
            indexURL: indexURL,
            payloadURL: payloadURL
        )
        let source = try DTS714SourceSet.load(directory: sourceDirectory)
        let sourceReport = try DTS714SourceSet.inspect(directory: sourceDirectory)
        guard loaded.records.count > 0 else {
            throw DTSError.malformed("XLL-X private artifact contains no frames")
        }
        guard source.sampleCount > 0 else {
            throw DTSError.malformed("DTS:X source set contains no samples")
        }

        let timelineSampleCount = loaded.records.count * frameSampleCount
        let trailingPadding = timelineSampleCount
            - leadingPrimingSampleCount
            - source.sampleCount
        guard trailingPadding >= 0 else {
            throw DTSError.truncated(
                field: "XLL-X generic decoder PCM timeline",
                bitOffset: timelineSampleCount * 24
            )
        }

        var maskAccumulators: [Int: MaskAccumulator] = [:]
        var branchAccumulators: [Int: BranchAccumulator] = [:]
        var permutationCounts: [PermutationKey: (decoded: Int, exact: Int)] = [:]
        var representatives: [DTSXPrivateGenericDecodeRepresentative] = []
        var representativeKeys = Set<String>()
        var failures: [DTSXPrivateGenericFrameFailure] = []
        var candidateCount = 0
        var eligibleCount = 0
        var entropyCount = 0
        var entropyDecodedFrameIndices: [Int] = []
        entropyDecodedFrameIndices.reserveCapacity(loaded.records.count)
        var decodedTrailingZeroCount = 0
        var exactTrailingZeroCount = 0
        var exactCount = 0
        var secondaryPermutationValidCount = 0
        var secondaryPermutationBestScoreCount = 0
        var secondaryPermutationExactCount = 0
        var partialCount = 0
        var prefixDecodedCounts: [Int: Int] = [:]
        var prefixExactCounts: [Int: Int] = [:]
        var uniqueExactPrefixCounts: [Int: Int] = [:]
        var prefixSweepAnyExactCount = 0
        var prefixSweepUniqueExactCount = 0
        var prefixSweepAmbiguousExactCount = 0
        var prefixSweepAdditionalExactCount = 0
        var autodetectedBranchZeroCount = 0
        var autodetectedBranchZeroExactCount = 0
        var autodetectedBranchZeroMismatchCount = 0
        var prefixSelections: [DTSXPrivateEntropyPrefixSelection] = []
        prefixSelections.reserveCapacity(loaded.records.count / 4)
        var predictionSyntaxStartCounts: [PredictionSyntaxStartKey: (parsed: Int, eligible: Int)] = [:]
        var predictionSyntaxStartSelections: [DTSXPrivatePredictionSyntaxStartSelection] = []
        predictionSyntaxStartSelections.reserveCapacity(loaded.records.count / 32)

        for (position, record) in loaded.records.enumerated() {
            guard record.frameIndex == position else {
                throw DTSError.malformed("XLL-X private frame indices are not contiguous")
            }
            let sourceStart = position * frameSampleCount - leadingPrimingSampleCount
            let mask = activeHeightMask(
                source: source,
                sourceSampleStart: sourceStart
            )
            maskAccumulators[mask, default: MaskAccumulator()].total += 1

            let ast: DTSXPrivateFrameAST
            do {
                ast = try DTSXPrivateFrameAST.parse(loaded.frameBytes(record))
            } catch {
                appendRepresentative(
                    &representatives,
                    seenKeys: &representativeKeys,
                    frameIndex: position,
                    activeHeightMask: mask,
                    stage: .astParse,
                    detail: String(describing: error),
                    prediction: nil,
                    decoded: nil,
                    body: nil
                )
                failures.append(DTSXPrivateGenericFrameFailure(
                    frameIndex: position,
                    activeHeightMask: mask,
                    stage: .astParse,
                    detail: String(describing: error)
                ))
                continue
            }
            let secondaryBranch = ast.candidateSecondaryBranchCode
            branchAccumulators[secondaryBranch, default: BranchAccumulator()].total += 1
            if ast.candidateSecondaryPermutationIsValid {
                secondaryPermutationValidCount += 1
            }

            var parsedSyntaxStarts: [Int] = []
            var eligibleSyntaxStarts: [Int] = []
            for bitOffset in predictionSyntaxStartCandidates {
                let key = PredictionSyntaxStartKey(
                    branchCode: secondaryBranch,
                    bitOffset: bitOffset
                )
                guard let probed = try? ast.parsePredictionHeaderCandidateForStructuralProbe(
                    syntaxStartBitOffset: bitOffset
                ) else { continue }
                parsedSyntaxStarts.append(bitOffset)
                predictionSyntaxStartCounts[key, default: (0, 0)].parsed += 1
                if probed.matchesObservedGenericProfile {
                    eligibleSyntaxStarts.append(bitOffset)
                    predictionSyntaxStartCounts[key, default: (0, 0)].eligible += 1
                }
            }
            if secondaryBranch != 0 || eligibleSyntaxStarts.count != 1 {
                predictionSyntaxStartSelections.append(
                    DTSXPrivatePredictionSyntaxStartSelection(
                        frameIndex: position,
                        branchCode: secondaryBranch,
                        parsedSyntaxStartBitOffsets: parsedSyntaxStarts,
                        eligibleSyntaxStartBitOffsets: eligibleSyntaxStarts
                    )
                )
            }

            let prediction: DTSXPrivatePredictionHeaderCandidate
            do {
                prediction = try ast.parsePredictionHeaderCandidate()
                candidateCount += 1
                maskAccumulators[mask, default: MaskAccumulator()].candidate += 1
            } catch {
                appendRepresentative(
                    &representatives,
                    seenKeys: &representativeKeys,
                    frameIndex: position,
                    activeHeightMask: mask,
                    stage: .predictionHeader,
                    detail: String(describing: error),
                    prediction: nil,
                    decoded: nil,
                    body: ast.body
                )
                failures.append(DTSXPrivateGenericFrameFailure(
                    frameIndex: position,
                    activeHeightMask: mask,
                    stage: .predictionHeader,
                    detail: String(describing: error)
                ))
                continue
            }

            if prediction.matchesObservedGenericProfile {
                eligibleCount += 1
                branchAccumulators[secondaryBranch, default: BranchAccumulator()].eligible += 1

                var decodedPrefixCounts: [Int] = []
                var trailingZeroPrefixCounts: [Int] = []
                var exactPrefixCounts: [Int] = []
                for prefixByteCount in entropyPrefixCandidates {
                    guard let prefixDecoded = try? DTSXPrivateIsolatedFrameDecoder.decodeGeneric(
                        ast,
                        entropyPrefixByteCount: prefixByteCount,
                        segmentCount: record.xllSyntax?.segmentCount ?? 2,
                        segmentSampleCount: record.xllSyntax?.segmentSampleCount ?? 256
                    ) else { continue }
                    decodedPrefixCounts.append(prefixByteCount)
                    if prefixDecoded.trailingBitsAreAllZero {
                        trailingZeroPrefixCounts.append(prefixByteCount)
                    }
                    prefixDecodedCounts[prefixByteCount, default: 0] += 1
                    let prefixComparison = compare(
                        decoded: prefixDecoded,
                        source: source,
                        sourceSampleStart: sourceStart,
                        secondaryPermutation: ast.candidateCodedPlaneToHeightPermutation
                    )
                    if prefixComparison.secondarySampleMatchCount == fullSampleMatchCount {
                        prefixExactCounts[prefixByteCount, default: 0] += 1
                        exactPrefixCounts.append(prefixByteCount)
                    }
                }
                prefixSelections.append(DTSXPrivateEntropyPrefixSelection(
                    frameIndex: position,
                    activeHeightMask: mask,
                    secondaryBranchCode: secondaryBranch,
                    primarySixBitCode: Int(ast.primarySixBitCode),
                    predictionBoundaryByteOffset: prediction.boundaryByteOffset,
                    boundarySuffixHex: hexPrefix(
                        ast.body.dropFirst(prediction.boundaryByteOffset),
                        maximumByteCount: 24
                    ),
                    entropyDecodedPrefixByteCounts: decodedPrefixCounts,
                    trailingZeroPrefixByteCounts: trailingZeroPrefixCounts,
                    exactPrefixByteCounts: exactPrefixCounts
                ))
                if secondaryBranch == 0,
                   let autodetected = try? DTSXPrivateIsolatedFrameDecoder
                       .decodeGenericAutodetected(
                           ast,
                           segmentCount: record.xllSyntax?.segmentCount ?? 2,
                           segmentSampleCount: record.xllSyntax?.segmentSampleCount ?? 256
                       ) {
                    autodetectedBranchZeroCount += 1
                    let autodetectedComparison = compare(
                        decoded: autodetected,
                        source: source,
                        sourceSampleStart: sourceStart,
                        secondaryPermutation: ast.candidateCodedPlaneToHeightPermutation
                    )
                    if autodetectedComparison.secondarySampleMatchCount == fullSampleMatchCount {
                        autodetectedBranchZeroExactCount += 1
                    } else {
                        autodetectedBranchZeroMismatchCount += 1
                    }
                }
                if !exactPrefixCounts.isEmpty {
                    prefixSweepAnyExactCount += 1
                    if !exactPrefixCounts.contains(7) { prefixSweepAdditionalExactCount += 1 }
                    if exactPrefixCounts.count == 1 {
                        prefixSweepUniqueExactCount += 1
                        uniqueExactPrefixCounts[exactPrefixCounts[0], default: 0] += 1
                    } else {
                        prefixSweepAmbiguousExactCount += 1
                    }
                }
            }

            let decoded: DTSXPrivateIsolatedDecodedFrame
            do {
                decoded = try DTSXPrivateFrameDecoder.decode(
                    ast,
                    segmentCount: record.xllSyntax?.segmentCount ?? 2,
                    segmentSampleCount: record.xllSyntax?.segmentSampleCount ?? 256
                )
                entropyCount += 1
                entropyDecodedFrameIndices.append(position)
                if decoded.trailingBitsAreAllZero { decodedTrailingZeroCount += 1 }
                branchAccumulators[secondaryBranch, default: BranchAccumulator()].decoded += 1
                maskAccumulators[mask, default: MaskAccumulator()].decoded += 1
            } catch {
                appendRepresentative(
                    &representatives,
                    seenKeys: &representativeKeys,
                    frameIndex: position,
                    activeHeightMask: mask,
                    stage: .entropy,
                    detail: String(describing: error),
                    prediction: prediction,
                    decoded: nil,
                    body: ast.body
                )
                failures.append(DTSXPrivateGenericFrameFailure(
                    frameIndex: position,
                    activeHeightMask: mask,
                    stage: .entropy,
                    detail: String(describing: error)
                ))
                continue
            }

            let comparison = compare(
                decoded: decoded,
                source: source,
                sourceSampleStart: sourceStart,
                secondaryPermutation: ast.candidateCodedPlaneToHeightPermutation
            )
            let key = PermutationKey(mask: mask, permutation: comparison.permutation)
            let isExact = comparison.bestSampleMatchCount == fullSampleMatchCount
            var permutationCount = permutationCounts[key] ?? (0, 0)
            permutationCount.decoded += 1
            if isExact { permutationCount.exact += 1 }
            permutationCounts[key] = permutationCount
            if isExact {
                exactCount += 1
                if decoded.trailingBitsAreAllZero { exactTrailingZeroCount += 1 }
                maskAccumulators[mask, default: MaskAccumulator()].exact += 1
            } else if comparison.bestSampleMatchCount > partialMatchThreshold {
                partialCount += 1
                maskAccumulators[mask, default: MaskAccumulator()].partial += 1
            }
            if comparison.secondarySampleMatchCount == comparison.bestSampleMatchCount {
                secondaryPermutationBestScoreCount += 1
            }
            if comparison.secondarySampleMatchCount == fullSampleMatchCount {
                secondaryPermutationExactCount += 1
                branchAccumulators[secondaryBranch, default: BranchAccumulator()].exact += 1
            }
            if comparison.bestSampleMatchCount != fullSampleMatchCount {
                appendRepresentative(
                    &representatives,
                    seenKeys: &representativeKeys,
                    frameIndex: position,
                    activeHeightMask: mask,
                    stage: .sampleComparison,
                    detail: "best sample match \(comparison.bestSampleMatchCount)/\(fullSampleMatchCount)",
                    prediction: prediction,
                    decoded: decoded,
                    body: ast.body,
                    bestSampleMatchCount: comparison.bestSampleMatchCount,
                    bestPermutation: comparison.permutation
                )
            }
        }

        let masks = maskAccumulators.keys.sorted().map { mask in
            let value = maskAccumulators[mask]!
            return DTSXPrivateGenericMaskDecodeSummary(
                activeHeightMask: mask,
                totalFrameCount: value.total,
                candidateHeaderParsedFrameCount: value.candidate,
                entropyDecodedFrameCount: value.decoded,
                fullPermutationExactFrameCount: value.exact,
                partialPermutationOver1000SampleFrameCount: value.partial
            )
        }
        let permutations = permutationCounts.keys.sorted {
            if $0.mask != $1.mask { return $0.mask < $1.mask }
            return lexicographicallyPrecedes($0.permutation, $1.permutation)
        }.map { key in
            DTSXPrivateGenericPermutationSummary(
                activeHeightMask: key.mask,
                permutation: key.permutation,
                frameCount: permutationCounts[key]!.decoded,
                sampleExactFrameCount: permutationCounts[key]!.exact
            )
        }
        let branches = branchAccumulators.keys.sorted().map { branch in
            let value = branchAccumulators[branch]!
            return DTSXPrivateSecondaryBranchSummary(
                branchCode: branch,
                totalFrameCount: value.total,
                genericProfileEligibleFrameCount: value.eligible,
                entropyDecodedFrameCount: value.decoded,
                secondaryPermutationSampleExactFrameCount: value.exact
            )
        }
        let prefixSummaries = entropyPrefixCandidates.map { prefixByteCount in
            DTSXPrivateEntropyPrefixSummary(
                prefixByteCount: prefixByteCount,
                entropyDecodedFrameCount: prefixDecodedCounts[prefixByteCount, default: 0],
                secondaryPermutationSampleExactFrameCount: prefixExactCounts[prefixByteCount, default: 0]
            )
        }
        let prefixFrequencies = uniqueExactPrefixCounts.keys.sorted().map { prefixByteCount in
            DTSXPrivateEntropyPrefixFrequency(
                prefixByteCount: prefixByteCount,
                frameCount: uniqueExactPrefixCounts[prefixByteCount]!
            )
        }
        let predictionSyntaxStarts = predictionSyntaxStartCounts.keys.sorted {
            if $0.branchCode != $1.branchCode { return $0.branchCode < $1.branchCode }
            return $0.bitOffset < $1.bitOffset
        }.map { key in
            let value = predictionSyntaxStartCounts[key]!
            return DTSXPrivatePredictionSyntaxStartSummary(
                branchCode: key.branchCode,
                syntaxStartBitOffset: key.bitOffset,
                candidateHeaderParsedFrameCount: value.parsed,
                genericProfileEligibleFrameCount: value.eligible
            )
        }
        let report = DTSXPrivateGenericDecodeReport(
            indexPath: indexURL.standardizedFileURL.path,
            payloadPath: payloadURL.standardizedFileURL.path,
            sourceDirectory: sourceDirectory.standardizedFileURL.path,
            payloadSHA256: SHA256Hasher.hash(loaded.payload),
            sourcePCM_SHA256: sourceReport.sourcePCMHash,
            frameCount: loaded.records.count,
            frameSampleCount: frameSampleCount,
            leadingPrimingSampleCount: leadingPrimingSampleCount,
            sourceSampleCount: source.sampleCount,
            trailingPaddingSampleCount: trailingPadding,
            candidateHeaderParsedFrameCount: candidateCount,
            genericProfileEligibleFrameCount: eligibleCount,
            entropyDecodedFrameCount: entropyCount,
            entropyDecodedFrameIndices: entropyDecodedFrameIndices,
            decodedFrameTrailingBitsAllZeroCount: decodedTrailingZeroCount,
            sampleExactFrameTrailingBitsAllZeroCount: exactTrailingZeroCount,
            fullPermutationExactFrameCount: exactCount,
            secondaryPermutationValidFrameCount: secondaryPermutationValidCount,
            secondaryPermutationBestScoreFrameCount: secondaryPermutationBestScoreCount,
            secondaryPermutationSampleExactFrameCount: secondaryPermutationExactCount,
            partialPermutationOver1000SampleFrameCount: partialCount,
            maskSummaries: masks,
            permutationSummaries: permutations,
            secondaryBranchSummaries: branches,
            entropyPrefixSummaries: prefixSummaries,
            prefixSweepAnySampleExactFrameCount: prefixSweepAnyExactCount,
            prefixSweepUniqueSampleExactFrameCount: prefixSweepUniqueExactCount,
            prefixSweepAmbiguousSampleExactFrameCount: prefixSweepAmbiguousExactCount,
            prefixSweepAdditionalSampleExactFrameCount: prefixSweepAdditionalExactCount,
            autodetectedBranchZeroFrameCount: autodetectedBranchZeroCount,
            autodetectedBranchZeroSampleExactFrameCount: autodetectedBranchZeroExactCount,
            autodetectedBranchZeroSampleMismatchFrameCount: autodetectedBranchZeroMismatchCount,
            uniqueExactPrefixFrequencies: prefixFrequencies,
            entropyPrefixSelections: prefixSelections,
            predictionSyntaxStartSummaries: predictionSyntaxStarts,
            predictionSyntaxStartSelections: predictionSyntaxStartSelections,
            representatives: representatives,
            failures: failures,
            allFramesCandidateParsed: candidateCount == loaded.records.count,
            allFramesEntropyDecoded: entropyCount == loaded.records.count,
            allDecodedFramesSampleExact: entropyCount > 0 && exactCount == entropyCount,
            genericDecoderIsClosed: entropyCount == loaded.records.count
                && exactCount == loaded.records.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            throw DTSError.io(
                "cannot write XLL-X generic decoder report \(outputURL.path): \(error.localizedDescription)"
            )
        }
        return report
    }

    private static func activeHeightMask(
        source: DTS714PCMBuffer,
        sourceSampleStart: Int
    ) -> Int {
        var mask = 0
        for height in 0..<heightChannelCount {
            let plane = source.planes[heightStartIndex + height]
            let active = (0..<frameSampleCount).contains { sample in
                let index = sourceSampleStart + sample
                return index >= 0 && index < plane.count && plane[index] != 0
            }
            if active { mask |= 1 << height }
        }
        return mask
    }

    private static func hexPrefix<C: Collection>(
        _ bytes: C,
        maximumByteCount: Int
    ) -> String where C.Element == UInt8 {
        bytes.prefix(maximumByteCount).map { String(format: "%02x", $0) }.joined()
    }

    private static func compare(
        decoded: DTSXPrivateIsolatedDecodedFrame,
        source: DTS714PCMBuffer,
        sourceSampleStart: Int,
        secondaryPermutation: [Int]
    ) -> (
        bestSampleMatchCount: Int,
        permutation: [Int],
        secondarySampleMatchCount: Int
    ) {
        let permutations = allPermutations4
        var exactCounts = Array(
            repeating: Array(repeating: 0, count: heightChannelCount),
            count: heightChannelCount
        )
        for coded in 0..<heightChannelCount {
            for height in 0..<heightChannelCount {
                let plane = source.planes[heightStartIndex + height]
                var count = 0
                for sample in 0..<frameSampleCount {
                    let index = sourceSampleStart + sample
                    let expected = index >= 0 && index < plane.count ? plane[index] : 0
                    if decoded.codedPlanes[coded][sample] == expected { count += 1 }
                }
                exactCounts[coded][height] = count
            }
        }
        var bestScore = -1
        var bestPermutation = permutations[0]
        for permutation in permutations {
            let score = (0..<heightChannelCount).reduce(0) {
                $0 + exactCounts[$1][permutation[$1]]
            }
            if score > bestScore {
                bestScore = score
                bestPermutation = permutation
            }
        }
        let secondaryScore: Int
        if secondaryPermutation.count == heightChannelCount,
           Set(secondaryPermutation).count == heightChannelCount {
            secondaryScore = (0..<heightChannelCount).reduce(0) {
                $0 + exactCounts[$1][secondaryPermutation[$1]]
            }
        } else {
            secondaryScore = -1
        }
        return (bestScore, bestPermutation, secondaryScore)
    }

    private static func appendRepresentative(
        _ representatives: inout [DTSXPrivateGenericDecodeRepresentative],
        seenKeys: inout Set<String>,
        frameIndex: Int,
        activeHeightMask: Int,
        stage: DTSXPrivateGenericFailureStage,
        detail: String,
        prediction: DTSXPrivatePredictionHeaderCandidate?,
        decoded: DTSXPrivateIsolatedDecodedFrame?,
        body: Data?,
        bestSampleMatchCount: Int? = nil,
        bestPermutation: [Int]? = nil
    ) {
        let representativeKey = "\(activeHeightMask):\(stage.rawValue)"
        guard representatives.count < 64, !seenKeys.contains(representativeKey) else { return }
        seenKeys.insert(representativeKey)
        let prefix: String?
        if let prediction, let body,
           prediction.boundaryByteOffset >= 0,
           prediction.boundaryByteOffset < body.count {
            let start = prediction.boundaryByteOffset
            let end = min(body.count, start + 7)
            prefix = body.subdata(in: start..<end).map { String(format: "%02x", $0) }.joined()
        } else {
            prefix = nil
        }
        representatives.append(DTSXPrivateGenericDecodeRepresentative(
            frameIndex: frameIndex,
            activeHeightMask: activeHeightMask,
            stage: stage,
            detail: detail,
            predictionOrders: prediction?.adaptivePredictionOrders,
            fixedPredictionOrders: prediction?.fixedPredictionOrders,
            boundaryByteOffset: prediction?.boundaryByteOffset,
            entropyPrefixHex: prefix,
            entropyEndBitOffset: decoded?.entropyEndBitOffset,
            trailingZeroBitCount: decoded?.trailingZeroBitCount,
            trailingBitsAreAllZero: decoded?.trailingBitsAreAllZero,
            bestSampleMatchCount: bestSampleMatchCount,
            bestPermutation: bestPermutation
        ))
    }

    private static func lexicographicallyPrecedes(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (left, right) in zip(lhs, rhs) {
            if left != right { return left < right }
        }
        return lhs.count < rhs.count
    }

    private static let allPermutations4: [[Int]] = {
        func build(_ prefix: [Int], _ remaining: [Int]) -> [[Int]] {
            guard !remaining.isEmpty else { return [prefix] }
            return remaining.flatMap { value in
                build(prefix + [value], remaining.filter { $0 != value })
            }
        }
        return build([], [0, 1, 2, 3])
    }()
}
