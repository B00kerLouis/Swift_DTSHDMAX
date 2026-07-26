import Foundation

public struct DTSXPrivateHeightMismatch: Sendable, Equatable, Codable {
    public let privateFrameIndex: Int
    public let sourceSampleIndex: Int
    public let heightChannel: DTS714Channel
    public let expectedSample: Int32
    public let decodedSample: Int32
}

public struct DTSXPrivateHeightVerificationReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let sourceSampleCount: Int
    public let encodedSourceSampleCount: Int
    public let primingFrameCount: Int
    public let expectedPrivateFrameCount: Int
    public let decodedPrivateFrameCount: Int
    public let headerCRCValidFrameCount: Int
    public let predictionCRCValidFrameCount: Int
    public let navigationCRCValidFrameCount: Int
    public let canonicalNoNavigationFrameCount: Int
    public let trailingBitsZeroFrameCount: Int
    public let comparedHeightSampleCount: Int
    public let differentHeightSampleCount: Int
    public let nonzeroPaddingSampleCount: Int
    public let firstMismatch: DTSXPrivateHeightMismatch?
    public let isBitExact: Bool
}

/// Explicit file-to-source verification for the native branch-zero XLL-X
/// profile. The decoded coded planes are first restored through each frame's
/// routing word, then compared in semantic Lfh/Rfh/Lrh/Rrh order.
public enum DTSXPrivateHeightVerifier {
    private static let heightChannels: [DTS714Channel] = [
        .leftFrontHeight,
        .rightFrontHeight,
        .leftRearHeight,
        .rightRearHeight
    ]

    public static func verify(
        inputURL: URL,
        source: DTS714PCMBuffer,
        maximumSourceFrameCount: Int? = nil
    ) throws -> DTSXPrivateHeightVerificationReport {
        let sourceSampleCount = try requestedSampleCount(
            source: source,
            maximumSourceFrameCount: maximumSourceFrameCount
        )
        let frameSampleCount = DTSXPrivateFrameEncoder.frameSampleCount
        let encodedSourceSampleCount = (
            (sourceSampleCount + frameSampleCount - 1) / frameSampleCount
        ) * frameSampleCount
        let sourceFrameCount = encodedSourceSampleCount / frameSampleCount
        let primingFrameCount = XLLSyntax.coreCompatiblePrimingSampleCount / frameSampleCount
        let expectedFrameCount = primingFrameCount + sourceFrameCount

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "swift-dtsx-private-height-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw DTSError.io(
                "cannot create XLL-X height verification directory: \(error.localizedDescription)"
            )
        }
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let payloadURL = temporaryDirectory.appendingPathComponent("payload.xllx")
        let indexURL = temporaryDirectory.appendingPathComponent("index.json")
        let extraction = try DTSXObjectExtractor.extract(
            inputURL: inputURL,
            payloadOutputURL: payloadURL,
            indexOutputURL: indexURL
        )
        let loaded = try DTSXPrivateArtifactLoader.load(
            indexURL: indexURL,
            payloadURL: payloadURL
        )

        var headerCRCValidFrameCount = 0
        var predictionCRCValidFrameCount = 0
        var navigationCRCValidFrameCount = 0
        var canonicalNoNavigationFrameCount = 0
        var trailingBitsZeroFrameCount = 0
        var comparedHeightSampleCount = 0
        var differentHeightSampleCount = 0
        var nonzeroPaddingSampleCount = 0
        var firstMismatch: DTSXPrivateHeightMismatch?

        for (position, record) in loaded.records.enumerated() {
            guard record.frameIndex == position else {
                throw DTSError.malformed(
                    "XLL-X private frame indices are not contiguous at \(position)"
                )
            }
            let ast = try DTSXPrivateFrameAST.parse(loaded.frameBytes(record))
            if ast.headerCRCIsValid { headerCRCValidFrameCount += 1 }
            if try ast.parsePredictionCRC().isValid { predictionCRCValidFrameCount += 1 }
            let navigation = try? ast.parseNavigation(
                segmentCount: record.xllSyntax?.segmentCount ?? 2
            )
            if let navigation {
                if navigation.crcIsValid { navigationCRCValidFrameCount += 1 }
            }

            let decoded: DTSXPrivateIsolatedDecodedFrame
            do {
                decoded = try DTSXPrivateFrameDecoder.decode(
                    ast,
                    segmentCount: record.xllSyntax?.segmentCount ?? 2,
                    segmentSampleCount: record.xllSyntax?.segmentSampleCount ?? 256
                )
            } catch {
                throw DTSError.malformed(
                    "XLL-X private frame \(position) decode failed: \(String(describing: error))"
                )
            }
            if decoded.trailingBitsAreAllZero { trailingBitsZeroFrameCount += 1 }
            if navigation == nil, decoded.trailingBitsAreAllZero {
                canonicalNoNavigationFrameCount += 1
            }
            let routing = try ast.routing
            let decodedHeights = try routing.heightPlanes(
                fromCodedPlanes: decoded.codedPlanes
            )

            for heightIndex in Self.heightChannels.indices {
                let sourcePlane = source[Self.heightChannels[heightIndex]]
                for frameSample in 0..<frameSampleCount {
                    let encodedSampleIndex = (position - primingFrameCount) * frameSampleCount
                        + frameSample
                    let expected: Int32
                    if encodedSampleIndex >= 0 && encodedSampleIndex < sourceSampleCount {
                        expected = sourcePlane[encodedSampleIndex]
                    } else {
                        expected = 0
                    }
                    let actual = decodedHeights[heightIndex][frameSample]
                    comparedHeightSampleCount += 1
                    if expected != actual {
                        differentHeightSampleCount += 1
                        if encodedSampleIndex >= sourceSampleCount, actual != 0 {
                            nonzeroPaddingSampleCount += 1
                        }
                        if firstMismatch == nil {
                            firstMismatch = DTSXPrivateHeightMismatch(
                                privateFrameIndex: position,
                                sourceSampleIndex: encodedSampleIndex,
                                heightChannel: Self.heightChannels[heightIndex],
                                expectedSample: expected,
                                decodedSample: actual
                            )
                        }
                    }
                }
            }
        }

        let decodedFrameCount = loaded.records.count
        let allFrameChecksPassed = decodedFrameCount == expectedFrameCount
            && extraction.summary.privateFrameCount == expectedFrameCount
            && extraction.summary.resynchronizationByteCount == 0
            && extraction.summary.trailingBufferedByteCount == 0
            && headerCRCValidFrameCount == decodedFrameCount
            && predictionCRCValidFrameCount == decodedFrameCount
            && navigationCRCValidFrameCount + canonicalNoNavigationFrameCount
                == decodedFrameCount
            && trailingBitsZeroFrameCount == decodedFrameCount
        return DTSXPrivateHeightVerificationReport(
            inputPath: inputURL.standardizedFileURL.path,
            sourceSampleCount: sourceSampleCount,
            encodedSourceSampleCount: encodedSourceSampleCount,
            primingFrameCount: primingFrameCount,
            expectedPrivateFrameCount: expectedFrameCount,
            decodedPrivateFrameCount: decodedFrameCount,
            headerCRCValidFrameCount: headerCRCValidFrameCount,
            predictionCRCValidFrameCount: predictionCRCValidFrameCount,
            navigationCRCValidFrameCount: navigationCRCValidFrameCount,
            canonicalNoNavigationFrameCount: canonicalNoNavigationFrameCount,
            trailingBitsZeroFrameCount: trailingBitsZeroFrameCount,
            comparedHeightSampleCount: comparedHeightSampleCount,
            differentHeightSampleCount: differentHeightSampleCount,
            nonzeroPaddingSampleCount: nonzeroPaddingSampleCount,
            firstMismatch: firstMismatch,
            isBitExact: allFrameChecksPassed
                && differentHeightSampleCount == 0
                && nonzeroPaddingSampleCount == 0
        )
    }

    private static func requestedSampleCount(
        source: DTS714PCMBuffer,
        maximumSourceFrameCount: Int?
    ) throws -> Int {
        guard let maximumSourceFrameCount else { return source.sampleCount }
        guard maximumSourceFrameCount > 0 else {
            throw DTSError.invalidArgument("maximum DTS:X source frame count must be positive")
        }
        let (maximumSampleCount, overflow) = maximumSourceFrameCount.multipliedReportingOverflow(
            by: DTSXPrivateFrameEncoder.frameSampleCount
        )
        guard !overflow else {
            throw DTSError.valueOutOfRange(
                field: "maximum DTS:X source frame count",
                value: String(maximumSourceFrameCount)
            )
        }
        return min(source.sampleCount, maximumSampleCount)
    }
}
