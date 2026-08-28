import Foundation

/// SMPTE timecode → access-unit mapping and windowed grammar census for the
/// TBH pop-window investigation.
///
/// Louis's hardware flags pops inside two programme timecode windows of the
/// TBH master. Timecode is a picture timebase; the delivery stream is a
/// 512-sample access-unit timebase with a Core-priming prefix, so every
/// window question ("what does the stream declare where it pops?") first
/// needs an exact, documented conversion. This analyzer owns that conversion
/// and then slices the whole-programme grammar timeline
/// (``DTSXGrammarTimelineExporter``) to the mapped access-unit ranges,
/// reporting every terminal-visible declaration change inside each window:
/// private silence-form transitions, height-activity onsets and releases,
/// public partition or NAVI changes, routing/branch changes, entropy ABIT
/// jumps, and private parse failures. It never modifies delivery bytes.

// MARK: - Timecode

/// Non-drop SMPTE timecode (`HH:MM:SS:FF`). Drop-frame is rejected by
/// ``DTSFrameRate``; fractional rates count frames on their nominal clock.
public struct DTSTimecode: Sendable, Equatable {
    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let frames: Int

    public init(argument: String, nominalFramesPerSecond: Int) throws {
        let parts = argument.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Int(parts[2]),
              let frames = Int(parts[3]) else {
            throw DTSError.invalidArgument(
                "timecode must be HH:MM:SS:FF, got \(argument)"
            )
        }
        guard (0...99).contains(hours),
              (0...59).contains(minutes),
              (0...59).contains(seconds),
              (0..<nominalFramesPerSecond).contains(frames) else {
            throw DTSError.invalidArgument(
                "timecode \(argument) is out of range for \(nominalFramesPerSecond) fps"
            )
        }
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    init(videoFrameIndex: Int, nominalFramesPerSecond: Int) {
        let totalSeconds = videoFrameIndex / nominalFramesPerSecond
        frames = videoFrameIndex % nominalFramesPerSecond
        seconds = totalSeconds % 60
        minutes = (totalSeconds / 60) % 60
        hours = totalSeconds / 3_600
    }

    public func videoFrameIndex(nominalFramesPerSecond: Int) -> Int {
        ((hours * 60 + minutes) * 60 + seconds) * nominalFramesPerSecond + frames
    }

    public var text: String {
        String(
            format: "%02d:%02d:%02d:%02d",
            hours, minutes, seconds, frames
        )
    }
}

/// One `START-END` timecode window. The end timecode is exclusive: the
/// window covers picture time from the first sample of the start frame up
/// to (not including) the first sample of the end frame.
public struct DTSTimecodeWindow: Sendable, Equatable {
    public let start: DTSTimecode
    public let end: DTSTimecode

    public init(argument: String, nominalFramesPerSecond: Int) throws {
        let parts = argument.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw DTSError.invalidArgument(
                "timecode window must be HH:MM:SS:FF-HH:MM:SS:FF, got \(argument)"
            )
        }
        start = try DTSTimecode(
            argument: String(parts[0]),
            nominalFramesPerSecond: nominalFramesPerSecond
        )
        end = try DTSTimecode(
            argument: String(parts[1]),
            nominalFramesPerSecond: nominalFramesPerSecond
        )
        guard start.videoFrameIndex(nominalFramesPerSecond: nominalFramesPerSecond)
            < end.videoFrameIndex(nominalFramesPerSecond: nominalFramesPerSecond) else {
            throw DTSError.invalidArgument(
                "timecode window \(argument) does not move forward"
            )
        }
    }
}

// MARK: - Mapping

/// Exact conversion record from one timecode window to sample and
/// access-unit ranges. All access-unit ranges are half-open (`end`
/// exclusive). `content` indices count source access units from programme
/// start; `stream` indices additionally include the Core-priming prefix,
/// matching ``DTSXGrammarFrameRecord/frameIndex``.
public struct DTSXPopWindowMapping: Sendable, Equatable, Codable {
    public let startTimecode: String
    /// Exclusive window end.
    public let endTimecode: String
    public let frameRate: String
    public let nominalFramesPerSecond: Int
    public let startVideoFrameIndex: Int
    public let endVideoFrameIndex: Int
    public let videoFrameCount: Int
    /// First 48 kHz sample of the window (floor of the exact rational).
    public let startSampleIndex: Int
    /// Exclusive 48 kHz sample end (ceiling of the exact rational).
    public let endSampleIndex: Int
    /// True when both boundaries land exactly on integer sample positions.
    public let sampleBoundariesAreExact: Bool
    /// floor(startSampleIndex / 512): first access unit overlapping the window.
    public let startContentAccessUnit: Int
    /// ceil(endSampleIndex / 512): exclusive access-unit end.
    public let endContentAccessUnit: Int
    public let primingAccessUnitCount: Int
    public let startStreamAccessUnit: Int
    public let endStreamAccessUnit: Int
    public let windowDurationSeconds: Double
}

public enum DTSXPopWindowMapper {
    static let sampleRate = 48_000
    static let accessUnitSampleCount = XLLSyntax.frameSampleCount
    public static let defaultPrimingAccessUnitCount =
        XLLSyntax.coreCompatiblePrimingSampleCount / XLLSyntax.frameSampleCount

    public static func mapping(
        window: DTSTimecodeWindow,
        frameRate: DTSFrameRate,
        primingAccessUnitCount: Int
    ) throws -> DTSXPopWindowMapping {
        guard primingAccessUnitCount >= 0 else {
            throw DTSError.invalidArgument("priming access-unit count must be non-negative")
        }
        let nominal = frameRate.nominalFramesPerSecond
        let startVideoFrame = window.start.videoFrameIndex(nominalFramesPerSecond: nominal)
        let endVideoFrame = window.end.videoFrameIndex(nominalFramesPerSecond: nominal)
        // sample = videoFrame * 48000 * den / num, kept in Int64 rationals.
        // TBH-scale programmes stay far below Int64 limits here.
        func scaledSamples(_ videoFrame: Int) -> (floor: Int, isExact: Bool) {
            let numerator = Int64(videoFrame) * Int64(sampleRate) * Int64(frameRate.denominator)
            let divisor = Int64(frameRate.numerator)
            return (Int(numerator / divisor), numerator % divisor == 0)
        }
        let start = scaledSamples(startVideoFrame)
        let endExact = scaledSamples(endVideoFrame)
        let endSample = endExact.isExact ? endExact.floor : endExact.floor + 1
        let startContentAccessUnit = start.floor / accessUnitSampleCount
        let endContentAccessUnit = (endSample + accessUnitSampleCount - 1) / accessUnitSampleCount
        return DTSXPopWindowMapping(
            startTimecode: window.start.text,
            endTimecode: window.end.text,
            frameRate: frameRate.description,
            nominalFramesPerSecond: nominal,
            startVideoFrameIndex: startVideoFrame,
            endVideoFrameIndex: endVideoFrame,
            videoFrameCount: endVideoFrame - startVideoFrame,
            startSampleIndex: start.floor,
            endSampleIndex: endSample,
            sampleBoundariesAreExact: start.isExact && endExact.isExact,
            startContentAccessUnit: startContentAccessUnit,
            endContentAccessUnit: endContentAccessUnit,
            primingAccessUnitCount: primingAccessUnitCount,
            startStreamAccessUnit: startContentAccessUnit + primingAccessUnitCount,
            endStreamAccessUnit: endContentAccessUnit + primingAccessUnitCount,
            windowDurationSeconds: Double(endSample - start.floor) / Double(sampleRate)
        )
    }
}

// MARK: - Windowed census

/// One terminal-visible declaration change between two consecutive access
/// units inside a surveyed window (margin included).
public struct DTSXPopWindowGrammarTransition: Sendable, Equatable, Codable {
    public let frameIndex: Int
    /// Picture timecode of the access unit's first sample (nominal clock).
    public let approximateTimecode: String
    public let field: String
    public let previousValue: String
    public let currentValue: String
    /// False when the transition sits in the margin outside the exact window.
    public let isInsideWindow: Bool
}

public struct DTSXPopWindowCensus: Sendable, Equatable, Codable {
    public let mapping: DTSXPopWindowMapping
    public let marginAccessUnits: Int
    /// Clamped half-open stream frame range actually surveyed (window plus
    /// margin on both sides).
    public let surveyedStartFrameIndex: Int
    public let surveyedEndFrameIndex: Int
    /// True when the mapped window is fully covered by the stream.
    public let windowIsWithinStream: Bool
    public let frameCountInsideWindow: Int
    public let heightOnsetFrameIndices: [Int]
    public let heightActivityTransitionFrameIndices: [Int]
    public let heightOnsetsPerSecond: Double
    public let silenceFormCounts: [String: Int]
    /// Entropy-declaration form of every surveyed bed-audible zero-height
    /// navigated frame (the TBH pop-window seam class), keyed by
    /// `shared-zero` (compact `ncSegType = 1` whole-frame declaration),
    /// `per-channel-linear-zero` (bridged per-plane width-0 declarations),
    /// or `sticky-rice` (bridged Rice declarations over zero residuals).
    /// This is the one-command arbitration signal for the seam-policy A/B
    /// candidates and for the official-reference census.
    public let zeroHeightSeamFormCounts: [String: Int]
    public let activeFrameCount: Int
    public let bedAudibleFrameCount: Int
    public let privateParseFailureFrameIndices: [Int]
    public let publicSegmentCounts: [Int]
    public let privateNavigationBitWidthCounts: [String: Int]
    public let maximumPublicRiceUnaryQuotient: Int
    public let maximumPrivateRiceUnaryQuotient: UInt64
    /// Largest per-plane part-B Rice allocation seen in the surveyed range.
    public let maximumPrivateBitAllocation: Int
    /// Largest increase of that per-frame maximum between two consecutive
    /// frames - the ABIT jump a silence→active or switch seam produces.
    public let maximumPrivateBitAllocationIncrease: Int
    public let minimumPrivateFrameByteCount: Int?
    public let maximumPrivateFrameByteCount: Int?
    public let grammarTransitionCount: Int
    public let grammarTransitions: [DTSXPopWindowGrammarTransition]
    public let grammarTransitionRecordLimitReached: Bool
}

/// Per-window counts without the transition list, for terminal output.
public struct DTSXPopWindowCensusSummary: Sendable, Equatable, Codable {
    public let mapping: DTSXPopWindowMapping
    public let windowIsWithinStream: Bool
    public let heightOnsetCount: Int
    public let heightActivityTransitionCount: Int
    public let heightOnsetsPerSecond: Double
    public let silenceFormCounts: [String: Int]
    public let zeroHeightSeamFormCounts: [String: Int]
    public let activeFrameCount: Int
    public let bedAudibleFrameCount: Int
    public let privateParseFailureCount: Int
    public let publicSegmentCounts: [Int]
    public let privateNavigationBitWidthCounts: [String: Int]
    public let maximumPrivateBitAllocation: Int
    public let maximumPrivateBitAllocationIncrease: Int
    public let grammarTransitionCount: Int
}

public struct DTSXPopWindowAnalysisSummary: Sendable, Equatable, Codable {
    public let inputPath: String
    public let streamSHA256: String
    public let frameRate: String
    public let accessUnitCount: Int
    public let xllFrameCount: Int
    public let primingFrameCount: Int
    public let marginAccessUnits: Int
    /// Whole-programme onset count, for density comparison against windows.
    public let totalHeightOnsetCount: Int
    public let heightOnsetCountInsideWindows: Int
    public let windows: [DTSXPopWindowCensusSummary]
}

public struct DTSXPopWindowAnalysisReport: Sendable, Equatable, Codable {
    public let summary: DTSXPopWindowAnalysisSummary
    public let windows: [DTSXPopWindowCensus]
}

public enum DTSXPopWindowAnalyzer {
    static let recordedTransitionLimit = 200

    public static func analyze(
        inputURL: URL,
        windowArguments: [String],
        frameRateOverride: DTSFrameRate?,
        marginAccessUnits: Int = 8,
        maximumFrameCount: Int? = nil
    ) throws -> DTSXPopWindowAnalysisReport {
        guard !windowArguments.isEmpty else {
            throw DTSError.invalidArgument(
                "pop-window analysis requires at least one HH:MM:SS:FF-HH:MM:SS:FF window"
            )
        }
        guard marginAccessUnits >= 0 else {
            throw DTSError.invalidArgument("margin access-unit count must be non-negative")
        }
        let containerFrameRate = try DTSHDFileContainer.authoringFrameRate(at: inputURL)
        if let containerFrameRate, let frameRateOverride,
           containerFrameRate != frameRateOverride {
            throw DTSError.invalidArgument(
                "--frame-rate \(frameRateOverride) differs from stream TIMECODE rate \(containerFrameRate)"
            )
        }
        guard let frameRate = containerFrameRate ?? frameRateOverride else {
            throw DTSError.invalidArgument(
                "stream has no TIMECODE frame rate; specify --frame-rate "
                    + DTSFrameRate.supportedArgumentValues.joined(separator: "|")
            )
        }

        let timeline = try DTSXGrammarTimelineExporter.export(
            inputURL: inputURL,
            maximumFrameCount: maximumFrameCount
        )
        let priming = timeline.summary.primingFrameCount
        let windows = try windowArguments.map {
            try DTSTimecodeWindow(
                argument: $0,
                nominalFramesPerSecond: frameRate.nominalFramesPerSecond
            )
        }

        var censuses: [DTSXPopWindowCensus] = []
        var onsetCountInsideWindows = 0
        for window in windows {
            let census = try census(
                window: window,
                frameRate: frameRate,
                primingAccessUnitCount: priming,
                marginAccessUnits: marginAccessUnits,
                timeline: timeline
            )
            onsetCountInsideWindows += census.heightOnsetFrameIndices.filter {
                $0 >= census.mapping.startStreamAccessUnit
                    && $0 < census.mapping.endStreamAccessUnit
            }.count
            censuses.append(census)
        }

        let summary = DTSXPopWindowAnalysisSummary(
            inputPath: timeline.summary.inputPath,
            streamSHA256: timeline.summary.streamSHA256,
            frameRate: frameRate.description,
            accessUnitCount: timeline.summary.accessUnitCount,
            xllFrameCount: timeline.summary.xllFrameCount,
            primingFrameCount: priming,
            marginAccessUnits: marginAccessUnits,
            totalHeightOnsetCount: timeline.summary.heightOnsetFrameIndices.count,
            heightOnsetCountInsideWindows: onsetCountInsideWindows,
            windows: censuses.map { census in
                DTSXPopWindowCensusSummary(
                    mapping: census.mapping,
                    windowIsWithinStream: census.windowIsWithinStream,
                    heightOnsetCount: census.heightOnsetFrameIndices.count,
                    heightActivityTransitionCount:
                        census.heightActivityTransitionFrameIndices.count,
                    heightOnsetsPerSecond: census.heightOnsetsPerSecond,
                    silenceFormCounts: census.silenceFormCounts,
                    zeroHeightSeamFormCounts: census.zeroHeightSeamFormCounts,
                    activeFrameCount: census.activeFrameCount,
                    bedAudibleFrameCount: census.bedAudibleFrameCount,
                    privateParseFailureCount:
                        census.privateParseFailureFrameIndices.count,
                    publicSegmentCounts: census.publicSegmentCounts,
                    privateNavigationBitWidthCounts:
                        census.privateNavigationBitWidthCounts,
                    maximumPrivateBitAllocation: census.maximumPrivateBitAllocation,
                    maximumPrivateBitAllocationIncrease:
                        census.maximumPrivateBitAllocationIncrease,
                    grammarTransitionCount: census.grammarTransitionCount
                )
            }
        )
        return DTSXPopWindowAnalysisReport(summary: summary, windows: censuses)
    }

    // MARK: - Single-window census

    private static func census(
        window: DTSTimecodeWindow,
        frameRate: DTSFrameRate,
        primingAccessUnitCount: Int,
        marginAccessUnits: Int,
        timeline: DTSXGrammarTimelineReport
    ) throws -> DTSXPopWindowCensus {
        let mapping = try DTSXPopWindowMapper.mapping(
            window: window,
            frameRate: frameRate,
            primingAccessUnitCount: primingAccessUnitCount
        )
        let frameCount = timeline.frames.count
        let surveyedStart = max(0, mapping.startStreamAccessUnit - marginAccessUnits)
        let surveyedEnd = min(frameCount, mapping.endStreamAccessUnit + marginAccessUnits)
        let windowIsWithinStream = mapping.endStreamAccessUnit <= frameCount
        let insideRange = mapping.startStreamAccessUnit..<mapping.endStreamAccessUnit

        var heightOnsets: [Int] = []
        var heightTransitions: [Int] = []
        var silenceFormCounts: [String: Int] = [:]
        var zeroHeightSeamFormCounts: [String: Int] = [:]
        var activeFrameCount = 0
        var bedAudibleFrameCount = 0
        var parseFailures: [Int] = []
        var publicSegmentCounts: Set<Int> = []
        var navigationWidthCounts: [String: Int] = [:]
        var maximumPublicQuotient = 0
        var maximumPrivateQuotient: UInt64 = 0
        var maximumBitAllocation = 0
        var maximumBitAllocationIncrease = 0
        var minimumPrivateByteCount: Int?
        var maximumPrivateByteCount: Int?
        var transitions: [DTSXPopWindowGrammarTransition] = []
        var transitionCount = 0
        var limitReached = false
        var frameCountInsideWindow = 0

        var previous: DTSXGrammarFrameRecord?
        var previousMaximumBitAllocation: Int?
        for frameIndex in surveyedStart..<surveyedEnd {
            let record = timeline.frames[frameIndex]
            let isInsideWindow = insideRange.contains(frameIndex)
            if isInsideWindow { frameCountInsideWindow += 1 }

            if let previous {
                let mask = record.activeHeightPlaneMask
                let previousMask = previous.activeHeightPlaneMask
                if mask & ~previousMask != 0 { heightOnsets.append(frameIndex) }
                if mask != previousMask { heightTransitions.append(frameIndex) }
                for change in grammarChanges(from: previous, to: record) {
                    transitionCount += 1
                    if transitions.count < recordedTransitionLimit {
                        transitions.append(DTSXPopWindowGrammarTransition(
                            frameIndex: frameIndex,
                            approximateTimecode: approximateTimecode(
                                forStreamFrame: frameIndex,
                                primingAccessUnitCount: primingAccessUnitCount,
                                frameRate: frameRate
                            ),
                            field: change.field,
                            previousValue: change.previous,
                            currentValue: change.current,
                            isInsideWindow: isInsideWindow
                        ))
                    } else {
                        limitReached = true
                    }
                }
            }

            silenceFormCounts[record.privateSilenceForm ?? "<active>", default: 0] += 1
            if let seamForm = zeroHeightSeamForm(of: record) {
                zeroHeightSeamFormCounts[seamForm, default: 0] += 1
            }
            if record.privateIsActive { activeFrameCount += 1 }
            if record.bedIsAudible == true { bedAudibleFrameCount += 1 }
            if record.privateParseFailure != nil { parseFailures.append(frameIndex) }
            publicSegmentCounts.insert(record.publicSegmentCount)
            if let width = record.privateNavigationBitWidth {
                navigationWidthCounts[String(width), default: 0] += 1
            }
            maximumPublicQuotient = max(
                maximumPublicQuotient,
                record.publicMaximumRiceUnaryQuotient
            )
            if let quotient = record.privateMaximumRiceUnaryQuotient {
                maximumPrivateQuotient = max(maximumPrivateQuotient, quotient)
            }
            if let byteCount = record.privateFrameByteCount {
                minimumPrivateByteCount = min(minimumPrivateByteCount ?? byteCount, byteCount)
                maximumPrivateByteCount = max(maximumPrivateByteCount ?? byteCount, byteCount)
            }
            let frameMaximumAllocation = maximumRiceBitAllocation(of: record)
            maximumBitAllocation = max(maximumBitAllocation, frameMaximumAllocation)
            if let previousAllocation = previousMaximumBitAllocation {
                maximumBitAllocationIncrease = max(
                    maximumBitAllocationIncrease,
                    frameMaximumAllocation - previousAllocation
                )
            }
            previousMaximumBitAllocation = frameMaximumAllocation
            previous = record
        }

        let onsetsInsideWindow = heightOnsets.filter { insideRange.contains($0) }.count
        return DTSXPopWindowCensus(
            mapping: mapping,
            marginAccessUnits: marginAccessUnits,
            surveyedStartFrameIndex: surveyedStart,
            surveyedEndFrameIndex: surveyedEnd,
            windowIsWithinStream: windowIsWithinStream,
            frameCountInsideWindow: frameCountInsideWindow,
            heightOnsetFrameIndices: heightOnsets,
            heightActivityTransitionFrameIndices: heightTransitions,
            heightOnsetsPerSecond: mapping.windowDurationSeconds > 0
                ? Double(onsetsInsideWindow) / mapping.windowDurationSeconds
                : 0,
            silenceFormCounts: silenceFormCounts,
            zeroHeightSeamFormCounts: zeroHeightSeamFormCounts,
            activeFrameCount: activeFrameCount,
            bedAudibleFrameCount: bedAudibleFrameCount,
            privateParseFailureFrameIndices: parseFailures,
            publicSegmentCounts: publicSegmentCounts.sorted(),
            privateNavigationBitWidthCounts: navigationWidthCounts,
            maximumPublicRiceUnaryQuotient: maximumPublicQuotient,
            maximumPrivateRiceUnaryQuotient: maximumPrivateQuotient,
            maximumPrivateBitAllocation: maximumBitAllocation,
            maximumPrivateBitAllocationIncrease: maximumBitAllocationIncrease,
            minimumPrivateFrameByteCount: minimumPrivateByteCount,
            maximumPrivateFrameByteCount: maximumPrivateByteCount,
            grammarTransitionCount: transitionCount,
            grammarTransitions: transitions,
            grammarTransitionRecordLimitReached: limitReached
        )
    }

    /// Terminal-visible declaration fields whose change between consecutive
    /// access units is a seam candidate. Byte-count and quotient extremes are
    /// summarized separately; this list is deliberately the *declaration*
    /// grammar a bounded reader keys on.
    private static func grammarChanges(
        from previous: DTSXGrammarFrameRecord,
        to current: DTSXGrammarFrameRecord
    ) -> [(field: String, previous: String, current: String)] {
        var changes: [(String, String, String)] = []
        func compare(_ field: String, _ old: String, _ new: String) {
            if old != new { changes.append((field, old, new)) }
        }
        func optional<Value>(_ value: Value?) -> String {
            value.map { String(describing: $0) } ?? "<none>"
        }
        compare(
            "privateSilenceForm",
            previous.privateSilenceForm ?? "<active>",
            current.privateSilenceForm ?? "<active>"
        )
        compare(
            "activeHeightPlaneMask",
            String(previous.activeHeightPlaneMask),
            String(current.activeHeightPlaneMask)
        )
        compare(
            "publicPartition",
            "\(previous.publicSegmentCount)x\(previous.publicSegmentSampleCount)",
            "\(current.publicSegmentCount)x\(current.publicSegmentSampleCount)"
        )
        compare(
            "publicUsesResearchSyntax",
            String(previous.publicUsesResearchSyntax),
            String(current.publicUsesResearchSyntax)
        )
        compare(
            "privateNavigationBitWidth",
            optional(previous.privateNavigationBitWidth),
            optional(current.privateNavigationBitWidth)
        )
        compare(
            "privateRoutingTenBitCode",
            optional(previous.privateRoutingTenBitCode),
            optional(current.privateRoutingTenBitCode)
        )
        compare(
            "privateDecorrelationBranchCode",
            optional(previous.privateDecorrelationBranchCode),
            optional(current.privateDecorrelationBranchCode)
        )
        compare(
            "privatePredictionBoundaryByteCount",
            optional(previous.privatePredictionBoundaryByteCount),
            optional(current.privatePredictionBoundaryByteCount)
        )
        compare(
            "privateAdaptivePredictionOrders",
            optional(previous.privateAdaptivePredictionOrders),
            optional(current.privateAdaptivePredictionOrders)
        )
        compare("bedIsAudible", optional(previous.bedIsAudible), optional(current.bedIsAudible))
        compare(
            "hasPrivateExtension",
            String(previous.hasPrivateExtension),
            String(current.hasPrivateExtension)
        )
        compare(
            "privateParseFailure",
            previous.privateParseFailure ?? "<none>",
            current.privateParseFailure ?? "<none>"
        )
        return changes
    }

    /// Classifies the entropy-declaration form of a bed-audible zero-height
    /// navigated frame (grammar timeline class `navigated-silence`): the
    /// compact shared-parameter whole-frame zero declaration, the bridged
    /// per-channel linear width-0 declarations, or the bridged sticky-Rice
    /// declarations over all-zero residuals. Returns nil for every other
    /// frame class.
    private static func zeroHeightSeamForm(
        of record: DTSXGrammarFrameRecord
    ) -> String? {
        guard record.privateSilenceForm == "navigated-silence",
              let segments = record.privateEntropySegments,
              !segments.isEmpty else { return nil }
        if segments.allSatisfy({ $0.commonParameters }) {
            return "shared-zero"
        }
        if segments.allSatisfy({ segment in
            segment.riceCoding.allSatisfy { !$0 }
                && segment.bitAllocations.allSatisfy { $0 == 0 }
        }) {
            return "per-channel-linear-zero"
        }
        if segments.contains(where: { $0.riceCoding.contains(true) }) {
            return "sticky-rice"
        }
        return "mixed"
    }

    private static func maximumRiceBitAllocation(
        of record: DTSXGrammarFrameRecord
    ) -> Int {
        guard let segments = record.privateEntropySegments else { return 0 }
        var maximum = 0
        for segment in segments {
            for (index, allocation) in segment.bitAllocations.enumerated()
            where index < segment.riceCoding.count && segment.riceCoding[index] {
                maximum = max(maximum, allocation)
            }
        }
        return maximum
    }

    private static func approximateTimecode(
        forStreamFrame frameIndex: Int,
        primingAccessUnitCount: Int,
        frameRate: DTSFrameRate
    ) -> String {
        let contentAccessUnit = max(0, frameIndex - primingAccessUnitCount)
        let sample = Int64(contentAccessUnit)
            * Int64(DTSXPopWindowMapper.accessUnitSampleCount)
        let videoFrame = Int(
            sample * Int64(frameRate.numerator)
                / (Int64(DTSXPopWindowMapper.sampleRate) * Int64(frameRate.denominator))
        )
        return DTSTimecode(
            videoFrameIndex: videoFrame,
            nominalFramesPerSecond: frameRate.nominalFramesPerSecond
        ).text
    }
}
