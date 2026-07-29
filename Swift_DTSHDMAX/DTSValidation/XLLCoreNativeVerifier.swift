import Foundation

public struct XLLCoreNativeVerificationReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let coreDecoder: String
    public let sourceProfile: String
    public let sourceDirectory: String
    public let streamSHA256: String
    public let xllFrameCount: Int
    public let coreSampleCount: Int
    public let sourceSampleCount: Int
    public let leadingPrimingSampleCount: Int
    public let comparisons: [XLLChannelPCMComparison]
    public let isBitExactWithZeroPadding: Bool
}

public enum XLLCoreNativeVerifier {
    public static func verify(
        inputURL: URL,
        sourceDirectory: URL
    ) throws -> XLLCoreNativeVerificationReport {
        let input = inputURL.standardizedFileURL
        let core = try DTSCoreStreamDecoder.decode(inputURL: input)
        let common = try XLLCoreOracleVerifier.verifyReconstruction(
            inputURL: input,
            corePCMSource: "pure-swift:DTSCoreDecoder",
            corePlanes: core.planes,
            coreSampleCount: core.sampleCount,
            sourceDirectory: sourceDirectory
        )
        return XLLCoreNativeVerificationReport(
            inputPath: common.inputPath,
            coreDecoder: "pure-swift:DTSCoreDecoder",
            sourceProfile: "discrete-7.1-pcm",
            sourceDirectory: common.sourceDirectory,
            streamSHA256: common.streamSHA256,
            xllFrameCount: common.xllFrameCount,
            coreSampleCount: common.coreSampleCount,
            sourceSampleCount: common.sourceSampleCount,
            leadingPrimingSampleCount: common.leadingPrimingSampleCount,
            comparisons: common.comparisons,
            isBitExactWithZeroPadding: common.isBitExactWithZeroPadding
        )
    }

    public static func verifyDTSXCompatibilityBed(
        inputURL: URL,
        sourceDirectory: URL,
        maximumSourceFrameCount: Int? = nil
    ) throws -> XLLCoreNativeVerificationReport {
        let input = inputURL.standardizedFileURL
        let core = try DTSCoreStreamDecoder.decode(inputURL: input)
        let completeSource = try DTS714SourceSet.loadLegacySevenOne(directory: sourceDirectory)
        let source: PCMBuffer
        if let maximumSourceFrameCount {
            guard maximumSourceFrameCount > 0 else {
                throw DTSError.invalidArgument("SOURCE_FRAME_COUNT must be positive")
            }
            let (sampleCount, overflow) = maximumSourceFrameCount.multipliedReportingOverflow(
                by: XLLSyntax.frameSampleCount
            )
            guard !overflow, sampleCount <= completeSource.sampleCount else {
                throw DTSError.valueOutOfRange(
                    field: "DTS:X compatibility source frame count",
                    value: String(maximumSourceFrameCount)
                )
            }
            source = try completeSource.frame(at: 0, count: sampleCount)
        } else {
            source = completeSource
        }
        let common = try XLLCoreOracleVerifier.verifyReconstruction(
            inputURL: input,
            corePCMSource: "pure-swift:DTSCoreDecoder",
            corePlanes: core.planes,
            coreSampleCount: core.sampleCount,
            source: source,
            sourceDirectory: sourceDirectory
        )
        return XLLCoreNativeVerificationReport(
            inputPath: common.inputPath,
            coreDecoder: "pure-swift:DTSCoreDecoder",
            sourceProfile: "dtsx-7.1.4-to-legacy-7.1:-3.0103dB-height-fold",
            sourceDirectory: common.sourceDirectory,
            streamSHA256: common.streamSHA256,
            xllFrameCount: common.xllFrameCount,
            coreSampleCount: common.coreSampleCount,
            sourceSampleCount: common.sourceSampleCount,
            leadingPrimingSampleCount: common.leadingPrimingSampleCount,
            comparisons: common.comparisons,
            isBitExactWithZeroPadding: common.isBitExactWithZeroPadding
        )
    }
}
