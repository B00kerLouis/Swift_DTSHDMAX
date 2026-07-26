import Foundation

public struct DTSXPrivateBodyMaskFrequency: Sendable, Equatable, Codable {
    public let activeHeightMask: Int
    public let count: Int
}

public struct DTSXPrivateBodyFieldValueSummary: Sendable, Equatable, Codable {
    public let value: Int
    public let count: Int
    public let maskFrequencies: [DTSXPrivateBodyMaskFrequency]
}

public struct DTSXPrivateBodyFieldCandidate: Sendable, Equatable, Codable {
    /// Bit offset relative to `DTSXPrivateFrameAST.body`.
    public let bitOffset: Int
    public let bitWidth: Int
    public let sampleCount: Int
    public let uniqueValueCount: Int
    public let activeMaskClassificationAccuracy: Double
    public let activeMaskMutualInformationBits: Double
    public let activeMaskInformationEfficiency: Double
    public let singleChannelSampleCount: Int
    public let singleChannelClassificationAccuracy: Double
    public let singleChannelMutualInformationBits: Double
    public let singleChannelInformationEfficiency: Double
    public let mostFrequentValues: [DTSXPrivateBodyFieldValueSummary]
}

public struct DTSXPrivateBodyPrefixByteActivity: Sendable, Equatable, Codable {
    public let byteOffset: Int
    public let zeroByteCount: Int
    public let nonzeroByteCount: Int
    public let nonzeroMatchesAnyHeightActivity: Double
    public let nonzeroMatchesFrontHeightPairActivity: Double
    public let nonzeroMatchesRearHeightPairActivity: Double
    public let nonzeroMatchesChannelActivity: [Double]
    public let singleChannelSampleCount: Int
    public let singleChannelNonzeroMatchesFrontHeightPair: Double
    public let singleChannelNonzeroMatchesRearHeightPair: Double
    public let singleChannelNonzeroMatchesChannel: [Double]
    /// Pearson correlation of the raw byte value with the simple Rice-cost
    /// proxy for each PCM group.  These values are deliberately descriptive,
    /// not decoder fields: they quantify whether a prefix byte tracks the
    /// coded height signal across the complete reference program.
    public let valueToHeightRiceBits: Double
    public let valueToFrontHeightPairRiceBits: Double
    public let valueToRearHeightPairRiceBits: Double
    public let valueToAllChannelRiceBits: Double
    public let mostFrequentValues: [DTSXPrivateBodyFieldValueSummary]
}

public struct DTSXPrivateBodySingleHeightChannelPrefixRelation: Sendable, Equatable, Codable {
    public let sampleCount: Int
    /// Per-channel sample counts in Lfh, Rfh, Lrh, Rrh order.
    public let channelSampleCounts: [Int]
    /// In all observed isolated-height frames, the byte for the inactive
    /// front/rear pair is zero.
    public let inactivePairByteZeroCount: Int
    /// In all observed isolated-height frames, the byte for the active pair is
    /// `primarySixBitCode - primaryCodeOffset`.
    public let activePairByteMatchesPrimaryCodeCount: Int
    public let primaryCodeOffset: Int
    public let relationHoldsForEverySample: Bool
}

public struct DTSXPrivateBodyValueFrequency: Sendable, Equatable, Codable {
    public let value: Int
    public let count: Int
}

/// Candidate public-XLL-style prediction header observed at the start of the
/// private body.  The grammar is only asserted for zero-height and exactly-one-
/// height-channel frames; multi-channel frames require an additional prefix or
/// decorrelation grammar and are intentionally excluded from this result.
public struct DTSXPrivateBodyPredictionHeaderCandidate: Sendable, Equatable, Codable {
    public let eligibleFrameCount: Int
    public let zeroHeightFrameCount: Int
    public let singleHeightChannelFrameCount: Int
    public let headerEndWithinBoundaryFrameCount: Int
    public let zeroPaddingToBoundaryFrameCount: Int
    public let allFixedPredictionOrdersZeroFrameCount: Int
    public let invalidReflectionCoefficientFrameCount: Int
    public let reflectionCoefficientCount: Int
    public let uniqueReflectionCoefficientCount: Int
    public let adaptivePredictionOrderFrequencies: [DTSXPrivateBodyValueFrequency]
    /// Observed next-section byte offset is `primarySixBitCode - 7`.
    public let boundaryPrimaryCodeOffset: Int
    public let minimumZeroPaddingBitCount: Int
    public let maximumZeroPaddingBitCount: Int
    public let isolatedPredictionTestFrameCount: Int
    public let candidatePredictionImprovesRawRiceFrameCount: Int
    public let candidatePredictionImprovesFirstDifferenceRiceFrameCount: Int
    public let wrongSignPredictionImprovesRawRiceFrameCount: Int
    public let meanCandidateToRawRiceBitRatio: Double
    public let meanCandidateToFirstDifferenceRiceBitRatio: Double
    public let meanWrongSignToRawRiceBitRatio: Double
    public let isolatedEntropyDecodedFrameCount: Int
    public let isolatedEntropySampleExactFrameCount: Int
    public let isolatedEntropyInactivePlanesZeroFrameCount: Int
    public let frontHeightMappedToCodedPlaneOneFrameCount: Int
    public let rearHeightMappedToCodedPlaneThreeFrameCount: Int
    public let entropyPrefixByteCount: Int
    public let entropyBitAllocationWidth: Int
    public let minimumEntropyTrailingZeroBitCount: Int
    public let maximumEntropyTrailingZeroBitCount: Int
    public let relationHoldsForEveryEligibleFrame: Bool
}

public struct DTSXPrivateBodyFieldAnalysisReport: Sendable, Equatable, Codable {
    public let indexPath: String
    public let payloadPath: String
    public let correlationPath: String
    public let outputPath: String
    public let payloadSHA256: String
    public let frameCount: Int
    public let analyzedBodyPrefixBitCount: Int
    public let maximumFieldBitWidth: Int
    public let activeHeightMaskFrequencies: [DTSXPrivateBodyMaskFrequency]
    /// Per-channel agreement order is Lfh, Rfh, Lrh, Rrh.
    public let prefixByteActivity: [DTSXPrivateBodyPrefixByteActivity]
    public let singleHeightChannelPrefixRelation: DTSXPrivateBodySingleHeightChannelPrefixRelation
    public let predictionHeaderCandidate: DTSXPrivateBodyPredictionHeaderCandidate
    public let candidates: [DTSXPrivateBodyFieldCandidate]
    public let compactCandidates: [DTSXPrivateBodyFieldCandidate]
}

/// Searches the stable private-body prefix for compact fields that predict
/// which of Lfh/Rfh/Lrh/Rrh contains non-zero PCM in the aligned 512-sample
/// source frame.  This is evidence tooling, not a semantic decoder: raw coded
/// audio can also correlate with activity, so candidates must still survive
/// controlled-vector and round-trip tests before being promoted into the AST.
public enum DTSXPrivateBodyFieldAnalyzer {
    private struct CandidateScore {
        let bitOffset: Int
        let bitWidth: Int
        let uniqueValueCount: Int
        let classificationAccuracy: Double
        let mutualInformation: Double
        let singleChannelCount: Int
        let singleChannelAccuracy: Double
        let singleChannelMutualInformation: Double
    }

    public static func analyze(
        indexURL: URL,
        payloadURL: URL,
        correlationURL: URL,
        outputURL: URL,
        bodyPrefixBitCount: Int = 128,
        maximumFieldBitWidth: Int = 16,
        candidateLimit: Int = 64
    ) throws -> DTSXPrivateBodyFieldAnalysisReport {
        guard bodyPrefixBitCount > 0,
              maximumFieldBitWidth > 0,
              maximumFieldBitWidth <= 24,
              candidateLimit > 0 else {
            throw DTSError.invalidArgument("invalid XLL-X private body field search limits")
        }
        let loaded = try DTSXPrivateArtifactLoader.load(
            indexURL: indexURL,
            payloadURL: payloadURL
        )
        let correlation: DTSXPrivatePCMCorrelationReport
        do {
            correlation = try JSONDecoder().decode(
                DTSXPrivatePCMCorrelationReport.self,
                from: Data(contentsOf: correlationURL, options: .mappedIfSafe)
            )
        } catch {
            throw DTSError.io("cannot read XLL-X PCM correlation report: \(error.localizedDescription)")
        }
        let payloadHash = SHA256Hasher.hash(loaded.payload)
        guard correlation.payloadSHA256 == payloadHash,
              correlation.frameCount == loaded.records.count,
              correlation.frames.count == loaded.records.count else {
            throw DTSError.malformed("XLL-X PCM correlation report does not match the private payload")
        }
        let source = try DTS714SourceSet.load(
            directory: URL(fileURLWithPath: correlation.sourceDirectory)
        )
        guard source.sampleCount == correlation.sourceSampleCount,
              DTSXPrivatePCMCorrelator.hashPCM(source.planes) == correlation.sourcePCM_SHA256 else {
            throw DTSError.malformed("XLL-X PCM correlation source has changed since the report was generated")
        }
        guard loaded.records.allSatisfy({ $0.payloadByteCount >= 28 + (bodyPrefixBitCount + 7) / 8 }) else {
            throw DTSError.truncated(
                field: "XLL-X private body analysis prefix",
                bitOffset: bodyPrefixBitCount
            )
        }

        let masks = correlation.frames.map(activeHeightMask)
        let globalMasks = frequencies(masks)
        let singleChannelMasks = masks.filter(isSingleChannelMask)
        let globalSingleChannelMasks = frequencies(singleChannelMasks)
        let singleChannelCount = singleChannelMasks.count
        var scores: [CandidateScore] = []
        scores.reserveCapacity(bodyPrefixBitCount * maximumFieldBitWidth)

        for bitOffset in 0..<bodyPrefixBitCount {
            let maximumWidth = min(maximumFieldBitWidth, bodyPrefixBitCount - bitOffset)
            for bitWidth in 1...maximumWidth {
                let groups = fieldGroups(
                    loaded: loaded,
                    masks: masks,
                    bitOffset: bitOffset,
                    bitWidth: bitWidth,
                    singleChannelOnly: false
                )
                let singleGroups = fieldGroups(
                    loaded: loaded,
                    masks: masks,
                    bitOffset: bitOffset,
                    bitWidth: bitWidth,
                    singleChannelOnly: true
                )
                scores.append(CandidateScore(
                    bitOffset: bitOffset,
                    bitWidth: bitWidth,
                    uniqueValueCount: groups.count,
                    classificationAccuracy: classificationAccuracy(
                        groups: groups,
                        sampleCount: masks.count
                    ),
                    mutualInformation: mutualInformation(
                        groups: groups,
                        globalMasks: globalMasks,
                        sampleCount: masks.count
                    ),
                    singleChannelCount: singleChannelCount,
                    singleChannelAccuracy: classificationAccuracy(
                        groups: singleGroups,
                        sampleCount: singleChannelCount
                    ),
                    singleChannelMutualInformation: mutualInformation(
                        groups: singleGroups,
                        globalMasks: globalSingleChannelMasks,
                        sampleCount: singleChannelCount
                    )
                ))
            }
        }

        let selected = scores.sorted {
            if $0.mutualInformation != $1.mutualInformation {
                return $0.mutualInformation > $1.mutualInformation
            }
            if $0.singleChannelAccuracy != $1.singleChannelAccuracy {
                return $0.singleChannelAccuracy > $1.singleChannelAccuracy
            }
            if $0.bitWidth != $1.bitWidth { return $0.bitWidth < $1.bitWidth }
            return $0.bitOffset < $1.bitOffset
        }.prefix(candidateLimit)
        let selectedCompact = scores.filter {
            $0.bitWidth <= 12 && $0.uniqueValueCount <= 128
        }.sorted {
            let lhsEfficiency = informationEfficiency(
                mutualInformation: $0.mutualInformation + $0.singleChannelMutualInformation,
                uniqueValueCount: $0.uniqueValueCount
            )
            let rhsEfficiency = informationEfficiency(
                mutualInformation: $1.mutualInformation + $1.singleChannelMutualInformation,
                uniqueValueCount: $1.uniqueValueCount
            )
            if lhsEfficiency != rhsEfficiency { return lhsEfficiency > rhsEfficiency }
            if $0.mutualInformation != $1.mutualInformation {
                return $0.mutualInformation > $1.mutualInformation
            }
            if $0.bitWidth != $1.bitWidth { return $0.bitWidth < $1.bitWidth }
            return $0.bitOffset < $1.bitOffset
        }.prefix(candidateLimit)

        func materialize(_ score: CandidateScore) -> DTSXPrivateBodyFieldCandidate {
            let groups = fieldGroups(
                loaded: loaded,
                masks: masks,
                bitOffset: score.bitOffset,
                bitWidth: score.bitWidth,
                singleChannelOnly: false
            )
            let values = groups.map { value, maskCounts in
                DTSXPrivateBodyFieldValueSummary(
                    value: value,
                    count: maskCounts.values.reduce(0, +),
                    maskFrequencies: sortedMaskFrequencies(maskCounts)
                )
            }.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.value < $1.value
            }.prefix(24)
            return DTSXPrivateBodyFieldCandidate(
                bitOffset: score.bitOffset,
                bitWidth: score.bitWidth,
                sampleCount: masks.count,
                uniqueValueCount: score.uniqueValueCount,
                activeMaskClassificationAccuracy: score.classificationAccuracy,
                activeMaskMutualInformationBits: score.mutualInformation,
                activeMaskInformationEfficiency: informationEfficiency(
                    mutualInformation: score.mutualInformation,
                    uniqueValueCount: score.uniqueValueCount
                ),
                singleChannelSampleCount: score.singleChannelCount,
                singleChannelClassificationAccuracy: score.singleChannelAccuracy,
                singleChannelMutualInformationBits: score.singleChannelMutualInformation,
                singleChannelInformationEfficiency: informationEfficiency(
                    mutualInformation: score.singleChannelMutualInformation,
                    uniqueValueCount: score.uniqueValueCount
                ),
                mostFrequentValues: Array(values)
            )
        }
        let candidates = selected.map(materialize)
        let compactCandidates = selectedCompact.map(materialize)
        let prefixByteActivity = (0..<bodyPrefixBitCount / 8).map { byteOffset in
            analyzePrefixByte(
                loaded: loaded,
                masks: masks,
                frames: correlation.frames,
                byteOffset: byteOffset
            )
        }
        let singleHeightChannelPrefixRelation = analyzeSingleHeightChannelPrefixRelation(
            loaded: loaded,
            masks: masks,
            frames: correlation.frames
        )
        let predictionHeaderCandidate = analyzePredictionHeaderCandidate(
            loaded: loaded,
            masks: masks,
            frames: correlation.frames,
            source: source
        )

        let report = DTSXPrivateBodyFieldAnalysisReport(
            indexPath: indexURL.standardizedFileURL.path,
            payloadPath: payloadURL.standardizedFileURL.path,
            correlationPath: correlationURL.standardizedFileURL.path,
            outputPath: outputURL.standardizedFileURL.path,
            payloadSHA256: payloadHash,
            frameCount: loaded.records.count,
            analyzedBodyPrefixBitCount: bodyPrefixBitCount,
            maximumFieldBitWidth: maximumFieldBitWidth,
            activeHeightMaskFrequencies: sortedMaskFrequencies(globalMasks),
            prefixByteActivity: prefixByteActivity,
            singleHeightChannelPrefixRelation: singleHeightChannelPrefixRelation,
            predictionHeaderCandidate: predictionHeaderCandidate,
            candidates: candidates,
            compactCandidates: compactCandidates
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try encoder.encode(report).write(to: outputURL, options: .atomic) }
        catch { throw DTSError.io("cannot write XLL-X private body field analysis: \(error.localizedDescription)") }
        return report
    }

    private static func activeHeightMask(_ frame: DTSXPrivatePCMFrameMetric) -> Int {
        var mask = 0
        for (index, channel) in frame.heightChannels.enumerated() where channel.nonzeroSampleCount > 0 {
            mask |= 1 << index
        }
        return mask
    }

    private static func isSingleChannelMask(_ mask: Int) -> Bool {
        mask > 0 && (mask & (mask - 1)) == 0
    }

    private static func frequencies(_ values: [Int]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for value in values { result[value, default: 0] += 1 }
        return result
    }

    private static func fieldGroups(
        loaded: DTSXPrivateLoadedArtifacts,
        masks: [Int],
        bitOffset: Int,
        bitWidth: Int,
        singleChannelOnly: Bool
    ) -> [Int: [Int: Int]] {
        var groups: [Int: [Int: Int]] = [:]
        for index in loaded.records.indices {
            let mask = masks[index]
            if singleChannelOnly && !isSingleChannelMask(mask) { continue }
            let record = loaded.records[index]
            let byteOffset = record.payloadFileOffset! + 28
            let value = readBits(
                loaded.payload,
                baseByteOffset: byteOffset,
                bitOffset: bitOffset,
                bitWidth: bitWidth
            )
            groups[value, default: [:]][mask, default: 0] += 1
        }
        return groups
    }

    private static func classificationAccuracy(
        groups: [Int: [Int: Int]],
        sampleCount: Int
    ) -> Double {
        guard sampleCount > 0 else { return 0 }
        let correct = groups.values.reduce(0) { total, maskCounts in
            total + (maskCounts.values.max() ?? 0)
        }
        return Double(correct) / Double(sampleCount)
    }

    private static func mutualInformation(
        groups: [Int: [Int: Int]],
        globalMasks: [Int: Int],
        sampleCount: Int
    ) -> Double {
        guard sampleCount > 0 else { return 0 }
        let total = Double(sampleCount)
        var result = 0.0
        for maskCounts in groups.values {
            let valueCount = maskCounts.values.reduce(0, +)
            for (mask, count) in maskCounts where count > 0 {
                guard let maskCount = globalMasks[mask], maskCount > 0 else { continue }
                let joint = Double(count) / total
                result += joint * log2(
                    Double(count * sampleCount) / Double(valueCount * maskCount)
                )
            }
        }
        return result
    }

    private static func informationEfficiency(
        mutualInformation: Double,
        uniqueValueCount: Int
    ) -> Double {
        let capacity = log2(Double(max(2, uniqueValueCount)))
        return capacity > 0 ? mutualInformation / capacity : 0
    }

    private static func sortedMaskFrequencies(_ values: [Int: Int]) -> [DTSXPrivateBodyMaskFrequency] {
        values.map {
            DTSXPrivateBodyMaskFrequency(activeHeightMask: $0.key, count: $0.value)
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.activeHeightMask < $1.activeHeightMask
        }
    }

    private static func analyzePrefixByte(
        loaded: DTSXPrivateLoadedArtifacts,
        masks: [Int],
        frames: [DTSXPrivatePCMFrameMetric],
        byteOffset: Int
    ) -> DTSXPrivateBodyPrefixByteActivity {
        var zeroCount = 0
        var anyAgreement = 0
        var frontAgreement = 0
        var rearAgreement = 0
        var channelAgreement = Array(repeating: 0, count: 4)
        var singleCount = 0
        var singleFrontAgreement = 0
        var singleRearAgreement = 0
        var singleChannelAgreement = Array(repeating: 0, count: 4)
        for index in loaded.records.indices {
            let record = loaded.records[index]
            let value = loaded.payload[record.payloadFileOffset! + 28 + byteOffset]
            let nonzero = value != 0
            if !nonzero { zeroCount += 1 }
            let mask = masks[index]
            if nonzero == (mask != 0) { anyAgreement += 1 }
            if nonzero == ((mask & 0b0011) != 0) { frontAgreement += 1 }
            if nonzero == ((mask & 0b1100) != 0) { rearAgreement += 1 }
            for channel in 0..<4 where nonzero == ((mask & (1 << channel)) != 0) {
                channelAgreement[channel] += 1
            }
            if isSingleChannelMask(mask) {
                singleCount += 1
                if nonzero == ((mask & 0b0011) != 0) { singleFrontAgreement += 1 }
                if nonzero == ((mask & 0b1100) != 0) { singleRearAgreement += 1 }
                for channel in 0..<4 where nonzero == ((mask & (1 << channel)) != 0) {
                    singleChannelAgreement[channel] += 1
                }
            }
        }
        let count = Double(loaded.records.count)
        let singleDenominator = Double(max(1, singleCount))
        let groups = fieldGroups(
            loaded: loaded,
            masks: masks,
            bitOffset: byteOffset * 8,
            bitWidth: 8,
            singleChannelOnly: false
        )
        let values = groups.map { value, maskCounts in
            DTSXPrivateBodyFieldValueSummary(
                value: value,
                count: maskCounts.values.reduce(0, +),
                maskFrequencies: sortedMaskFrequencies(maskCounts)
            )
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.value < $1.value
        }.prefix(24)
        let byteValues = loaded.records.indices.map { index -> Double in
            Double(loaded.payload[loaded.records[index].payloadFileOffset! + 28 + byteOffset])
        }
        let heightRice = frames.map { Double($0.heightFirstDifferenceRiceBits) }
        let frontRice = frames.map { frame in
            Double(frame.heightChannels.prefix(2).reduce(Int64(0)) {
                $0 + $1.firstDifferenceRiceBits
            })
        }
        let rearRice = frames.map { frame in
            Double(frame.heightChannels.dropFirst(2).reduce(Int64(0)) {
                $0 + $1.firstDifferenceRiceBits
            })
        }
        let allRice = frames.map { Double($0.allChannelFirstDifferenceRiceBits) }
        return DTSXPrivateBodyPrefixByteActivity(
            byteOffset: byteOffset,
            zeroByteCount: zeroCount,
            nonzeroByteCount: loaded.records.count - zeroCount,
            nonzeroMatchesAnyHeightActivity: Double(anyAgreement) / count,
            nonzeroMatchesFrontHeightPairActivity: Double(frontAgreement) / count,
            nonzeroMatchesRearHeightPairActivity: Double(rearAgreement) / count,
            nonzeroMatchesChannelActivity: channelAgreement.map { Double($0) / count },
            singleChannelSampleCount: singleCount,
            singleChannelNonzeroMatchesFrontHeightPair: Double(singleFrontAgreement) / singleDenominator,
            singleChannelNonzeroMatchesRearHeightPair: Double(singleRearAgreement) / singleDenominator,
            singleChannelNonzeroMatchesChannel: singleChannelAgreement.map {
                Double($0) / singleDenominator
            },
            valueToHeightRiceBits: pearson(byteValues, heightRice),
            valueToFrontHeightPairRiceBits: pearson(byteValues, frontRice),
            valueToRearHeightPairRiceBits: pearson(byteValues, rearRice),
            valueToAllChannelRiceBits: pearson(byteValues, allRice),
            mostFrequentValues: Array(values)
        )
    }

    private static func analyzeSingleHeightChannelPrefixRelation(
        loaded: DTSXPrivateLoadedArtifacts,
        masks: [Int],
        frames: [DTSXPrivatePCMFrameMetric]
    ) -> DTSXPrivateBodySingleHeightChannelPrefixRelation {
        let primaryCodeOffset = 16
        var sampleCount = 0
        var channelCounts = Array(repeating: 0, count: 4)
        var inactivePairZero = 0
        var activePairMatchesPrimary = 0
        for index in loaded.records.indices where isSingleChannelMask(masks[index]) {
            sampleCount += 1
            let channel = masks[index].trailingZeroBitCount
            channelCounts[channel] += 1
            let record = loaded.records[index]
            let bodyOffset = record.payloadFileOffset! + 28
            let activePairByteOffset = channel < 2 ? 0 : 1
            let inactivePairByteOffset = activePairByteOffset ^ 1
            if loaded.payload[bodyOffset + inactivePairByteOffset] == 0 {
                inactivePairZero += 1
            }
            let expected = frames[index].primarySixBitCode - primaryCodeOffset
            if expected >= 0,
               loaded.payload[bodyOffset + activePairByteOffset] == UInt8(expected) {
                activePairMatchesPrimary += 1
            }
        }
        return DTSXPrivateBodySingleHeightChannelPrefixRelation(
            sampleCount: sampleCount,
            channelSampleCounts: channelCounts,
            inactivePairByteZeroCount: inactivePairZero,
            activePairByteMatchesPrimaryCodeCount: activePairMatchesPrimary,
            primaryCodeOffset: primaryCodeOffset,
            relationHoldsForEverySample: sampleCount > 0
                && inactivePairZero == sampleCount
                && activePairMatchesPrimary == sampleCount
        )
    }

    private static func analyzePredictionHeaderCandidate(
        loaded: DTSXPrivateLoadedArtifacts,
        masks: [Int],
        frames: [DTSXPrivatePCMFrameMetric],
        source: DTS714PCMBuffer
    ) -> DTSXPrivateBodyPredictionHeaderCandidate {
        let boundaryPrimaryCodeOffset = 7
        var eligible = 0
        var zeroHeight = 0
        var singleHeight = 0
        var headerWithinBoundary = 0
        var zeroPadding = 0
        var allFixedOrdersZero = 0
        var invalidReflectionFrames = 0
        var reflectionCount = 0
        var reflectionValues = Set<Int>()
        var orderFrequencies: [Int: Int] = [:]
        var minimumPadding = Int.max
        var maximumPadding = 0
        var predictionTests = 0
        var candidateImprovesRaw = 0
        var candidateImprovesFirstDifference = 0
        var wrongSignImprovesRaw = 0
        var candidateToRawRatioSum = 0.0
        var candidateToFirstDifferenceRatioSum = 0.0
        var wrongSignToRawRatioSum = 0.0
        var isolatedEntropyDecoded = 0
        var isolatedEntropyExact = 0
        var isolatedEntropyInactiveZero = 0
        var frontMappedToPlaneOne = 0
        var rearMappedToPlaneThree = 0
        var minimumTrailingZero = Int.max
        var maximumTrailingZero = 0

        for index in loaded.records.indices {
            let mask = masks[index]
            guard mask == 0 || isSingleChannelMask(mask) else { continue }
            eligible += 1
            if mask == 0 { zeroHeight += 1 } else { singleHeight += 1 }
            let record = loaded.records[index]
            guard let ast = try? DTSXPrivateFrameAST.parse(loaded.frameBytes(record)),
                  let candidate = try? ast.parsePredictionHeaderCandidate() else {
                continue
            }
            headerWithinBoundary += 1
            for order in candidate.adaptivePredictionOrders {
                orderFrequencies[order, default: 0] += 1
            }
            if candidate.fixedPredictionOrders.compactMap({ $0 }).allSatisfy({ $0 == 0 }) {
                allFixedOrdersZero += 1
            }
            if candidate.containsReservedReflectionIndex {
                invalidReflectionFrames += 1
            }
            for channel in candidate.reflectionCoefficientRawIndices {
                reflectionCount += channel.count
                reflectionValues.formUnion(channel)
            }
            minimumPadding = min(minimumPadding, candidate.zeroPaddingBitCount)
            maximumPadding = max(maximumPadding, candidate.zeroPaddingBitCount)
            if candidate.paddingIsAllZero { zeroPadding += 1 }

            if isSingleChannelMask(mask),
               let evidence = predictionEvidence(
                   candidate: candidate,
                   activeHeightChannel: mask.trailingZeroBitCount,
                   sourceSampleStart: frames[index].sourceSampleStart,
                   source: source,
                   firstDifferenceRiceBits: frames[index].heightChannels[
                       mask.trailingZeroBitCount
                   ].firstDifferenceRiceBits
               ) {
                predictionTests += 1
                if evidence.candidateRiceBits < evidence.rawRiceBits {
                    candidateImprovesRaw += 1
                }
                if evidence.candidateRiceBits < evidence.firstDifferenceRiceBits {
                    candidateImprovesFirstDifference += 1
                }
                if evidence.wrongSignRiceBits < evidence.rawRiceBits {
                    wrongSignImprovesRaw += 1
                }
                candidateToRawRatioSum += Double(evidence.candidateRiceBits)
                    / Double(evidence.rawRiceBits)
                candidateToFirstDifferenceRatioSum += Double(evidence.candidateRiceBits)
                    / Double(evidence.firstDifferenceRiceBits)
                wrongSignToRawRatioSum += Double(evidence.wrongSignRiceBits)
                    / Double(evidence.rawRiceBits)

                if let ast = try? DTSXPrivateFrameAST.parse(loaded.frameBytes(record)),
                   let decoded = try? DTSXPrivateIsolatedFrameDecoder.decode(ast) {
                    isolatedEntropyDecoded += 1
                    minimumTrailingZero = min(
                        minimumTrailingZero,
                        decoded.trailingZeroBitCount
                    )
                    maximumTrailingZero = max(
                        maximumTrailingZero,
                        decoded.trailingZeroBitCount
                    )
                    let activePlane = 8 + mask.trailingZeroBitCount
                    let codedPlane = mask.trailingZeroBitCount < 2 ? 1 : 3
                    let sourcePlane = source.planes[activePlane]
                    let sourceStart = frames[index].sourceSampleStart
                    let activeMatches = (0..<XLLSyntax.frameSampleCount).allSatisfy { sample in
                        let sourceIndex = sourceStart + sample
                        let expected = sourceIndex >= 0 && sourceIndex < sourcePlane.count
                            ? sourcePlane[sourceIndex] : 0
                        return decoded.codedPlanes[codedPlane][sample] == expected
                    }
                    let inactiveAreZero = decoded.codedPlanes.indices
                        .filter { $0 != codedPlane }
                        .allSatisfy { plane in
                            decoded.codedPlanes[plane].allSatisfy { $0 == 0 }
                        }
                    if activeMatches {
                        isolatedEntropyExact += 1
                        if codedPlane == 1 { frontMappedToPlaneOne += 1 }
                        if codedPlane == 3 { rearMappedToPlaneThree += 1 }
                    }
                    if inactiveAreZero { isolatedEntropyInactiveZero += 1 }
                }
            }
        }

        return DTSXPrivateBodyPredictionHeaderCandidate(
            eligibleFrameCount: eligible,
            zeroHeightFrameCount: zeroHeight,
            singleHeightChannelFrameCount: singleHeight,
            headerEndWithinBoundaryFrameCount: headerWithinBoundary,
            zeroPaddingToBoundaryFrameCount: zeroPadding,
            allFixedPredictionOrdersZeroFrameCount: allFixedOrdersZero,
            invalidReflectionCoefficientFrameCount: invalidReflectionFrames,
            reflectionCoefficientCount: reflectionCount,
            uniqueReflectionCoefficientCount: reflectionValues.count,
            adaptivePredictionOrderFrequencies: orderFrequencies.map {
                DTSXPrivateBodyValueFrequency(value: $0.key, count: $0.value)
            }.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.value < $1.value
            },
            boundaryPrimaryCodeOffset: boundaryPrimaryCodeOffset,
            minimumZeroPaddingBitCount: minimumPadding == Int.max ? 0 : minimumPadding,
            maximumZeroPaddingBitCount: maximumPadding,
            isolatedPredictionTestFrameCount: predictionTests,
            candidatePredictionImprovesRawRiceFrameCount: candidateImprovesRaw,
            candidatePredictionImprovesFirstDifferenceRiceFrameCount: candidateImprovesFirstDifference,
            wrongSignPredictionImprovesRawRiceFrameCount: wrongSignImprovesRaw,
            meanCandidateToRawRiceBitRatio: predictionTests > 0
                ? candidateToRawRatioSum / Double(predictionTests) : 0,
            meanCandidateToFirstDifferenceRiceBitRatio: predictionTests > 0
                ? candidateToFirstDifferenceRatioSum / Double(predictionTests) : 0,
            meanWrongSignToRawRiceBitRatio: predictionTests > 0
                ? wrongSignToRawRatioSum / Double(predictionTests) : 0,
            isolatedEntropyDecodedFrameCount: isolatedEntropyDecoded,
            isolatedEntropySampleExactFrameCount: isolatedEntropyExact,
            isolatedEntropyInactivePlanesZeroFrameCount: isolatedEntropyInactiveZero,
            frontHeightMappedToCodedPlaneOneFrameCount: frontMappedToPlaneOne,
            rearHeightMappedToCodedPlaneThreeFrameCount: rearMappedToPlaneThree,
            entropyPrefixByteCount: isolatedEntropyDecoded > 0 ? 7 : 0,
            entropyBitAllocationWidth: isolatedEntropyDecoded > 0 ? 5 : 0,
            minimumEntropyTrailingZeroBitCount: minimumTrailingZero == Int.max
                ? 0 : minimumTrailingZero,
            maximumEntropyTrailingZeroBitCount: maximumTrailingZero,
            relationHoldsForEveryEligibleFrame: eligible > 0
                && headerWithinBoundary == eligible
                && zeroPadding == eligible
                && allFixedOrdersZero == eligible
                && invalidReflectionFrames == 0
                && predictionTests == singleHeight
                && candidateImprovesRaw == predictionTests
                && wrongSignImprovesRaw == 0
                && isolatedEntropyDecoded == singleHeight
                && isolatedEntropyExact == singleHeight
                && isolatedEntropyInactiveZero == singleHeight
        )
    }

    private struct PredictionEvidence {
        let rawRiceBits: Int64
        let firstDifferenceRiceBits: Int64
        let candidateRiceBits: Int64
        let wrongSignRiceBits: Int64
    }

    /// Tests the candidate reflection-coefficient syntax against the actual
    /// isolated height waveform.  The public XLL inverse uses
    /// `sample = codedError - prediction`, so the encoder-side error candidate
    /// is `sample + prediction`; the opposite sign is kept as a falsification
    /// control rather than silently choosing the lower-cost result.
    private static func predictionEvidence(
        candidate: DTSXPrivatePredictionHeaderCandidate,
        activeHeightChannel: Int,
        sourceSampleStart: Int,
        source: DTS714PCMBuffer,
        firstDifferenceRiceBits: Int64
    ) -> PredictionEvidence? {
        guard (0..<4).contains(activeHeightChannel) else { return nil }
        let codedChannels = candidate.adaptivePredictionOrders.indices.filter {
            candidate.adaptivePredictionOrders[$0] > 0
        }
        guard codedChannels.count == 1 else { return nil }
        let codedChannel = codedChannels[0]
        let order = candidate.adaptivePredictionOrders[codedChannel]
        let signedIndices = candidate.reflectionCoefficientSignedIndices[codedChannel]
        guard order > 0, signedIndices.count == order else { return nil }

        let sourcePlane = source.planes[8 + activeHeightChannel]
        let samples: [Int64] = (0..<XLLSyntax.frameSampleCount).map { localSample in
            let sample = sourceSampleStart + localSample
            return sample >= 0 && sample < sourcePlane.count
                ? Int64(sourcePlane[sample]) : 0
        }
        var direct = Array(repeating: Int32(0), count: order)
        for index in 0..<order {
            let signedIndex = Int(signedIndices[index])
            let magnitude = abs(signedIndex)
            guard XLLSyntax.reflectionCoefficients.indices.contains(magnitude) else { return nil }
            let rawCoefficient = Int32(XLLSyntax.reflectionCoefficients[magnitude])
            let coefficient = signedIndex < 0 ? -rawCoefficient : rawCoefficient
            for pairIndex in 0..<((index + 1) / 2) {
                let opposite = index - pairIndex - 1
                let first = direct[pairIndex]
                let second = direct[opposite]
                direct[pairIndex] = first &+ multiplyQ16(coefficient, second)
                direct[opposite] = second &+ multiplyQ16(coefficient, first)
            }
            direct[index] = coefficient
        }

        var candidateResidual = Array(samples.prefix(order))
        var wrongSignResidual = candidateResidual
        if samples.count > order {
            candidateResidual.reserveCapacity(samples.count)
            wrongSignResidual.reserveCapacity(samples.count)
            for sample in 0..<(samples.count - order) {
                var accumulator: Int64 = 0
                for coefficient in 0..<order {
                    accumulator += samples[sample + coefficient]
                        * Int64(direct[order - coefficient - 1])
                }
                let prediction = clip24(roundShift(accumulator, by: 16))
                let value = samples[sample + order]
                candidateResidual.append(value + Int64(prediction))
                wrongSignResidual.append(value - Int64(prediction))
            }
        }
        return PredictionEvidence(
            rawRiceBits: minimumRiceBits(samples),
            firstDifferenceRiceBits: firstDifferenceRiceBits,
            candidateRiceBits: minimumRiceBits(candidateResidual),
            wrongSignRiceBits: minimumRiceBits(wrongSignResidual)
        )
    }

    private static func minimumRiceBits(_ values: [Int64]) -> Int64 {
        var minimum = Int64.max
        for parameter in 0..<24 {
            var bits = Int64(values.count * (1 + parameter))
            for value in values {
                let mapped = value < 0
                    ? UInt64((-value << 1) - 1)
                    : UInt64(value << 1)
                bits += Int64(mapped >> UInt64(parameter))
            }
            minimum = min(minimum, bits)
        }
        return minimum
    }

    @inline(__always)
    private static func multiplyQ16(_ first: Int32, _ second: Int32) -> Int32 {
        Int32(truncatingIfNeeded: roundShift(Int64(first) * Int64(second), by: 16))
    }

    @inline(__always)
    private static func roundShift(_ value: Int64, by shift: Int) -> Int64 {
        shift > 0 ? (value + (Int64(1) << (shift - 1))) >> shift : value
    }

    @inline(__always)
    private static func clip24(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }

    /// Pearson correlation for the numeric prefix-byte evidence.  Keep this
    /// local to the analyzer so the report remains self-contained and does
    /// not couple the field search to the PCM correlator's private helpers.
    private static func pearson(_ left: [Double], _ right: [Double]) -> Double {
        let count = min(left.count, right.count)
        guard count > 1 else { return 0 }
        let leftMean = left.prefix(count).reduce(0, +) / Double(count)
        let rightMean = right.prefix(count).reduce(0, +) / Double(count)
        var covariance = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for index in 0..<count {
            let leftDelta = left[index] - leftMean
            let rightDelta = right[index] - rightMean
            covariance += leftDelta * rightDelta
            leftVariance += leftDelta * leftDelta
            rightVariance += rightDelta * rightDelta
        }
        let denominator = sqrt(leftVariance * rightVariance)
        return denominator > 0 ? covariance / denominator : 0
    }

    @inline(__always)
    private static func readBits(
        _ bytes: Data,
        baseByteOffset: Int,
        bitOffset: Int,
        bitWidth: Int
    ) -> Int {
        var value = 0
        for bit in 0..<bitWidth {
            let absoluteBit = bitOffset + bit
            let byte = bytes[baseByteOffset + absoluteBit / 8]
            let shift = 7 - (absoluteBit & 7)
            value = (value << 1) | Int((byte >> shift) & 1)
        }
        return value
    }
}
