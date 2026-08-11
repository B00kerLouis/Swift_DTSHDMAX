import Foundation

public struct DTSX714NativeClosedLoopReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let streamSHA256: String
    public let sourceDirectory: String
    public let sourceChannelCount: Int
    public let sourceSampleCountPerChannel: Int
    public let publicBed: XLLCoreNativeVerificationReport
    public let privateHeights: DTSXPrivateHeightVerificationReport
    public let totalComparedSampleCount: Int
    public let totalMismatchCount: Int
    public let isBitExactSevenOneFour: Bool
}

/// Runs both halves of the native DTS:X reconstruction against the same
/// explicit 7.1.4 source: Core + public XLL for the compatibility bed and the
/// routed XLL-X private payload for the four height channels.
public enum DTSX714NativeClosedLoopVerifier {
    public static func verify(
        inputURL: URL,
        sourceDirectory: URL,
        maximumSourceFrameCount: Int? = nil
    ) throws -> DTSX714NativeClosedLoopReport {
        let input = inputURL.standardizedFileURL
        let sourcePath = sourceDirectory.standardizedFileURL
        let source = try DTS714SourceSet.load(directory: sourcePath)
        let requestedSourceSampleCount: Int
        if let maximumSourceFrameCount {
            guard maximumSourceFrameCount > 0 else {
                throw DTSError.invalidArgument("SOURCE_FRAME_COUNT must be positive")
            }
            let (sampleCount, overflow) = maximumSourceFrameCount.multipliedReportingOverflow(
                by: XLLSyntax.frameSampleCount
            )
            guard !overflow, sampleCount <= source.sampleCount else {
                throw DTSError.valueOutOfRange(
                    field: "DTS:X 7.1.4 closed-loop source frame count",
                    value: String(maximumSourceFrameCount)
                )
            }
            requestedSourceSampleCount = sampleCount
        } else {
            requestedSourceSampleCount = source.sampleCount
        }

        let publicBed = try XLLCoreNativeVerifier.verifyDTSXCompatibilityBed(
            inputURL: input,
            sourceDirectory: sourcePath,
            maximumSourceFrameCount: maximumSourceFrameCount
        )
        let privateHeights = try DTSXPrivateHeightVerifier.verify(
            inputURL: input,
            source: source,
            maximumSourceFrameCount: maximumSourceFrameCount
        )
        let publicMismatchCount = publicBed.comparisons.reduce(0) {
            $0 + $1.mismatchCount + $1.nonzeroTailSampleCount
        }
        let totalMismatchCount = publicMismatchCount
            + privateHeights.differentHeightSampleCount
            + privateHeights.nonzeroPaddingSampleCount
            + privateHeights.frameBoundaryDeltaMismatchCount
            + privateHeights.segmentBoundaryDeltaMismatchCount
        let publicComparedSampleCount = publicBed.comparisons.reduce(0) {
            $0 + min($1.expectedSampleCount, $1.decodedSampleCount)
        }
        return DTSX714NativeClosedLoopReport(
            inputPath: input.path,
            streamSHA256: publicBed.streamSHA256,
            sourceDirectory: sourcePath.path,
            sourceChannelCount: DTS714Channel.allCases.count,
            sourceSampleCountPerChannel: requestedSourceSampleCount,
            publicBed: publicBed,
            privateHeights: privateHeights,
            totalComparedSampleCount: publicComparedSampleCount
                + privateHeights.comparedHeightSampleCount,
            totalMismatchCount: totalMismatchCount,
            isBitExactSevenOneFour: publicBed.isBitExactWithZeroPadding
                && privateHeights.isBitExact
                && totalMismatchCount == 0
        )
    }
}
