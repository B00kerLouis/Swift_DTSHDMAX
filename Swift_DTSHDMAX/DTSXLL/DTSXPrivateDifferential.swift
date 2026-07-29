import Foundation

public struct DTSXPrivateHeaderObservation: Sendable, Equatable, Codable {
    public let syncWord: UInt32
    public let crc16PrefixRemainder: UInt16
    public let packetType: UInt8
    public let reservedHighFourBits: UInt8
    public let primarySixBitCode: UInt8
    public let separatorSixBits: UInt8
    public let secondarySyncWord: UInt16
    public let secondaryPrefixSixBits: UInt8
    public let secondaryTenBitCode: UInt16
    public let terminalUInt16: UInt16
}

public struct DTSXPrivateFrameDifference: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let baselineByteCount: Int
    public let variantByteCount: Int
    public let baselineSHA256: String
    public let variantSHA256: String
    public let differingBitCount: Int
    public let firstDifferingBitOffset: Int?
    public let lastDifferingBitOffset: Int?
    public let baselineHeader: DTSXPrivateHeaderObservation
    public let variantHeader: DTSXPrivateHeaderObservation
}

public struct DTSXPrivateDifferentialSummary: Sendable, Equatable, Codable {
    public let baselineIndexPath: String
    public let baselinePayloadPath: String
    public let variantIndexPath: String
    public let variantPayloadPath: String
    public let comparedFrameCount: Int
    public let identicalFrameCount: Int
    public let lengthChangedFrameCount: Int
    public let primaryCodeChangedFrameCount: Int
    public let secondaryCodeChangedFrameCount: Int
    public let secondaryPermutationChangedFrameCount: Int
    public let secondaryBranchChangedFrameCount: Int
    /// Frames whose only changed bytes are the secondary routing word and the
    /// CRC that protects it plus the unchanged prediction payload.
    public let routingFieldAndPredictionCRCOnlyChangedFrameCount: Int
    public let predictionPayloadChangedFrameCount: Int
    public let postPredictionCRCSuffixChangedFrameCount: Int
    public let totalDifferingBitCount: Int64
}

public struct DTSXPrivateDifferentialReport: Sendable, Equatable, Codable {
    public let summary: DTSXPrivateDifferentialSummary
    public let frames: [DTSXPrivateFrameDifference]
}

public enum DTSXPrivateDifferential {
    private static let xllXSyncWord: UInt32 = 0x0200_0850

    public static func compare(
        baselineIndexURL: URL,
        baselinePayloadURL: URL,
        variantIndexURL: URL,
        variantPayloadURL: URL,
        outputURL: URL
    ) throws -> DTSXPrivateDifferentialReport {
        let baseline = try load(indexURL: baselineIndexURL, payloadURL: baselinePayloadURL)
        let variant = try load(indexURL: variantIndexURL, payloadURL: variantPayloadURL)
        guard baseline.records.count == variant.records.count else {
            throw DTSError.invalidArgument(
                "XLL-X differential requires equal private-frame counts; found "
                + "\(baseline.records.count) and \(variant.records.count)"
            )
        }

        var differences: [DTSXPrivateFrameDifference] = []
        differences.reserveCapacity(baseline.records.count)
        var identicalFrameCount = 0
        var lengthChangedFrameCount = 0
        var primaryCodeChangedFrameCount = 0
        var secondaryCodeChangedFrameCount = 0
        var secondaryPermutationChangedFrameCount = 0
        var secondaryBranchChangedFrameCount = 0
        var routingFieldAndPredictionCRCOnlyChangedFrameCount = 0
        var predictionPayloadChangedFrameCount = 0
        var postPredictionCRCSuffixChangedFrameCount = 0
        var totalDifferingBitCount: Int64 = 0

        for index in baseline.records.indices {
            let baselineRecord = baseline.records[index]
            let variantRecord = variant.records[index]
            guard baselineRecord.frameIndex == variantRecord.frameIndex else {
                throw DTSError.malformed("XLL-X differential frame indices are not aligned")
            }
            let baselineBytes = frameBytes(baselineRecord, payload: baseline.payload)
            let variantBytes = frameBytes(variantRecord, payload: variant.payload)
            let baselineHeader = try observeHeader(baselineBytes)
            let variantHeader = try observeHeader(variantBytes)
            let bitDifference = compareBits(baselineBytes, variantBytes)
            totalDifferingBitCount += Int64(bitDifference.count)
            if bitDifference.count == 0 { identicalFrameCount += 1 }
            if baselineBytes.count != variantBytes.count { lengthChangedFrameCount += 1 }
            if baselineHeader.primarySixBitCode != variantHeader.primarySixBitCode {
                primaryCodeChangedFrameCount += 1
            }
            if baselineHeader.secondaryTenBitCode != variantHeader.secondaryTenBitCode {
                secondaryCodeChangedFrameCount += 1
            }
            let baselineAST = try DTSXPrivateFrameAST.parse(baselineBytes)
            let variantAST = try DTSXPrivateFrameAST.parse(variantBytes)
            if baselineAST.candidateCodedPlaneToHeightPermutation
                != variantAST.candidateCodedPlaneToHeightPermutation {
                secondaryPermutationChangedFrameCount += 1
            }
            if baselineAST.candidateSecondaryBranchCode
                != variantAST.candidateSecondaryBranchCode {
                secondaryBranchChangedFrameCount += 1
            }
            if baselineBytes.count == variantBytes.count,
               baselineAST.primarySixBitCode == variantAST.primarySixBitCode {
                let crcOffset = Int(baselineAST.primarySixBitCode) - 7
                let predictionEqual = crcOffset >= 0
                    && Data(baselineAST.body.prefix(crcOffset))
                    == Data(variantAST.body.prefix(crcOffset))
                let suffixEqual = crcOffset + 2 <= baselineAST.body.count
                    && crcOffset + 2 <= variantAST.body.count
                    && Data(baselineAST.body.dropFirst(crcOffset + 2))
                    == Data(variantAST.body.dropFirst(crcOffset + 2))
                if !predictionEqual { predictionPayloadChangedFrameCount += 1 }
                if !suffixEqual { postPredictionCRCSuffixChangedFrameCount += 1 }
                if bitDifference.count > 0,
                   Data(baselineBytes.prefix(26)) == Data(variantBytes.prefix(26)),
                   predictionEqual,
                   suffixEqual {
                    routingFieldAndPredictionCRCOnlyChangedFrameCount += 1
                }
            }
            differences.append(DTSXPrivateFrameDifference(
                frameIndex: baselineRecord.frameIndex,
                baselineByteCount: baselineBytes.count,
                variantByteCount: variantBytes.count,
                baselineSHA256: SHA256Hasher.hash(Data(baselineBytes)),
                variantSHA256: SHA256Hasher.hash(Data(variantBytes)),
                differingBitCount: bitDifference.count,
                firstDifferingBitOffset: bitDifference.first,
                lastDifferingBitOffset: bitDifference.last,
                baselineHeader: baselineHeader,
                variantHeader: variantHeader
            ))
        }

        let report = DTSXPrivateDifferentialReport(
            summary: DTSXPrivateDifferentialSummary(
                baselineIndexPath: baselineIndexURL.standardizedFileURL.path,
                baselinePayloadPath: baselinePayloadURL.standardizedFileURL.path,
                variantIndexPath: variantIndexURL.standardizedFileURL.path,
                variantPayloadPath: variantPayloadURL.standardizedFileURL.path,
                comparedFrameCount: differences.count,
                identicalFrameCount: identicalFrameCount,
                lengthChangedFrameCount: lengthChangedFrameCount,
                primaryCodeChangedFrameCount: primaryCodeChangedFrameCount,
                secondaryCodeChangedFrameCount: secondaryCodeChangedFrameCount,
                secondaryPermutationChangedFrameCount: secondaryPermutationChangedFrameCount,
                secondaryBranchChangedFrameCount: secondaryBranchChangedFrameCount,
                routingFieldAndPredictionCRCOnlyChangedFrameCount:
                    routingFieldAndPredictionCRCOnlyChangedFrameCount,
                predictionPayloadChangedFrameCount: predictionPayloadChangedFrameCount,
                postPredictionCRCSuffixChangedFrameCount: postPredictionCRCSuffixChangedFrameCount,
                totalDifferingBitCount: totalDifferingBitCount
            ),
            frames: differences
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try encoder.encode(report).write(to: outputURL, options: .atomic) }
        catch { throw DTSError.io("cannot write XLL-X differential: \(error.localizedDescription)") }
        return report
    }

    public static func observeHeader(
        _ bytes: Data.SubSequence
    ) throws -> DTSXPrivateHeaderObservation {
        guard bytes.count >= 28 else {
            throw DTSError.truncated(field: "XLL-X private header", bitOffset: bytes.count * 8)
        }
        let start = bytes.startIndex
        let sync = uint32(bytes, at: start)
        guard sync == xllXSyncWord else {
            throw DTSError.malformed("XLL-X private marker is missing")
        }
        let firstWord = (UInt16(bytes[start + 22]) << 8) | UInt16(bytes[start + 23])
        let secondWord = (UInt16(bytes[start + 26]) << 8) | UInt16(bytes[start + 27])
        return DTSXPrivateHeaderObservation(
            syncWord: sync,
            crc16PrefixRemainder: DTSCRC16.checksum(bytes.prefix(21)),
            packetType: bytes[start + 21],
            reservedHighFourBits: UInt8((firstWord >> 12) & 0x0f),
            primarySixBitCode: UInt8((firstWord >> 6) & 0x3f),
            separatorSixBits: UInt8(firstWord & 0x3f),
            secondarySyncWord: (UInt16(bytes[start + 24]) << 8) | UInt16(bytes[start + 25]),
            secondaryPrefixSixBits: UInt8((secondWord >> 10) & 0x3f),
            secondaryTenBitCode: secondWord & 0x03ff,
            terminalUInt16: (UInt16(bytes[bytes.endIndex - 2]) << 8) | UInt16(bytes[bytes.endIndex - 1])
        )
    }

    private static func compareBits(
        _ baseline: Data.SubSequence,
        _ variant: Data.SubSequence
    ) -> (count: Int, first: Int?, last: Int?) {
        let commonByteCount = min(baseline.count, variant.count)
        var count = 0
        var first: Int?
        var last: Int?
        for byteOffset in 0..<commonByteCount {
            let xor = baseline[baseline.startIndex + byteOffset]
                ^ variant[variant.startIndex + byteOffset]
            guard xor != 0 else { continue }
            count += xor.nonzeroBitCount
            for bitInByte in 0..<8 where (xor & (0x80 >> UInt8(bitInByte))) != 0 {
                let bitOffset = byteOffset * 8 + bitInByte
                if first == nil { first = bitOffset }
                last = bitOffset
            }
        }
        let extraBitCount = abs(baseline.count - variant.count) * 8
        if extraBitCount > 0 {
            if first == nil { first = commonByteCount * 8 }
            last = max(baseline.count, variant.count) * 8 - 1
            count += extraBitCount
        }
        return (count, first, last)
    }

    private static func load(
        indexURL: URL,
        payloadURL: URL
    ) throws -> (records: [DTSXPrivateFrameRecord], payload: Data) {
        let extraction: DTSXExtractionReport
        let payload: Data
        do {
            extraction = try JSONDecoder().decode(
                DTSXExtractionReport.self,
                from: Data(contentsOf: indexURL, options: .mappedIfSafe)
            )
            payload = try Data(contentsOf: payloadURL, options: .mappedIfSafe)
        } catch {
            throw DTSError.io("cannot read XLL-X differential input: \(error.localizedDescription)")
        }
        let records = extraction.frames.filter { $0.payloadFileOffset != nil && $0.payloadByteCount > 0 }
        guard !records.isEmpty else { throw DTSError.malformed("XLL-X differential input has no private frames") }
        for record in records {
            let offset = record.payloadFileOffset!
            guard offset >= 0, record.payloadByteCount >= 28,
                  offset + record.payloadByteCount <= payload.count else {
                throw DTSError.malformed("XLL-X differential index is outside its payload")
            }
            if let expectedHash = record.payloadSHA256 {
                let bytes = payload[offset..<(offset + record.payloadByteCount)]
                guard SHA256Hasher.hash(Data(bytes)) == expectedHash else {
                    throw DTSError.malformed(
                        "XLL-X private frame \(record.frameIndex) SHA-256 does not match its index"
                    )
                }
            }
        }
        return (records, payload)
    }

    private static func frameBytes(
        _ record: DTSXPrivateFrameRecord,
        payload: Data
    ) -> Data.SubSequence {
        let start = record.payloadFileOffset!
        return payload[start..<(start + record.payloadByteCount)]
    }

    private static func uint32(_ bytes: Data.SubSequence, at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}
