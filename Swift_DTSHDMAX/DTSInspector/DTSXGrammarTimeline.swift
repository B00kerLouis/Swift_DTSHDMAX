import Foundation

/// Whole-programme, per-frame declaration census for one DTS:X stream.
///
/// The early-programme verifier gates a startup window and an equally sized
/// trailing window; the residual hardware defect (Atmos-master object onsets
/// and fast channel switches) lives at arbitrary programme positions, and
/// every remaining fix candidate is arbitrated only by what the perfect /
/// encode-debug corpus declares at exactly those positions. This exporter
/// therefore walks the complete stream and records, for every XLL frame, the
/// grammar a terminal actually reads - public partition and navigation,
/// private silence-form class, private NAVI word, per-segment entropy
/// declarations, prediction and routing words, and the ExSS descriptor
/// closure - together with height-activity onset annotations.
///
/// Reference streams may carry grammar the strict decode paths reject; those
/// frames are the finding, so private-layer parse failures are recorded per
/// frame instead of aborting the export.
public struct DTSXGrammarEntropySegmentRecord: Sendable, Equatable, Codable {
    public let segmentIndex: Int
    public let reusesPreviousParameters: Bool
    public let commonParameters: Bool
    public let riceCoding: [Bool]
    public let bitAllocations: [Int]
    public let partABitAllocations: [Int]
    public let partASampleCounts: [Int]
    public let hybridLinearWidths: [Int]
}

public struct DTSXGrammarFrameRecord: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let startAccessUnit: Int
    public let endAccessUnit: Int
    public let isPriming: Bool

    public let publicFrameByteCount: Int
    public let publicSegmentCount: Int
    public let publicSegmentSampleCount: Int
    public let publicNaviSegmentByteCounts: [Int]
    public let publicMaximumRiceUnaryQuotient: Int
    public let publicUsesResearchSyntax: Bool
    public let publicPlanesAreSilent: Bool

    public let exssHeaderByteCount: Int?
    public let exssAssetDescriptorByteCount: Int?
    public let exssAssetDescriptorClosesXLLFrame: Bool?

    public let hasPrivateExtension: Bool
    /// Human-readable reason the private layer could not be fully decoded.
    /// A non-nil value on a reference stream marks grammar this codebase
    /// does not reproduce - the primary survey target.
    public let privateParseFailure: String?
    public let privateFrameByteCount: Int?
    /// Recovered silence-form class, or nil for an active frame:
    /// `core-priming-compact`, `startup-navigated`, `startup-no-navigation`,
    /// `mid-stream-no-navigation`, `navigated-silence`.
    public let privateSilenceForm: String?
    public let privateIsActive: Bool
    /// Bit i set when decoded height plane i (Lfh/Rfh/Lrh/Rrh) carries any
    /// nonzero sample in this frame.
    public let activeHeightPlaneMask: Int
    public let privateRoutingTenBitCode: Int?
    public let privateDecorrelationBranchCode: Int?
    public let privatePrimarySixBitCode: Int?
    public let privatePredictionBoundaryByteCount: Int?
    public let privateAdaptivePredictionOrders: [Int]?
    public let privateNavigationBitWidth: Int?
    public let privateNavigationSegmentByteCounts: [Int]?
    public let privateNavigationTrailingFrameByteCount: Int?
    public let privateMaximumRiceUnaryQuotient: UInt64?
    public let privateEntropySegments: [DTSXGrammarEntropySegmentRecord]?

    /// Whole-access-unit bed audibility from the losslessly reconstructed
    /// public bed; nil when the public bed could not be decoded.
    public let bedIsAudible: Bool?
}

public struct DTSXGrammarTimelineSummary: Sendable, Equatable, Codable {
    public let inputPath: String
    public let streamSHA256: String
    public let accessUnitCount: Int
    public let xllFrameCount: Int
    public let primingFrameCount: Int
    public let bedDecodeSucceeded: Bool
    public let privateFrameCount: Int
    public let privateActiveFrameCount: Int
    public let privateParseFailureCount: Int
    public let firstPrivateParseFailureFrameIndex: Int?
    public let publicSegmentCounts: [Int]
    public let silenceFormCounts: [String: Int]
    public let privateNavigationBitWidthCounts: [String: Int]
    /// Frames on which at least one height plane becomes active after being
    /// inactive in the previous frame - the XLL-X onset positions.
    public let heightOnsetFrameIndices: [Int]
    /// Frames on which the active-plane mask changes in either direction
    /// (onsets and releases) - the fast channel-switch positions.
    public let heightActivityTransitionFrameIndices: [Int]
    public let firstHeightActiveFrameIndex: Int?
    public let publicMaximumRiceUnaryQuotient: Int
    public let privateMaximumRiceUnaryQuotient: UInt64
}

public struct DTSXGrammarTimelineReport: Sendable, Equatable, Codable {
    public let summary: DTSXGrammarTimelineSummary
    public let frames: [DTSXGrammarFrameRecord]
}

public enum DTSXGrammarTimelineExporter {
    private static let xllXSyncWord: UInt32 = 0x0200_0850

    private struct ExSSFrameSummary {
        let headerByteCount: Int
        let assetDescriptorByteCount: Int
        let assetDescriptorClosesXLLFrame: Bool
    }

    public static func export(
        inputURL: URL,
        maximumFrameCount: Int? = nil
    ) throws -> DTSXGrammarTimelineReport {
        if let maximumFrameCount, maximumFrameCount <= 0 {
            throw DTSError.invalidArgument(
                "grammar timeline frame count must be positive"
            )
        }
        let input = inputURL.standardizedFileURL
        let stream = try XLLPBRStreamReader.read(inputURL: input)
        guard !stream.frames.isEmpty else {
            throw DTSError.malformed("grammar timeline requires XLL frames")
        }
        let primingFrameCount = stream.hasBackwardCompatibleCore
            ? XLLSyntax.coreCompatiblePrimingSampleCount / XLLSyntax.frameSampleCount
            : 0
        let measuredFrameCount = min(
            stream.frames.count,
            maximumFrameCount ?? stream.frames.count
        )
        let exssSummaries = exssSummariesByAccessUnit(inputURL: input)

        // The public bed decode is optional context: reference streams that
        // this decoder cannot fully reconstruct still get a grammar census.
        var bedPlanes: [[Int32]]?
        if let fileData = try? Data(contentsOf: input, options: .mappedIfSafe) {
            bedPlanes = (try? DTSHDMADecoder().decode(fileData))?.planes
        }
        func bedIsAudible(frameIndex: Int) -> Bool? {
            guard let bedPlanes else { return nil }
            guard frameIndex >= primingFrameCount else { return false }
            let start = (frameIndex - primingFrameCount) * XLLSyntax.frameSampleCount
            let end = min(
                start + XLLSyntax.frameSampleCount,
                bedPlanes.first?.count ?? 0
            )
            guard start < end else { return false }
            return bedPlanes.contains { plane in
                plane[start..<end].contains { $0 != 0 }
            }
        }

        var records: [DTSXGrammarFrameRecord] = []
        records.reserveCapacity(measuredFrameCount)
        var previousMask = 0
        var heightOnsetFrameIndices: [Int] = []
        var heightActivityTransitionFrameIndices: [Int] = []
        var firstHeightActiveFrameIndex: Int?
        var privateFrameCount = 0
        var privateActiveFrameCount = 0
        var privateParseFailureCount = 0
        var firstPrivateParseFailureFrameIndex: Int?
        var publicSegmentCounts: Set<Int> = []
        var silenceFormCounts: [String: Int] = [:]
        var navigationBitWidthCounts: [String: Int] = [:]
        var publicMaximumQuotient = 0
        var privateMaximumQuotient: UInt64 = 0

        for frameIndex in 0..<measuredFrameCount {
            let frame = stream.frames[frameIndex]
            let ast = try XLLFrameASTParser.parse(frame.frame)
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            publicSegmentCounts.insert(ast.segmentCount)
            publicMaximumQuotient = max(
                publicMaximumQuotient,
                decoded.maximumRiceUnaryQuotient
            )
            let publicPlanesAreSilent = decoded.channelSets.allSatisfy { channelSet in
                channelSet.planes.allSatisfy { plane in
                    plane.allSatisfy { $0 == 0 }
                }
            }
            let publicUsesResearchSyntax = decoded.entropyStateReuseSegmentCount > 0
                || decoded.hybridRiceParameterCount > 0
                || decoded.hybridIsolatedSampleCount > 0
                || decoded.entropyCommonParameterSegmentCount > 0
                || decoded.channelSets.contains { channelSet in
                    channelSet.decorrelationEnabled
                        || channelSet.adaptivePredictionOrders.contains { $0 > 0 }
                        || channelSet.fixedPredictionOrders.contains { $0 > 0 }
                }

            let exss = exssSummaries[frame.startAccessUnit]
            let privateRecord = surveyPrivateExtension(
                ast: ast,
                segmentCount: ast.segmentCount,
                segmentSampleCount: ast.segmentSampleCount
            )

            var mask = 0
            var silenceForm: String?
            var isActive = false
            switch privateRecord {
            case .absent:
                break
            case .parsed(let survey):
                privateFrameCount += 1
                mask = survey.activeHeightPlaneMask
                silenceForm = survey.silenceForm
                isActive = survey.silenceForm == nil
                if isActive { privateActiveFrameCount += 1 }
                if let form = survey.silenceForm {
                    silenceFormCounts[form, default: 0] += 1
                }
                if let width = survey.navigationBitWidth {
                    navigationBitWidthCounts[String(width), default: 0] += 1
                }
                if let quotient = survey.maximumQuotient {
                    privateMaximumQuotient = max(privateMaximumQuotient, quotient)
                }
            case .failed(let survey, _):
                privateFrameCount += 1
                privateParseFailureCount += 1
                if firstPrivateParseFailureFrameIndex == nil {
                    firstPrivateParseFailureFrameIndex = frameIndex
                }
                if let width = survey?.navigationBitWidth {
                    navigationBitWidthCounts[String(width), default: 0] += 1
                }
            }

            if mask & ~previousMask != 0 {
                heightOnsetFrameIndices.append(frameIndex)
            }
            if mask != previousMask {
                heightActivityTransitionFrameIndices.append(frameIndex)
            }
            if mask != 0, firstHeightActiveFrameIndex == nil {
                firstHeightActiveFrameIndex = frameIndex
            }
            previousMask = mask

            let survey: PrivateFrameSurvey?
            let failure: String?
            let hasPrivateExtension: Bool
            switch privateRecord {
            case .absent:
                survey = nil
                failure = nil
                hasPrivateExtension = false
            case .parsed(let parsed):
                survey = parsed
                failure = nil
                hasPrivateExtension = true
            case .failed(let partial, let reason):
                survey = partial
                failure = reason
                hasPrivateExtension = true
            }
            records.append(DTSXGrammarFrameRecord(
                frameIndex: frameIndex,
                startAccessUnit: frame.startAccessUnit,
                endAccessUnit: frame.endAccessUnit,
                isPriming: frameIndex < primingFrameCount,
                publicFrameByteCount: frame.frame.count,
                publicSegmentCount: ast.segmentCount,
                publicSegmentSampleCount: ast.segmentSampleCount,
                publicNaviSegmentByteCounts: ast.naviSegmentByteCounts,
                publicMaximumRiceUnaryQuotient: decoded.maximumRiceUnaryQuotient,
                publicUsesResearchSyntax: publicUsesResearchSyntax,
                publicPlanesAreSilent: publicPlanesAreSilent,
                exssHeaderByteCount: exss?.headerByteCount,
                exssAssetDescriptorByteCount: exss?.assetDescriptorByteCount,
                exssAssetDescriptorClosesXLLFrame: exss?.assetDescriptorClosesXLLFrame,
                hasPrivateExtension: hasPrivateExtension,
                privateParseFailure: failure,
                privateFrameByteCount: survey?.frameByteCount,
                privateSilenceForm: silenceForm,
                privateIsActive: isActive,
                activeHeightPlaneMask: mask,
                privateRoutingTenBitCode: survey?.routingTenBitCode,
                privateDecorrelationBranchCode: survey?.decorrelationBranchCode,
                privatePrimarySixBitCode: survey?.primarySixBitCode,
                privatePredictionBoundaryByteCount: survey?.predictionBoundaryByteCount,
                privateAdaptivePredictionOrders: survey?.adaptivePredictionOrders,
                privateNavigationBitWidth: survey?.navigationBitWidth,
                privateNavigationSegmentByteCounts: survey?.navigationSegmentByteCounts,
                privateNavigationTrailingFrameByteCount:
                    survey?.navigationTrailingFrameByteCount,
                privateMaximumRiceUnaryQuotient: survey?.maximumQuotient,
                privateEntropySegments: survey?.entropySegments,
                bedIsAudible: bedIsAudible(frameIndex: frameIndex)
            ))
        }

        let summary = DTSXGrammarTimelineSummary(
            inputPath: input.path,
            streamSHA256: try SHA256Hasher.hash(fileAt: input),
            accessUnitCount: stream.accessUnitCount,
            xllFrameCount: measuredFrameCount,
            primingFrameCount: primingFrameCount,
            bedDecodeSucceeded: bedPlanes != nil,
            privateFrameCount: privateFrameCount,
            privateActiveFrameCount: privateActiveFrameCount,
            privateParseFailureCount: privateParseFailureCount,
            firstPrivateParseFailureFrameIndex: firstPrivateParseFailureFrameIndex,
            publicSegmentCounts: publicSegmentCounts.sorted(),
            silenceFormCounts: silenceFormCounts,
            privateNavigationBitWidthCounts: navigationBitWidthCounts,
            heightOnsetFrameIndices: heightOnsetFrameIndices,
            heightActivityTransitionFrameIndices: heightActivityTransitionFrameIndices,
            firstHeightActiveFrameIndex: firstHeightActiveFrameIndex,
            publicMaximumRiceUnaryQuotient: publicMaximumQuotient,
            privateMaximumRiceUnaryQuotient: privateMaximumQuotient
        )
        return DTSXGrammarTimelineReport(summary: summary, frames: records)
    }

    // MARK: - Private-frame survey

    struct PrivateFrameSurvey {
        var frameByteCount: Int
        var routingTenBitCode: Int?
        var primarySixBitCode: Int?
        var decorrelationBranchCode: Int?
        var predictionBoundaryByteCount: Int?
        var adaptivePredictionOrders: [Int]?
        var navigationBitWidth: Int?
        var navigationSegmentByteCounts: [Int]?
        var navigationTrailingFrameByteCount: Int?
        var maximumQuotient: UInt64?
        var entropySegments: [DTSXGrammarEntropySegmentRecord]?
        var silenceForm: String?
        var activeHeightPlaneMask: Int = 0
    }

    private enum PrivateFrameOutcome {
        case absent
        case parsed(PrivateFrameSurvey)
        case failed(PrivateFrameSurvey?, String)
    }

    private static func surveyPrivateExtension(
        ast: XLLFrameAST,
        segmentCount: Int,
        segmentSampleCount: Int
    ) -> PrivateFrameOutcome {
        let range = ast.privateDataByteRange
        guard range.count >= 4 else { return .absent }
        let bytes = ast.data.subdata(in: range)
        let word = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        guard word == xllXSyncWord else { return .absent }

        var survey = PrivateFrameSurvey(frameByteCount: bytes.count)
        let privateAST: DTSXPrivateFrameAST
        do {
            privateAST = try DTSXPrivateFrameAST.parse(bytes[...])
        } catch {
            return .failed(survey, "AST parse: \(describe(error))")
        }
        survey.primarySixBitCode = Int(privateAST.primarySixBitCode)
        survey.routingTenBitCode = Int(privateAST.secondaryTenBitCode)
        if let prediction = try? privateAST.parsePredictionHeaderCandidate() {
            survey.predictionBoundaryByteCount = prediction.boundaryByteOffset
            survey.adaptivePredictionOrders = prediction.adaptivePredictionOrders
            survey.decorrelationBranchCode = prediction.decorrelation.branchCode
        }

        let decoded: DTSXPrivateIsolatedDecodedFrame
        do {
            decoded = try DTSXPrivateFrameDecoder.decode(
                privateAST,
                segmentCount: segmentCount,
                segmentSampleCount: segmentSampleCount,
                collectEntropyDiagnostics: true
            )
        } catch {
            survey.navigationBitWidth = (try? privateAST.parseNavigation(
                segmentCount: segmentCount
            ))?.bitWidth
            return .failed(survey, "entropy decode: \(describe(error))")
        }

        if decoded.noNavigationZeroSideInfo == nil,
           let navigation = (try? privateAST.parseNavigation(
               segmentCount: segmentCount
           )) ?? (try? privateAST.parseNavigation(
               segmentCount: segmentCount,
               matching: decoded
           )) {
            survey.navigationBitWidth = navigation.bitWidth
            survey.navigationSegmentByteCounts = navigation.segmentByteCounts
            survey.navigationTrailingFrameByteCount = navigation.trailingFrameByteCount
        }

        survey.entropySegments = decoded.entropySegments.map { syntax in
            DTSXGrammarEntropySegmentRecord(
                segmentIndex: syntax.segmentIndex,
                reusesPreviousParameters: syntax.reusesPreviousParameters,
                commonParameters: syntax.commonParameters,
                riceCoding: syntax.riceCoding,
                bitAllocations: syntax.partBBitAllocations,
                partABitAllocations: syntax.partABitAllocations,
                partASampleCounts: syntax.partASampleCounts,
                hybridLinearWidths: syntax.hybridLinearWidths
            )
        }

        let planesAreSilent = decoded.predictionResidualPlanes.allSatisfy { plane in
            plane.allSatisfy { $0 == 0 }
        }
        if !planesAreSilent {
            survey.silenceForm = nil
        } else if let sideInfo = decoded.noNavigationZeroSideInfo {
            survey.silenceForm = sideInfo.controlCode == 0x20
                ? "mid-stream-no-navigation"
                : "startup-no-navigation"
        } else if decoded.usesCompactZeroEntropySyntax {
            survey.silenceForm = "startup-navigated"
        } else if bytes.count == 48,
                  privateAST.primarySixBitCode == 15,
                  (try? privateAST.parseNavigation(segmentCount: segmentCount)) == nil {
            survey.silenceForm = "core-priming-compact"
        } else {
            survey.silenceForm = "navigated-silence"
        }

        if let routing = try? privateAST.routing,
           let heightPlanes = try? routing.heightPlanes(
               fromCodedPlanes: decoded.codedPlanes
           ) {
            var mask = 0
            for (index, plane) in heightPlanes.enumerated()
            where plane.contains(where: { $0 != 0 }) {
                mask |= 1 << index
            }
            survey.activeHeightPlaneMask = mask
        }

        var maximumQuotient: UInt64 = 0
        for syntax in decoded.entropySegments {
            let parameterCount = syntax.commonParameters
                ? 1
                : decoded.predictionResidualPlanes.count
            for parameter in 0..<parameterCount where syntax.riceCoding[parameter] {
                let channels = syntax.commonParameters
                    ? Array(decoded.predictionResidualPlanes.indices)
                    : [parameter]
                let allocation = syntax.partBBitAllocations[parameter]
                guard (0...31).contains(allocation) else { continue }
                let isHybrid = syntax.hybridLinearWidths[parameter] > 0
                for channel in channels {
                    let partASampleCount = syntax.partASampleCounts[parameter]
                    let segmentStart = syntax.segmentIndex * segmentSampleCount
                    let partBStart = segmentStart + partASampleCount
                    let segmentEnd = segmentStart + segmentSampleCount
                    guard partASampleCount >= 0,
                          partBStart <= segmentEnd,
                          segmentEnd <= decoded.predictionResidualPlanes[channel].count else {
                        continue
                    }
                    let isolatedOffsets = isHybrid
                        ? Set(syntax.hybridIsolatedSampleOffsets[channel])
                        : []
                    for sampleIndex in partBStart..<segmentEnd {
                        if isolatedOffsets.contains(sampleIndex - partBStart) { continue }
                        let sample = decoded.predictionResidualPlanes[channel][sampleIndex]
                        maximumQuotient = max(
                            maximumQuotient,
                            zigZag(sample) >> UInt64(allocation)
                        )
                    }
                }
            }
        }
        survey.maximumQuotient = maximumQuotient
        return .parsed(survey)
    }

    private static func exssSummariesByAccessUnit(
        inputURL: URL
    ) -> [Int: ExSSFrameSummary] {
        guard let infos = try? DTSStreamInspector().inspect(
            url: inputURL,
            maximumAccessUnits: Int.max
        ), let handle = try? FileHandle(forReadingFrom: inputURL) else {
            return [:]
        }
        defer { try? handle.close() }
        var summaries: [Int: ExSSFrameSummary] = [:]
        for info in infos {
            guard let exssByteCount = info.exssByteCount else { continue }
            let offset = info.byteOffset
                + UInt64(info.coreByteCount.map { ($0 + 3) & ~3 } ?? 0)
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: exssByteCount),
                  data.count == exssByteCount,
                  let parsed = try? ExSSParser().parse(frame: data) else {
                continue
            }
            let closes: Bool
            if let signal = parsed.info.dtsxAssetDescriptorSignal {
                closes = signal.xllXByteOffset + signal.xllXFrameByteCount
                    == parsed.info.xllByteCount
            } else {
                closes = false
            }
            summaries[info.index] = ExSSFrameSummary(
                headerByteCount: parsed.info.headerByteCount,
                assetDescriptorByteCount: parsed.info.assetDescriptorByteCount,
                assetDescriptorClosesXLLFrame: closes
            )
        }
        return summaries
    }

    private static func describe(_ error: Error) -> String {
        if let dtsError = error as? DTSError {
            return String(describing: dtsError)
        }
        return error.localizedDescription
    }

    @inline(__always)
    private static func zigZag(_ value: Int32) -> UInt64 {
        let signed = Int64(value)
        return signed >= 0
            ? UInt64(signed) << 1
            : UInt64((-signed << 1) - 1)
    }
}

// MARK: - Timeline comparison

public struct DTSXGrammarFieldMismatch: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let field: String
    public let baseline: String
    public let candidate: String
    public let isHeightOnsetFrame: Bool
}

public struct DTSXGrammarTimelineComparisonReport: Sendable, Equatable, Codable {
    public let baselinePath: String
    public let candidatePath: String
    public let baselineFrameCount: Int
    public let candidateFrameCount: Int
    public let comparedFrameCount: Int
    public let identicalGrammarFrameCount: Int
    public let firstMismatchFrameIndex: Int?
    public let fieldMismatchCounts: [String: Int]
    public let firstMismatchFrameIndexByField: [String: Int]
    /// Height-onset frames of the baseline timeline (typically the reference
    /// stream) whose grammar differs in the candidate - the highest-priority
    /// divergences for the residual onset/switch pops.
    public let heightOnsetMismatchFrameIndices: [Int]
    public let recordedMismatches: [DTSXGrammarFieldMismatch]
    public let recordedMismatchLimitReached: Bool
    public let grammarIsIdentical: Bool
}

public enum DTSXGrammarTimelineComparator {
    private static let recordedMismatchLimit = 256

    public static func compare(
        baseline: DTSXGrammarTimelineReport,
        candidate: DTSXGrammarTimelineReport
    ) -> DTSXGrammarTimelineComparisonReport {
        let comparedFrameCount = min(
            baseline.frames.count,
            candidate.frames.count
        )
        let onsetFrames = Set(baseline.summary.heightOnsetFrameIndices)
        var identicalGrammarFrameCount = 0
        var firstMismatchFrameIndex: Int?
        var fieldMismatchCounts: [String: Int] = [:]
        var firstMismatchFrameIndexByField: [String: Int] = [:]
        var onsetMismatchFrameIndices: [Int] = []
        var recorded: [DTSXGrammarFieldMismatch] = []
        var limitReached = false

        for frameIndex in 0..<comparedFrameCount {
            let baselineFields = grammarFields(of: baseline.frames[frameIndex])
            let candidateFields = grammarFields(of: candidate.frames[frameIndex])
            var frameIsIdentical = true
            for (field, baselineValue) in baselineFields {
                let candidateValue = candidateFields[field] ?? "<missing>"
                guard baselineValue != candidateValue else { continue }
                frameIsIdentical = false
                fieldMismatchCounts[field, default: 0] += 1
                if firstMismatchFrameIndexByField[field] == nil {
                    firstMismatchFrameIndexByField[field] = frameIndex
                }
                if recorded.count < recordedMismatchLimit {
                    recorded.append(DTSXGrammarFieldMismatch(
                        frameIndex: frameIndex,
                        field: field,
                        baseline: baselineValue,
                        candidate: candidateValue,
                        isHeightOnsetFrame: onsetFrames.contains(frameIndex)
                    ))
                } else {
                    limitReached = true
                }
            }
            if frameIsIdentical {
                identicalGrammarFrameCount += 1
            } else {
                if firstMismatchFrameIndex == nil {
                    firstMismatchFrameIndex = frameIndex
                }
                if onsetFrames.contains(frameIndex) {
                    onsetMismatchFrameIndices.append(frameIndex)
                }
            }
        }

        return DTSXGrammarTimelineComparisonReport(
            baselinePath: baseline.summary.inputPath,
            candidatePath: candidate.summary.inputPath,
            baselineFrameCount: baseline.frames.count,
            candidateFrameCount: candidate.frames.count,
            comparedFrameCount: comparedFrameCount,
            identicalGrammarFrameCount: identicalGrammarFrameCount,
            firstMismatchFrameIndex: firstMismatchFrameIndex,
            fieldMismatchCounts: fieldMismatchCounts,
            firstMismatchFrameIndexByField: firstMismatchFrameIndexByField,
            heightOnsetMismatchFrameIndices: onsetMismatchFrameIndices,
            recordedMismatches: recorded,
            recordedMismatchLimitReached: limitReached,
            grammarIsIdentical: firstMismatchFrameIndex == nil
                && baseline.frames.count == candidate.frames.count
        )
    }

    /// The grammar-bearing fields of one frame record as stable strings.
    /// PCM-derived context (bed audibility, activity mask) is included
    /// because a mask difference at an aligned access unit means the two
    /// encodes disagree about what is audible - itself a finding.
    private static func grammarFields(
        of record: DTSXGrammarFrameRecord
    ) -> [String: String] {
        var fields: [String: String] = [:]
        fields["publicSegmentCount"] = String(record.publicSegmentCount)
        fields["publicSegmentSampleCount"] = String(record.publicSegmentSampleCount)
        fields["publicNaviSegmentByteCounts"] =
            String(describing: record.publicNaviSegmentByteCounts)
        fields["publicUsesResearchSyntax"] = String(record.publicUsesResearchSyntax)
        fields["exssHeaderByteCount"] = describeOptional(record.exssHeaderByteCount)
        fields["exssAssetDescriptorByteCount"] =
            describeOptional(record.exssAssetDescriptorByteCount)
        fields["exssAssetDescriptorClosesXLLFrame"] =
            describeOptional(record.exssAssetDescriptorClosesXLLFrame)
        fields["hasPrivateExtension"] = String(record.hasPrivateExtension)
        fields["privateParseFailure"] = record.privateParseFailure ?? "<none>"
        fields["privateFrameByteCount"] = describeOptional(record.privateFrameByteCount)
        fields["privateSilenceForm"] = record.privateSilenceForm ?? "<active>"
        fields["activeHeightPlaneMask"] = String(record.activeHeightPlaneMask)
        fields["privateRoutingTenBitCode"] =
            describeOptional(record.privateRoutingTenBitCode)
        fields["privateDecorrelationBranchCode"] =
            describeOptional(record.privateDecorrelationBranchCode)
        fields["privatePrimarySixBitCode"] =
            describeOptional(record.privatePrimarySixBitCode)
        fields["privatePredictionBoundaryByteCount"] =
            describeOptional(record.privatePredictionBoundaryByteCount)
        fields["privateAdaptivePredictionOrders"] =
            record.privateAdaptivePredictionOrders.map(String.init(describing:))
                ?? "<none>"
        fields["privateNavigationBitWidth"] =
            describeOptional(record.privateNavigationBitWidth)
        fields["privateNavigationSegmentByteCounts"] =
            record.privateNavigationSegmentByteCounts.map(String.init(describing:))
                ?? "<none>"
        fields["privateNavigationTrailingFrameByteCount"] =
            describeOptional(record.privateNavigationTrailingFrameByteCount)
        fields["privateEntropySegments"] =
            record.privateEntropySegments.map(describeEntropySegments) ?? "<none>"
        fields["bedIsAudible"] = describeOptional(record.bedIsAudible)
        return fields
    }

    private static func describeEntropySegments(
        _ segments: [DTSXGrammarEntropySegmentRecord]
    ) -> String {
        var parts: [String] = []
        parts.reserveCapacity(segments.count)
        for segment in segments {
            var text = "seg" + String(segment.segmentIndex)
            text += ":reuse=" + String(describing: segment.reusesPreviousParameters)
            text += ",common=" + String(describing: segment.commonParameters)
            text += ",rice=" + String(describing: segment.riceCoding)
            text += ",abit=" + String(describing: segment.bitAllocations)
            text += ",abit0=" + String(describing: segment.partABitAllocations)
            text += ",partA=" + String(describing: segment.partASampleCounts)
            text += ",hybrid=" + String(describing: segment.hybridLinearWidths)
            parts.append(text)
        }
        return parts.joined(separator: "; ")
    }

    private static func describeOptional<Value>(_ value: Value?) -> String {
        value.map { String(describing: $0) } ?? "<none>"
    }
}
