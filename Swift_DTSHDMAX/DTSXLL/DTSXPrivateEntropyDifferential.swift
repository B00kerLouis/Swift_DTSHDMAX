import Foundation

/// The decoded syntax of one XLL-X frame. A failed candidate is retained as a
/// report value so an unknown official grammar is never silently counted as a
/// successful Rice parse.
public struct DTSXPrivateEntropyFrameSyntax: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let privateFrameByteCount: Int
    public let segmentCount: Int
    public let segmentSampleCount: Int
    public let primarySixBitCode: Int?
    public let secondaryBranchCode: Int?
    public let decoded: Bool
    public let usesCompactZeroEntropySyntax: Bool
    public let noNavigationZeroSideInfo: Bool
    public let error: String?
    public let entropySegments: [DTSXPrivateEntropySegmentSyntax]
}

public struct DTSXPrivateEntropySyntaxMetrics: Sendable, Equatable, Codable {
    public let frameCount: Int
    public let decodedFrameCount: Int
    public let compactZeroFrameCount: Int
    public let noNavigationFrameCount: Int
    public let privateByteCount: Int
    public let entropySegmentCount: Int
    public let stateReuseSegmentCount: Int
    public let commonParameterSegmentCount: Int
    public let riceParameterCount: Int
    public let hybridRiceParameterCount: Int
}

public struct DTSXPrivateEntropyDifferentialSummary: Sendable, Equatable, Codable {
    public let baselineIndexPath: String
    public let baselinePayloadPath: String
    public let variantIndexPath: String
    public let variantPayloadPath: String
    public let requestedFrameOffset: Int
    public let requestedMaximumFrameCount: Int?
    public let comparedFrameCount: Int
    public let frameIndexMismatchCount: Int
    public let publicSegmentationMismatchCount: Int
    public let samePublicSegmentationFrameCount: Int
    /// Includes only frames whose public XLL segmentation matches and whose
    /// recovered private entropy grammar closed on both sides.
    public let comparableSameSegmentation: DTSXPrivateEntropyComparableMetrics
    public let baseline: DTSXPrivateEntropySyntaxMetrics
    public let variant: DTSXPrivateEntropySyntaxMetrics
}

public struct DTSXPrivateEntropyFrameDifferential: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let publicSegmentationMatches: Bool
    public let baseline: DTSXPrivateEntropyFrameSyntax
    public let variant: DTSXPrivateEntropyFrameSyntax
}

public struct DTSXPrivateEntropyBranchPairFrequency: Sendable, Equatable, Codable {
    public let baselineBranchCode: Int
    public let variantBranchCode: Int
    public let frameCount: Int
}

/// Byte deltas restricted to frames that share public XLL segmentation. This
/// prevents a segmentation-layout change from being attributed to private
/// prediction or entropy coding.
public struct DTSXPrivateEntropyComparableMetrics: Sendable, Equatable, Codable {
    public let decodedFrameCount: Int
    public let baselinePrivateByteCount: Int
    public let variantPrivateByteCount: Int
    public let variantMinusBaselineByteCount: Int
    public let variantLargerFrameCount: Int
    public let variantSmallerFrameCount: Int
    public let equalSizeFrameCount: Int
    public let branchPairFrequencies: [DTSXPrivateEntropyBranchPairFrequency]
}

public struct DTSXPrivateEntropyDifferentialReport: Sendable, Equatable, Codable {
    public let summary: DTSXPrivateEntropyDifferentialSummary
    public let frames: [DTSXPrivateEntropyFrameDifferential]
}

/// Produces a syntax-level XLL-X differential. Unlike the byte differential,
/// this report makes every recovered entropy declaration directly inspectable
/// for an aligned official/candidate frame pair.
public enum DTSXPrivateEntropyDifferential {
    public static func compare(
        baselineIndexURL: URL,
        baselinePayloadURL: URL,
        variantIndexURL: URL,
        variantPayloadURL: URL,
        outputURL: URL,
        maximumFrameCount: Int? = nil,
        frameOffset: Int = 0
    ) throws -> DTSXPrivateEntropyDifferentialReport {
        guard frameOffset >= 0 else {
            throw DTSError.invalidArgument("XLL-X entropy differential frame offset must not be negative")
        }
        if let maximumFrameCount, maximumFrameCount <= 0 {
            throw DTSError.invalidArgument("XLL-X entropy differential maximum frame count must be positive")
        }
        let baseline = try DTSXPrivateArtifactLoader.load(
            indexURL: baselineIndexURL,
            payloadURL: baselinePayloadURL
        )
        let variant = try DTSXPrivateArtifactLoader.load(
            indexURL: variantIndexURL,
            payloadURL: variantPayloadURL
        )
        let baselineRecords = selectedRecords(
            baseline.records,
            frameOffset: frameOffset,
            maximumFrameCount: maximumFrameCount
        )
        let variantRecords = selectedRecords(
            variant.records,
            frameOffset: frameOffset,
            maximumFrameCount: maximumFrameCount
        )
        guard baselineRecords.count == variantRecords.count else {
            throw DTSError.invalidArgument(
                "XLL-X entropy differential requires equal selected frame counts; found "
                    + "\(baselineRecords.count) and \(variantRecords.count)"
            )
        }

        var frameIndexMismatchCount = 0
        var publicSegmentationMismatchCount = 0
        var samePublicSegmentationFrameCount = 0
        var frames: [DTSXPrivateEntropyFrameDifferential] = []
        frames.reserveCapacity(baselineRecords.count)
        for index in baselineRecords.indices {
            let baselineRecord = baselineRecords[index]
            let variantRecord = variantRecords[index]
            if baselineRecord.frameIndex != variantRecord.frameIndex {
                frameIndexMismatchCount += 1
            }
            let publicSegmentationMatches = segmentation(of: baselineRecord)
                == segmentation(of: variantRecord)
            if !publicSegmentationMatches {
                publicSegmentationMismatchCount += 1
            } else {
                samePublicSegmentationFrameCount += 1
            }
            let baselineSyntax = inspect(
                record: baselineRecord,
                bytes: baseline.frameBytes(baselineRecord)
            )
            let variantSyntax = inspect(
                record: variantRecord,
                bytes: variant.frameBytes(variantRecord)
            )
            frames.append(DTSXPrivateEntropyFrameDifferential(
                frameIndex: baselineRecord.frameIndex,
                publicSegmentationMatches: publicSegmentationMatches,
                baseline: baselineSyntax,
                variant: variantSyntax
            ))
        }

        let report = DTSXPrivateEntropyDifferentialReport(
            summary: DTSXPrivateEntropyDifferentialSummary(
                baselineIndexPath: baselineIndexURL.standardizedFileURL.path,
                baselinePayloadPath: baselinePayloadURL.standardizedFileURL.path,
                variantIndexPath: variantIndexURL.standardizedFileURL.path,
                variantPayloadPath: variantPayloadURL.standardizedFileURL.path,
                requestedFrameOffset: frameOffset,
                requestedMaximumFrameCount: maximumFrameCount,
                comparedFrameCount: frames.count,
                frameIndexMismatchCount: frameIndexMismatchCount,
                publicSegmentationMismatchCount: publicSegmentationMismatchCount,
                samePublicSegmentationFrameCount: samePublicSegmentationFrameCount,
                comparableSameSegmentation: comparableMetrics(frames),
                baseline: metrics(frames.map(\.baseline)),
                variant: metrics(frames.map(\.variant))
            ),
            frames: frames
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(report).write(to: outputURL.standardizedFileURL, options: .atomic)
        } catch {
            throw DTSError.io("cannot write XLL-X entropy differential: \(error.localizedDescription)")
        }
        return report
    }

    private static func selectedRecords(
        _ records: [DTSXPrivateFrameRecord],
        frameOffset: Int,
        maximumFrameCount: Int?
    ) -> [DTSXPrivateFrameRecord] {
        let offset = Array(records.dropFirst(frameOffset))
        return maximumFrameCount.map { Array(offset.prefix($0)) } ?? offset
    }

    private static func segmentation(
        of record: DTSXPrivateFrameRecord
    ) -> (segmentCount: Int, segmentSampleCount: Int) {
        (
            record.xllSyntax?.segmentCount ?? 2,
            record.xllSyntax?.segmentSampleCount ?? 256
        )
    }

    private static func inspect(
        record: DTSXPrivateFrameRecord,
        bytes: Data.SubSequence
    ) -> DTSXPrivateEntropyFrameSyntax {
        let layout = segmentation(of: record)
        do {
            let ast = try DTSXPrivateFrameAST.parse(bytes)
            let decoded = try DTSXPrivateFrameDecoder.decode(
                ast,
                segmentCount: layout.segmentCount,
                segmentSampleCount: layout.segmentSampleCount,
                collectEntropyDiagnostics: true
            )
            return DTSXPrivateEntropyFrameSyntax(
                frameIndex: record.frameIndex,
                privateFrameByteCount: bytes.count,
                segmentCount: layout.segmentCount,
                segmentSampleCount: layout.segmentSampleCount,
                primarySixBitCode: Int(ast.primarySixBitCode),
                secondaryBranchCode: ast.candidateSecondaryBranchCode,
                decoded: true,
                usesCompactZeroEntropySyntax: decoded.usesCompactZeroEntropySyntax,
                noNavigationZeroSideInfo: decoded.noNavigationZeroSideInfo != nil,
                error: nil,
                entropySegments: decoded.entropySegments
            )
        } catch {
            return DTSXPrivateEntropyFrameSyntax(
                frameIndex: record.frameIndex,
                privateFrameByteCount: bytes.count,
                segmentCount: layout.segmentCount,
                segmentSampleCount: layout.segmentSampleCount,
                primarySixBitCode: nil,
                secondaryBranchCode: nil,
                decoded: false,
                usesCompactZeroEntropySyntax: false,
                noNavigationZeroSideInfo: false,
                error: String(describing: error),
                entropySegments: []
            )
        }
    }

    private static func metrics(
        _ frames: [DTSXPrivateEntropyFrameSyntax]
    ) -> DTSXPrivateEntropySyntaxMetrics {
        var decodedFrameCount = 0
        var compactZeroFrameCount = 0
        var noNavigationFrameCount = 0
        var privateByteCount = 0
        var entropySegmentCount = 0
        var stateReuseSegmentCount = 0
        var commonParameterSegmentCount = 0
        var riceParameterCount = 0
        var hybridRiceParameterCount = 0
        for frame in frames {
            privateByteCount += frame.privateFrameByteCount
            if frame.decoded { decodedFrameCount += 1 }
            if frame.usesCompactZeroEntropySyntax { compactZeroFrameCount += 1 }
            if frame.noNavigationZeroSideInfo { noNavigationFrameCount += 1 }
            for segment in frame.entropySegments {
                entropySegmentCount += 1
                // Compact-zero continuation bytes have no ordinary
                // bUseSegStateCodeParm field, even though the specialized
                // decoder represents their inherited zero parameters this way.
                if !frame.usesCompactZeroEntropySyntax,
                   segment.reusesPreviousParameters {
                    stateReuseSegmentCount += 1
                }
                if segment.commonParameters { commonParameterSegmentCount += 1 }
                riceParameterCount += segment.riceCoding.filter { $0 }.count
                hybridRiceParameterCount += segment.hybridLinearWidths.filter { $0 > 0 }.count
            }
        }
        return DTSXPrivateEntropySyntaxMetrics(
            frameCount: frames.count,
            decodedFrameCount: decodedFrameCount,
            compactZeroFrameCount: compactZeroFrameCount,
            noNavigationFrameCount: noNavigationFrameCount,
            privateByteCount: privateByteCount,
            entropySegmentCount: entropySegmentCount,
            stateReuseSegmentCount: stateReuseSegmentCount,
            commonParameterSegmentCount: commonParameterSegmentCount,
            riceParameterCount: riceParameterCount,
            hybridRiceParameterCount: hybridRiceParameterCount
        )
    }

    private static func comparableMetrics(
        _ frames: [DTSXPrivateEntropyFrameDifferential]
    ) -> DTSXPrivateEntropyComparableMetrics {
        var baselinePrivateByteCount = 0
        var variantPrivateByteCount = 0
        var variantLargerFrameCount = 0
        var variantSmallerFrameCount = 0
        var equalSizeFrameCount = 0
        var branchPairCounts: [BranchPair: Int] = [:]

        let comparable = frames.filter {
            $0.publicSegmentationMatches && $0.baseline.decoded && $0.variant.decoded
        }
        for frame in comparable {
            baselinePrivateByteCount += frame.baseline.privateFrameByteCount
            variantPrivateByteCount += frame.variant.privateFrameByteCount
            if frame.variant.privateFrameByteCount > frame.baseline.privateFrameByteCount {
                variantLargerFrameCount += 1
            } else if frame.variant.privateFrameByteCount < frame.baseline.privateFrameByteCount {
                variantSmallerFrameCount += 1
            } else {
                equalSizeFrameCount += 1
            }
            if let baselineBranchCode = frame.baseline.secondaryBranchCode,
               let variantBranchCode = frame.variant.secondaryBranchCode {
                branchPairCounts[
                    BranchPair(baseline: baselineBranchCode, variant: variantBranchCode),
                    default: 0
                ] += 1
            }
        }

        let branchPairFrequencies = branchPairCounts.map { pair, count in
            DTSXPrivateEntropyBranchPairFrequency(
                baselineBranchCode: pair.baseline,
                variantBranchCode: pair.variant,
                frameCount: count
            )
        }.sorted {
            ($0.baselineBranchCode, $0.variantBranchCode)
                < ($1.baselineBranchCode, $1.variantBranchCode)
        }
        return DTSXPrivateEntropyComparableMetrics(
            decodedFrameCount: comparable.count,
            baselinePrivateByteCount: baselinePrivateByteCount,
            variantPrivateByteCount: variantPrivateByteCount,
            variantMinusBaselineByteCount: variantPrivateByteCount - baselinePrivateByteCount,
            variantLargerFrameCount: variantLargerFrameCount,
            variantSmallerFrameCount: variantSmallerFrameCount,
            equalSizeFrameCount: equalSizeFrameCount,
            branchPairFrequencies: branchPairFrequencies
        )
    }

    private struct BranchPair: Hashable {
        let baseline: Int
        let variant: Int
    }
}
