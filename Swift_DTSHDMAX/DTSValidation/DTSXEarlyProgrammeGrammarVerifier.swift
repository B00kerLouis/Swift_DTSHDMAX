import Foundation

/// Multi-access-unit early-programme grammar report for one DTS:X stream.
///
/// Earlier gates checked only the first access unit (or the first two source
/// frames), which let a stream pass while every active access unit of the
/// first ~10 seconds still carried grammar a terminal bounded reader cannot
/// parse. This report audits a whole startup window - hundreds of 512-sample
/// access units - against the recovered perfect-stream rules:
///
/// 1. Every emitted public XLL Rice unary quotient fits the official-corpus
///    maximum (22). A longer run desyncs terminal bounded readers and turns
///    the rest of the segment into full-scale garbage, which presents as
///    sustained unplayable audio while content stays hot and as random pops
///    at every later transient.
/// 2. Every emitted private XLL-X Rice unary quotient fits the same bound.
/// 3. The public partition follows the frame-indexed official grammar:
///    priming and mid-stream frames are 2x256, and 4x128 appears only on the
///    first two source access units when the access unit is fully silent
///    (the Nature's Fury silent-start transition). The references never pair
///    4x128 with active content.
/// 4. Post-priming delivery frames carry no research-only syntax: no entropy
///    state reuse, no hybrid Rice, no pairwise decorrelation, no prediction.
public struct DTSXEarlyProgrammeGrammarReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let streamSHA256: String
    public let accessUnitCount: Int
    public let measuredAccessUnitCount: Int
    public let primingAccessUnitCount: Int
    public let terminalMaximumUnaryQuotient: Int
    /// Distinct public segment counts observed inside the measured window.
    public let publicSegmentCounts: [Int]
    /// Frames coded 4x128 inside the measured window.
    public let fourSegmentFrameIndices: [Int]
    public let publicPartitionsFollowOfficialGrammar: Bool
    public let publicMaximumRiceUnaryQuotient: Int
    public let publicUnaryBoundExceededFrameCount: Int
    public let publicFirstUnaryBoundExceededFrameIndex: Int?
    public let publicResearchSyntaxFrameCount: Int
    public let publicFirstResearchSyntaxFrameIndex: Int?
    public let privateFrameCount: Int
    public let privateMaximumUnaryQuotient: UInt64
    public let privateUnaryBoundExceededFrameCount: Int
    public let privateFirstUnaryBoundExceededFrameIndex: Int?
    public let isEarlyProgrammeSafe: Bool
}

/// Gates the first ~10 seconds of programme (or the requested window) as one
/// unit instead of trusting single-access-unit checks.
public enum DTSXEarlyProgrammeGrammarVerifier {
    /// Longest unary quotient observed anywhere in the recovered official
    /// corpus; shared by the public XLL and private XLL-X bounded readers.
    public static let terminalMaximumUnaryQuotient = 22
    /// ~10.24 s of 512-sample access units at 48 kHz. Louis's tbh symptom is
    /// "the first ~10 seconds do not play"; the default window covers it.
    public static let defaultWindowAccessUnitCount = 960
    private static let xllXSyncWord: UInt32 = 0x0200_0850

    public static func verify(
        inputURL: URL,
        maximumAccessUnitCount: Int? = nil
    ) throws -> DTSXEarlyProgrammeGrammarReport {
        if let maximumAccessUnitCount, maximumAccessUnitCount <= 0 {
            throw DTSError.invalidArgument(
                "early-programme window must be a positive access-unit count"
            )
        }
        let input = inputURL.standardizedFileURL
        let stream = try XLLPBRStreamReader.read(inputURL: input)
        guard !stream.frames.isEmpty else {
            throw DTSError.malformed("early-programme verification requires XLL frames")
        }
        let primingFrameCount = stream.hasBackwardCompatibleCore
            ? XLLSyntax.coreCompatiblePrimingSampleCount / XLLSyntax.frameSampleCount
            : 0
        let window = min(
            stream.frames.count,
            maximumAccessUnitCount ?? defaultWindowAccessUnitCount
        )

        var segmentCounts: Set<Int> = []
        var fourSegmentFrameIndices: [Int] = []
        var partitionsFollowOfficialGrammar = true
        var publicMaximumQuotient = 0
        var publicUnaryBoundExceededFrameCount = 0
        var publicFirstUnaryBoundExceededFrameIndex: Int?
        var publicResearchSyntaxFrameCount = 0
        var publicFirstResearchSyntaxFrameIndex: Int?
        var privateFrameCount = 0
        var privateMaximumQuotient: UInt64 = 0
        var privateUnaryBoundExceededFrameCount = 0
        var privateFirstUnaryBoundExceededFrameIndex: Int?

        for (frameIndex, frame) in stream.frames.prefix(window).enumerated() {
            let ast = try XLLFrameASTParser.parse(frame.frame)
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            segmentCounts.insert(ast.segmentCount)

            let publicPlanesAreSilent = decoded.channelSets.allSatisfy { channelSet in
                channelSet.planes.allSatisfy { plane in
                    plane.allSatisfy { $0 == 0 }
                }
            }

            let privateQuotient: UInt64?
            let privatePlanesAreSilent: Bool
            if let audit = try auditPrivateExtension(
                ast: ast,
                segmentCount: ast.segmentCount,
                segmentSampleCount: ast.segmentSampleCount
            ) {
                privateFrameCount += 1
                privateQuotient = audit.maximumQuotient
                privatePlanesAreSilent = audit.planesAreSilent
                privateMaximumQuotient = max(privateMaximumQuotient, audit.maximumQuotient)
                if audit.maximumQuotient > UInt64(terminalMaximumUnaryQuotient) {
                    privateUnaryBoundExceededFrameCount += 1
                    if privateFirstUnaryBoundExceededFrameIndex == nil {
                        privateFirstUnaryBoundExceededFrameIndex = frameIndex
                    }
                }
            } else {
                privateQuotient = nil
                privatePlanesAreSilent = true
            }
            _ = privateQuotient

            // Partition grammar. Priming AUs and mid-stream AUs are 2x256;
            // 4x128 is legal only for the first two source AUs of a fully
            // silent start.
            switch ast.segmentCount {
            case 2:
                break
            case 4:
                fourSegmentFrameIndices.append(frameIndex)
                let inSilentStartWindow = frameIndex >= primingFrameCount
                    && frameIndex < primingFrameCount + 2
                if !(inSilentStartWindow && publicPlanesAreSilent && privatePlanesAreSilent) {
                    partitionsFollowOfficialGrammar = false
                }
            default:
                partitionsFollowOfficialGrammar = false
            }

            publicMaximumQuotient = max(
                publicMaximumQuotient,
                decoded.maximumRiceUnaryQuotient
            )
            if decoded.maximumRiceUnaryQuotient > terminalMaximumUnaryQuotient {
                publicUnaryBoundExceededFrameCount += 1
                if publicFirstUnaryBoundExceededFrameIndex == nil {
                    publicFirstUnaryBoundExceededFrameIndex = frameIndex
                }
            }

            // Research-only syntax must stay out of post-priming delivery
            // frames. The compact priming form legitimately declares identity
            // pairwise decorrelation and common entropy parameters.
            if frameIndex >= primingFrameCount {
                let usesResearchSyntax = decoded.entropyStateReuseSegmentCount > 0
                    || decoded.hybridRiceParameterCount > 0
                    || decoded.hybridIsolatedSampleCount > 0
                    || decoded.entropyCommonParameterSegmentCount > 0
                    || decoded.channelSets.contains { channelSet in
                        channelSet.decorrelationEnabled
                            || channelSet.adaptivePredictionOrders.contains { $0 > 0 }
                            || channelSet.fixedPredictionOrders.contains { $0 > 0 }
                    }
                if usesResearchSyntax {
                    publicResearchSyntaxFrameCount += 1
                    if publicFirstResearchSyntaxFrameIndex == nil {
                        publicFirstResearchSyntaxFrameIndex = frameIndex
                    }
                }
            }
        }

        let isSafe = partitionsFollowOfficialGrammar
            && publicUnaryBoundExceededFrameCount == 0
            && publicResearchSyntaxFrameCount == 0
            && privateUnaryBoundExceededFrameCount == 0
        return DTSXEarlyProgrammeGrammarReport(
            inputPath: input.path,
            streamSHA256: try SHA256Hasher.hash(fileAt: input),
            accessUnitCount: stream.frames.count,
            measuredAccessUnitCount: window,
            primingAccessUnitCount: primingFrameCount,
            terminalMaximumUnaryQuotient: terminalMaximumUnaryQuotient,
            publicSegmentCounts: segmentCounts.sorted(),
            fourSegmentFrameIndices: fourSegmentFrameIndices,
            publicPartitionsFollowOfficialGrammar: partitionsFollowOfficialGrammar,
            publicMaximumRiceUnaryQuotient: publicMaximumQuotient,
            publicUnaryBoundExceededFrameCount: publicUnaryBoundExceededFrameCount,
            publicFirstUnaryBoundExceededFrameIndex: publicFirstUnaryBoundExceededFrameIndex,
            publicResearchSyntaxFrameCount: publicResearchSyntaxFrameCount,
            publicFirstResearchSyntaxFrameIndex: publicFirstResearchSyntaxFrameIndex,
            privateFrameCount: privateFrameCount,
            privateMaximumUnaryQuotient: privateMaximumQuotient,
            privateUnaryBoundExceededFrameCount: privateUnaryBoundExceededFrameCount,
            privateFirstUnaryBoundExceededFrameIndex: privateFirstUnaryBoundExceededFrameIndex,
            isEarlyProgrammeSafe: isSafe
        )
    }

    private struct PrivateExtensionAudit {
        let maximumQuotient: UInt64
        let planesAreSilent: Bool
    }

    /// Measures the exact unary quotients a terminal reads from the embedded
    /// XLL-X frame. Hybrid-isolated samples are excluded because they are
    /// emitted with the declared signed-linear width instead of a Rice code.
    private static func auditPrivateExtension(
        ast: XLLFrameAST,
        segmentCount: Int,
        segmentSampleCount: Int
    ) throws -> PrivateExtensionAudit? {
        let range = ast.privateDataByteRange
        guard range.count >= 4 else { return nil }
        let bytes = ast.data.subdata(in: range)
        let word = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        guard word == xllXSyncWord else { return nil }
        let privateAST = try DTSXPrivateFrameAST.parse(bytes[...])
        let decoded = try DTSXPrivateFrameDecoder.decode(
            privateAST,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            collectEntropyDiagnostics: true
        )
        let planesAreSilent = decoded.predictionResidualPlanes.allSatisfy { plane in
            plane.allSatisfy { $0 == 0 }
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
                guard (0...31).contains(allocation) else {
                    throw DTSError.valueOutOfRange(
                        field: "early-programme XLL-X ABIT",
                        value: String(allocation)
                    )
                }
                let isHybrid = syntax.hybridLinearWidths[parameter] > 0
                for channel in channels {
                    let partASampleCount = syntax.partASampleCounts[parameter]
                    let segmentStart = syntax.segmentIndex * segmentSampleCount
                    let partBStart = segmentStart + partASampleCount
                    let segmentEnd = segmentStart + segmentSampleCount
                    guard partASampleCount >= 0,
                          partBStart <= segmentEnd,
                          segmentEnd <= decoded.predictionResidualPlanes[channel].count else {
                        throw DTSError.malformed(
                            "early-programme XLL-X part-B range is invalid"
                        )
                    }
                    let isolatedOffsets = isHybrid
                        ? Set(syntax.hybridIsolatedSampleOffsets[channel])
                        : []
                    for sampleIndex in partBStart..<segmentEnd {
                        if isolatedOffsets.contains(sampleIndex - partBStart) { continue }
                        let sample = decoded.predictionResidualPlanes[channel][sampleIndex]
                        let mapped = zigZag(sample)
                        maximumQuotient = max(
                            maximumQuotient,
                            mapped >> UInt64(allocation)
                        )
                    }
                }
            }
        }
        return PrivateExtensionAudit(
            maximumQuotient: maximumQuotient,
            planesAreSilent: planesAreSilent
        )
    }

    @inline(__always)
    private static func zigZag(_ value: Int32) -> UInt64 {
        let signed = Int64(value)
        return signed >= 0
            ? UInt64(signed) << 1
            : UInt64((-signed << 1) - 1)
    }
}
