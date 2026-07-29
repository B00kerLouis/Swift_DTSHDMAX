import Foundation

public struct DTSXPrivateControlledRoutingVerificationReport: Sendable, Equatable, Codable {
    public let baselineIndexPath: String
    public let baselinePayloadPath: String
    public let variantIndexPath: String
    public let variantPayloadPath: String
    public let oldToNewHeightMap: [Int]
    public let baselinePayloadSHA256: String
    public let variantPayloadSHA256: String
    public let rebuiltPayloadSHA256: String?
    public let frameCount: Int
    public let identicalFrameCount: Int
    public let routingChangedFrameCount: Int
    public let expectedRoutingMatchFrameCount: Int
    public let branchPreservedFrameCount: Int
    public let predictionCRCValidFrameCount: Int
    public let byteExactRebuiltFrameCount: Int
    public let firstMismatchFrameIndex: Int?
    public let firstMismatchDetail: String?
    public let rebuiltPayloadIsByteIdenticalToVariant: Bool
    public let isVerified: Bool
}

/// Verifies the encoder-side inverse of a controlled speaker-routing change.
/// The baseline coded planes are retained, their height indices are remapped,
/// and the protected prediction CRC is regenerated. A successful result means
/// the rebuilt private payload equals the independently encoded variant byte
/// for byte; it does not copy the variant prediction or entropy bytes.
public enum DTSXPrivateControlledRoutingVerifier {
    public static func verify(
        baselineIndexURL: URL,
        baselinePayloadURL: URL,
        variantIndexURL: URL,
        variantPayloadURL: URL,
        oldToNewHeightMap: [Int],
        outputURL: URL
    ) throws -> DTSXPrivateControlledRoutingVerificationReport {
        _ = try DTSXPrivateRouting(
            codedPlaneToHeightPermutation: oldToNewHeightMap,
            branchCode: 0
        )
        let baseline = try DTSXPrivateArtifactLoader.load(
            indexURL: baselineIndexURL,
            payloadURL: baselinePayloadURL
        )
        let variant = try DTSXPrivateArtifactLoader.load(
            indexURL: variantIndexURL,
            payloadURL: variantPayloadURL
        )
        guard baseline.records.count == variant.records.count else {
            throw DTSError.invalidArgument(
                "XLL-X controlled routing verification requires equal private-frame counts"
            )
        }

        var identicalFrameCount = 0
        var routingChangedFrameCount = 0
        var expectedRoutingMatchFrameCount = 0
        var branchPreservedFrameCount = 0
        var predictionCRCValidFrameCount = 0
        var byteExactRebuiltFrameCount = 0
        var firstMismatchFrameIndex: Int?
        var firstMismatchDetail: String?
        var rebuiltPayload = Data()
        rebuiltPayload.reserveCapacity(variant.payload.count)
        var rebuiltPayloadIsComplete = true

        func recordMismatch(frameIndex: Int, detail: String) {
            guard firstMismatchFrameIndex == nil else { return }
            firstMismatchFrameIndex = frameIndex
            firstMismatchDetail = detail
        }

        for position in baseline.records.indices {
            let baselineRecord = baseline.records[position]
            let variantRecord = variant.records[position]
            guard baselineRecord.frameIndex == variantRecord.frameIndex else {
                throw DTSError.malformed(
                    "XLL-X controlled routing frame indices are not aligned"
                )
            }
            let baselineBytes = Data(baseline.frameBytes(baselineRecord))
            let variantBytes = Data(variant.frameBytes(variantRecord))
            if baselineBytes == variantBytes {
                identicalFrameCount += 1
                rebuiltPayload.append(baselineBytes)
                continue
            }

            routingChangedFrameCount += 1
            do {
                let baselineAST = try DTSXPrivateFrameAST.parse(baselineBytes[...])
                let variantAST = try DTSXPrivateFrameAST.parse(variantBytes[...])
                let baselineRouting = try baselineAST.routing
                let variantRouting = try variantAST.routing
                let expectedRouting = try baselineRouting.remappingHeights(
                    oldToNew: oldToNewHeightMap
                )
                if baselineRouting.branchCode == variantRouting.branchCode {
                    branchPreservedFrameCount += 1
                }
                if expectedRouting == variantRouting {
                    expectedRoutingMatchFrameCount += 1
                } else {
                    recordMismatch(
                        frameIndex: baselineRecord.frameIndex,
                        detail: "variant routing differs from the requested height remap"
                    )
                }

                let rebuilt = try baselineAST.serializeReplacingRoutingAndRebuildingCRC(
                    expectedRouting
                )
                let rebuiltAST = try DTSXPrivateFrameAST.parse(rebuilt[...])
                if try rebuiltAST.parsePredictionCRC().isValid {
                    predictionCRCValidFrameCount += 1
                }
                if rebuilt == variantBytes {
                    byteExactRebuiltFrameCount += 1
                } else {
                    recordMismatch(
                        frameIndex: baselineRecord.frameIndex,
                        detail: "routing rewrite and CRC regeneration are not byte-exact"
                    )
                }
                rebuiltPayload.append(rebuilt)
            } catch {
                rebuiltPayloadIsComplete = false
                recordMismatch(
                    frameIndex: baselineRecord.frameIndex,
                    detail: String(describing: error)
                )
            }
        }

        let rebuiltSHA = rebuiltPayloadIsComplete
            ? SHA256Hasher.hash(rebuiltPayload)
            : nil
        let variantSHA = SHA256Hasher.hash(variant.payload)
        let rebuiltPayloadIsByteIdenticalToVariant = rebuiltPayloadIsComplete
            && rebuiltPayload == variant.payload
        let isVerified = !baseline.records.isEmpty
            && routingChangedFrameCount > 0
            && expectedRoutingMatchFrameCount == routingChangedFrameCount
            && branchPreservedFrameCount == routingChangedFrameCount
            && predictionCRCValidFrameCount == routingChangedFrameCount
            && byteExactRebuiltFrameCount == routingChangedFrameCount
            && rebuiltPayloadIsByteIdenticalToVariant
            && rebuiltSHA == variantSHA
            && firstMismatchFrameIndex == nil
        let report = DTSXPrivateControlledRoutingVerificationReport(
            baselineIndexPath: baselineIndexURL.standardizedFileURL.path,
            baselinePayloadPath: baselinePayloadURL.standardizedFileURL.path,
            variantIndexPath: variantIndexURL.standardizedFileURL.path,
            variantPayloadPath: variantPayloadURL.standardizedFileURL.path,
            oldToNewHeightMap: oldToNewHeightMap,
            baselinePayloadSHA256: SHA256Hasher.hash(baseline.payload),
            variantPayloadSHA256: variantSHA,
            rebuiltPayloadSHA256: rebuiltSHA,
            frameCount: baseline.records.count,
            identicalFrameCount: identicalFrameCount,
            routingChangedFrameCount: routingChangedFrameCount,
            expectedRoutingMatchFrameCount: expectedRoutingMatchFrameCount,
            branchPreservedFrameCount: branchPreservedFrameCount,
            predictionCRCValidFrameCount: predictionCRCValidFrameCount,
            byteExactRebuiltFrameCount: byteExactRebuiltFrameCount,
            firstMismatchFrameIndex: firstMismatchFrameIndex,
            firstMismatchDetail: firstMismatchDetail,
            rebuiltPayloadIsByteIdenticalToVariant: rebuiltPayloadIsByteIdenticalToVariant,
            isVerified: isVerified
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            throw DTSError.io(
                "cannot write XLL-X controlled routing report: \(error.localizedDescription)"
            )
        }
        return report
    }
}
