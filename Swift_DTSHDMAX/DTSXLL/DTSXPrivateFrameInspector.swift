import Foundation

public struct DTSXPrivatePlaneInspection: Sendable, Equatable, Codable {
    public let planeIndex: Int
    public let sampleCount: Int
    public let nonzeroSampleCount: Int
    public let minimumSample: Int32
    public let maximumSample: Int32
    public let sampleSHA256: String
    public let firstSamples: [Int32]
}

public struct DTSXPrivateEntropyCandidateInspection: Sendable, Equatable, Codable {
    public let entropyPrefixByteCount: Int
    public let decoded: Bool
    public let error: String?
    public let entropyStartBitOffset: Int?
    public let entropyEndBitOffset: Int?
    public let segmentDataEndBitOffsets: [Int]
    public let segmentBoundaryBitOffsets: [Int]
    public let trailingZeroBitCount: Int?
    public let trailingBitsAreAllZero: Bool?
    public let planes: [DTSXPrivatePlaneInspection]
}

public struct DTSXPrivateSideInfoNavigationCandidate: Sendable, Equatable, Codable {
    public let bitWidth: Int
    public let firstRawValue: Int
    public let secondRawValue: Int
    public let firstValuePlusOne: Int
    public let secondValuePlusOne: Int
    public let unusedDataBitCount: Int
}

public struct DTSXPrivateFrameInspectionReport: Sendable, Equatable, Codable {
    public let indexPath: String
    public let payloadPath: String
    public let frameIndex: Int
    public let frameByteCount: Int
    public let frameSHA256: String
    public let primarySixBitCode: Int
    public let routing: DTSXPrivateRouting
    public let predictionCRC: DTSXPrivatePredictionCRCObservation
    public let predictionHeader: DTSXPrivatePredictionHeaderCandidate
    public let navigation: DTSXPrivateNavigation?
    public let sideInfoHex: String
    public let sideInfoCRC16Remainder: UInt16
    public let sideInfoNavigationCandidates: [DTSXPrivateSideInfoNavigationCandidate]
    public let navigatedPredictionResidualPlanes: [DTSXPrivatePlaneInspection]?
    public let navigatedTemporalPredictionPlanes: [DTSXPrivatePlaneInspection]?
    public let navigatedEntropy: DTSXPrivateEntropyCandidateInspection?
    public let bodyPrefixHex: String
    public let entropyCandidates: [DTSXPrivateEntropyCandidateInspection]
}

public enum DTSXPrivateFrameInspector {
    public static func inspect(
        indexURL: URL,
        payloadURL: URL,
        frameIndex: Int,
        outputURL: URL
    ) throws -> DTSXPrivateFrameInspectionReport {
        let loaded = try DTSXPrivateArtifactLoader.load(
            indexURL: indexURL,
            payloadURL: payloadURL
        )
        guard let record = loaded.records.first(where: { $0.frameIndex == frameIndex }) else {
            throw DTSError.invalidArgument(
                "XLL-X private frame index \(frameIndex) is not present"
            )
        }
        let bytes = Data(loaded.frameBytes(record))
        let ast = try DTSXPrivateFrameAST.parse(bytes[...])
        let crc = try ast.parsePredictionCRC()
        let prediction = try ast.parsePredictionHeaderCandidate()
        let segmentCount = record.xllSyntax?.segmentCount ?? 2
        let segmentSampleCount = record.xllSyntax?.segmentSampleCount ?? 256
        let navigation = try? ast.parseNavigation(segmentCount: segmentCount)
        let navigatedDecoded = try? DTSXPrivateIsolatedFrameDecoder.decodeGeneric(
            ast,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount
        )
        let sideInfoStart = crc.bodyByteOffset + 2
        let sideInfoEnd = min(sideInfoStart + 5, ast.body.count)
        guard sideInfoStart <= sideInfoEnd else {
            throw DTSError.malformed("XLL-X private side-info boundary is invalid")
        }
        let sideInfo = Data(ast.body[sideInfoStart..<sideInfoEnd])
        let navigationCandidates = sideInfoNavigationCandidates(sideInfo)

        var entropyCandidates: [DTSXPrivateEntropyCandidateInspection] = []
        for prefix in 2...15 {
            do {
                let decoded = try DTSXPrivateIsolatedFrameDecoder.decodeGeneric(
                    ast,
                    entropyPrefixByteCount: prefix,
                    segmentCount: segmentCount,
                    segmentSampleCount: segmentSampleCount
                )
                entropyCandidates.append(DTSXPrivateEntropyCandidateInspection(
                    entropyPrefixByteCount: prefix,
                    decoded: true,
                    error: nil,
                    entropyStartBitOffset: decoded.entropyStartBitOffset,
                    entropyEndBitOffset: decoded.entropyEndBitOffset,
                    segmentDataEndBitOffsets: decoded.segmentDataEndBitOffsets,
                    segmentBoundaryBitOffsets: decoded.segmentBoundaryBitOffsets,
                    trailingZeroBitCount: decoded.trailingZeroBitCount,
                    trailingBitsAreAllZero: decoded.trailingBitsAreAllZero,
                    planes: decoded.codedPlanes.enumerated().map {
                        planeInspection(index: $0.offset, samples: $0.element)
                    }
                ))
            } catch {
                entropyCandidates.append(DTSXPrivateEntropyCandidateInspection(
                    entropyPrefixByteCount: prefix,
                    decoded: false,
                    error: String(describing: error),
                    entropyStartBitOffset: nil,
                    entropyEndBitOffset: nil,
                    segmentDataEndBitOffsets: [],
                    segmentBoundaryBitOffsets: [],
                    trailingZeroBitCount: nil,
                    trailingBitsAreAllZero: nil,
                    planes: []
                ))
            }
        }
        let report = DTSXPrivateFrameInspectionReport(
            indexPath: indexURL.standardizedFileURL.path,
            payloadPath: payloadURL.standardizedFileURL.path,
            frameIndex: frameIndex,
            frameByteCount: bytes.count,
            frameSHA256: SHA256Hasher.hash(bytes),
            primarySixBitCode: Int(ast.primarySixBitCode),
            routing: try ast.routing,
            predictionCRC: crc,
            predictionHeader: prediction,
            navigation: navigation,
            sideInfoHex: hex(sideInfo),
            sideInfoCRC16Remainder: DTSCRC16.checksum(sideInfo),
            sideInfoNavigationCandidates: navigationCandidates,
            navigatedPredictionResidualPlanes: navigatedDecoded.map {
                $0.predictionResidualPlanes.enumerated().map {
                    planeInspection(index: $0.offset, samples: $0.element)
                }
            },
            navigatedTemporalPredictionPlanes: navigatedDecoded.map {
                $0.temporalPredictionPlanes.enumerated().map {
                    planeInspection(index: $0.offset, samples: $0.element)
                }
            },
            navigatedEntropy: navigatedDecoded.map {
                entropyInspection(prefix: 7, decoded: $0)
            },
            bodyPrefixHex: hex(ast.body.prefix(min(32, ast.body.count))),
            entropyCandidates: entropyCandidates
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            throw DTSError.io("cannot write XLL-X private frame inspection: \(error.localizedDescription)")
        }
        return report
    }

    private static func planeInspection(
        index: Int,
        samples: [Int32]
    ) -> DTSXPrivatePlaneInspection {
        var data = Data()
        data.reserveCapacity(samples.count * 4)
        for sample in samples {
            let raw = UInt32(bitPattern: sample)
            data.append(UInt8(truncatingIfNeeded: raw >> 24))
            data.append(UInt8(truncatingIfNeeded: raw >> 16))
            data.append(UInt8(truncatingIfNeeded: raw >> 8))
            data.append(UInt8(truncatingIfNeeded: raw))
        }
        return DTSXPrivatePlaneInspection(
            planeIndex: index,
            sampleCount: samples.count,
            nonzeroSampleCount: samples.lazy.filter { $0 != 0 }.count,
            minimumSample: samples.min() ?? 0,
            maximumSample: samples.max() ?? 0,
            sampleSHA256: SHA256Hasher.hash(data),
            firstSamples: Array(samples.prefix(24))
        )
    }

    private static func entropyInspection(
        prefix: Int,
        decoded: DTSXPrivateIsolatedDecodedFrame
    ) -> DTSXPrivateEntropyCandidateInspection {
        DTSXPrivateEntropyCandidateInspection(
            entropyPrefixByteCount: prefix,
            decoded: true,
            error: nil,
            entropyStartBitOffset: decoded.entropyStartBitOffset,
            entropyEndBitOffset: decoded.entropyEndBitOffset,
            segmentDataEndBitOffsets: decoded.segmentDataEndBitOffsets,
            segmentBoundaryBitOffsets: decoded.segmentBoundaryBitOffsets,
            trailingZeroBitCount: decoded.trailingZeroBitCount,
            trailingBitsAreAllZero: decoded.trailingBitsAreAllZero,
            planes: decoded.codedPlanes.enumerated().map {
                planeInspection(index: $0.offset, samples: $0.element)
            }
        )
    }

    private static func sideInfoNavigationCandidates(
        _ sideInfo: Data
    ) -> [DTSXPrivateSideInfoNavigationCandidate] {
        guard sideInfo.count >= 5 else { return [] }
        let dataWord = (UInt32(sideInfo[0]) << 16)
            | (UInt32(sideInfo[1]) << 8)
            | UInt32(sideInfo[2])
        var result: [DTSXPrivateSideInfoNavigationCandidate] = []
        for width in 8...12 {
            let mask = UInt32((1 << width) - 1)
            let first = Int((dataWord >> UInt32(24 - width)) & mask)
            let secondShift = 24 - width * 2
            guard secondShift >= 0 else { continue }
            let second = Int((dataWord >> UInt32(secondShift)) & mask)
            result.append(DTSXPrivateSideInfoNavigationCandidate(
                bitWidth: width,
                firstRawValue: first,
                secondRawValue: second,
                firstValuePlusOne: first + 1,
                secondValuePlusOne: second + 1,
                unusedDataBitCount: 24 - width * 2
            ))
        }
        return result
    }

    private static func hex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
