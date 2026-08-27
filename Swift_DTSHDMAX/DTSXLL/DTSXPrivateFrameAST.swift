import Foundation

public struct DTSXPrivateFrameAST: Sendable, Equatable {
    public static let syncWord: UInt32 = 0x0200_0850
    /// Primary six-bit code of the ordinary navigated 2x256 delivery class
    /// (a ten-byte prediction header; the encoder derives the code as the
    /// prediction byte count plus seven). The no-NAVI silence classes carry
    /// codes 15/16, and only frames declaring this class may resolve an
    /// ambiguous NAVI word to the canonical mid-stream width.
    public static let ordinaryNavigatedDeliveryPrimarySixBitCode: UInt8 = 17

    public let fixedHeaderBytes: Data
    public let headerCRC16: UInt16
    public let packetType: UInt8
    public let reservedHighFourBits: UInt8
    public let primarySixBitCode: UInt8
    public let separatorSixBits: UInt8
    public let secondarySyncWord: UInt16
    public let secondaryPrefixSixBits: UInt8
    public let secondaryTenBitCode: UInt16
    public let body: Data

    public static func parse(_ bytes: Data.SubSequence) throws -> DTSXPrivateFrameAST {
        guard bytes.count >= 30 else {
            throw DTSError.truncated(field: "XLL-X private frame", bitOffset: bytes.count * 8)
        }
        let start = bytes.startIndex
        guard readUInt32(bytes, at: start) == syncWord else {
            throw DTSError.malformed("XLL-X private sync word is missing")
        }
        let firstWord = readUInt16(bytes, at: start + 22)
        let secondWord = readUInt16(bytes, at: start + 26)
        return DTSXPrivateFrameAST(
            fixedHeaderBytes: Data(bytes[(start + 4)..<(start + 19)]),
            headerCRC16: readUInt16(bytes, at: start + 19),
            packetType: bytes[start + 21],
            reservedHighFourBits: UInt8((firstWord >> 12) & 0x0f),
            primarySixBitCode: UInt8((firstWord >> 6) & 0x3f),
            separatorSixBits: UInt8(firstWord & 0x3f),
            secondarySyncWord: readUInt16(bytes, at: start + 24),
            secondaryPrefixSixBits: UInt8((secondWord >> 10) & 0x3f),
            secondaryTenBitCode: secondWord & 0x03ff,
            body: Data(bytes[(start + 28)..<bytes.endIndex])
        )
    }

    public func serialize() throws -> Data {
        guard fixedHeaderBytes.count == 15,
              reservedHighFourBits < 16,
              primarySixBitCode < 64,
              separatorSixBits < 64,
              secondaryPrefixSixBits < 64,
              secondaryTenBitCode < 1_024 else {
            throw DTSError.valueOutOfRange(field: "XLL-X private AST", value: "header field")
        }
        var data = Data()
        data.reserveCapacity(28 + body.count)
        appendUInt32(Self.syncWord, to: &data)
        data.append(fixedHeaderBytes)
        appendUInt16(headerCRC16, to: &data)
        data.append(packetType)
        let firstWord = (UInt16(reservedHighFourBits) << 12)
            | (UInt16(primarySixBitCode) << 6)
            | UInt16(separatorSixBits)
        appendUInt16(firstWord, to: &data)
        appendUInt16(secondarySyncWord, to: &data)
        let secondWord = (UInt16(secondaryPrefixSixBits) << 10) | secondaryTenBitCode
        appendUInt16(secondWord, to: &data)
        data.append(body)
        return data
    }

    public var headerCRCIsValid: Bool {
        guard let serialized = try? serialize(), serialized.count >= 21 else { return false }
        return DTSCRC16.checksum(serialized.prefix(21)) == 0
    }

    public var matchesObservedStandardProfile: Bool {
        packetType == 0x02
            && reservedHighFourBits == 0
            && separatorSixBits == 0x0f
            && secondarySyncWord == 0xef7c
            && secondaryPrefixSixBits == 0x01
            && body.suffix(2) == Data([0, 0])
    }

    /// The upper eight bits of the observed ten-bit secondary code are four
    /// packed two-bit indices. Across all Nature's Fury private frames they
    /// form a permutation of 0...3; on every sample-exact generalized decode
    /// they map coded planes to Lfh/Rfh/Lrh/Rrh source-plane indices.
    public var candidateCodedPlaneToHeightPermutation: [Int] {
        [
            Int((secondaryTenBitCode >> 8) & 0x03),
            Int((secondaryTenBitCode >> 6) & 0x03),
            Int((secondaryTenBitCode >> 4) & 0x03),
            Int((secondaryTenBitCode >> 2) & 0x03)
        ]
    }

    /// Low two bits following the packed plane permutation. Value zero marks
    /// every frame currently recovered sample-exactly; values 1...3 select a
    /// still-open branch such as decorrelation or alternate entropy syntax.
    public var candidateSecondaryBranchCode: Int {
        Int(secondaryTenBitCode & 0x03)
    }

    public var candidateSecondaryPermutationIsValid: Bool {
        Set(candidateCodedPlaneToHeightPermutation).count == 4
    }

    private static func readUInt16(_ bytes: Data.SubSequence, at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: Data.SubSequence, at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}

/// A typed candidate for the public-XLL-style prediction fields at the start
/// of the private body.  This parser is intentionally separate from the stable
/// 28-byte AST prefix: it is proven for the zero-height and isolated-height
/// Nature's Fury frames, while the multi-height prefix branches remain open.
public struct DTSXPrivatePredictionHeaderCandidate: Sendable, Equatable, Codable {
    public let decorrelation: DTSXPrivateDecorrelationCandidate
    public let adaptivePredictionOrders: [Int]
    /// `nil` means the corresponding adaptive order is nonzero and therefore
    /// no two-bit fixed-order field is present.
    public let fixedPredictionOrders: [Int?]
    public let reflectionCoefficientRawIndices: [[Int]]
    public let reflectionCoefficientSignedIndices: [[Int32]]
    public let syntaxBitCount: Int
    public let syntaxStartBitOffset: Int
    public let boundaryByteOffset: Int
    public let zeroPaddingBitCount: Int
    public let paddingIsAllZero: Bool
    public let containsReservedReflectionIndex: Bool
    public let crc: DTSXPrivatePredictionCRCObservation

    public var matchesObservedZeroOrSingleHeightProfile: Bool {
        adaptivePredictionOrders.count == 4
            && fixedPredictionOrders.count == 4
            && reflectionCoefficientRawIndices.count == 4
            && reflectionCoefficientSignedIndices.count == 4
            && fixedPredictionOrders.compactMap { $0 }.allSatisfy { $0 == 0 }
            && paddingIsAllZero
            && !containsReservedReflectionIndex
            && crc.isValid
    }

    /// Structural candidate gate for the generalized four-plane decoder.  The
    /// private stream keeps the same prediction-header grammar on multi-height
    /// frames, but fixed-prediction orders are no longer restricted to zero.
    /// This property deliberately does not infer activity or plane ordering;
    /// those semantics are carried by the following private prefix and are
    /// reported separately by the generic decoder QC.
    public var matchesObservedGenericProfile: Bool {
        adaptivePredictionOrders.count == 4
            && fixedPredictionOrders.count == 4
            && reflectionCoefficientRawIndices.count == 4
            && reflectionCoefficientSignedIndices.count == 4
            && fixedPredictionOrders.compactMap { $0 }.allSatisfy { (0...3).contains($0) }
            && reflectionCoefficientRawIndices.enumerated().allSatisfy {
                $0.element.count == adaptivePredictionOrders[$0.offset]
            }
            && reflectionCoefficientSignedIndices.enumerated().allSatisfy {
                $0.element.count == adaptivePredictionOrders[$0.offset]
            }
            && paddingIsAllZero
            && !containsReservedReflectionIndex
            && crc.isValid
    }
}

/// Branch-qualified pairwise-decorrelation fields that precede the public-XLL
/// prediction grammar. Branch zero has no such prefix. The reference uses both
/// one- and two-coefficient forms for branch two, selected below by the
/// CRC-bounded prediction grammar rather than by source PCM.
public struct DTSXPrivateDecorrelationCandidate: Sendable, Equatable, Codable {
    public let branchCode: Int
    public let rawCoefficientCodes: [Int]
    public let signedCoefficientCodes: [Int32]
    public let syntaxBitCount: Int

    public var isEnabled: Bool {
        signedCoefficientCodes.contains { $0 != 0 }
    }
}

/// CRC-protected private header block beginning at frame byte 22. The primary
/// six-bit code determines the prediction payload length, so the CRC field is
/// located at `body[primarySixBitCode - 7]` and closes a `primary + 1` byte
/// protected region.
public struct DTSXPrivatePredictionCRCObservation: Sendable, Equatable, Codable {
    public let bodyByteOffset: Int
    public let storedCRC16: UInt16
    public let protectedByteCount: Int
    public let isValid: Bool
}

public extension DTSXPrivateFrameAST {
    func parseDecorrelationCandidate() throws -> DTSXPrivateDecorrelationCandidate {
        let branchCode = candidateSecondaryBranchCode
        switch branchCode {
        case 0:
            return DTSXPrivateDecorrelationCandidate(
                branchCode: branchCode,
                rawCoefficientCodes: [],
                signedCoefficientCodes: [0, 0],
                syntaxBitCount: 0
            )
        case 1, 2, 3:
            var reader = try BitReader(data: body)
            var rawCodes: [Int] = []
            var signedCodes = Array(repeating: Int32(0), count: 2)
            let coefficientCount = branchCode == 1 ? 1 : 2
            rawCodes.reserveCapacity(coefficientCount)
            for pair in 0..<coefficientCount {
                let destinationPair = branchCode == 1 ? 1 : pair
                let raw = Int(try reader.read(
                    7,
                    field: "XLL-X pair decorrelation coefficient[\(pair)]"
                ))
                // Pair one applies ordinary ZigZag to the complete seven-bit
                // value. Pair zero applies ZigZag to the upper six bits plus
                // the branch-qualified extension bit. The raw low bit remains
                // an alias/form discriminator; it does not bypass the branch
                // extension for even raw values.
                let coefficientCode = raw >> 1
                let signedValue: Int
                // The second destination pair always uses ordinary seven-bit
                // ZigZag. Only pair zero is branch-qualified: branch two uses
                // a zero extension and branch three a one extension for every
                // raw-code form. Official branch-two frame 613 carries raw 7 for
                // pair one, which must decode to -4 (not the extended -34).
                if destinationPair == 1 {
                    signedValue = (raw & 1) == 0
                        ? coefficientCode : -coefficientCode - 1
                } else {
                    let extensionBit = (branchCode >> destinationPair) & 1
                    let extendedCode = (extensionBit << 6) | coefficientCode
                    let magnitude = extendedCode >> 1
                    signedValue = (extendedCode & 1) == 0
                        ? magnitude : -magnitude - 1
                }
                let signed = Int32(signedValue)
                rawCodes.append(raw)
                signedCodes[destinationPair] = signed
            }
            return DTSXPrivateDecorrelationCandidate(
                branchCode: branchCode,
                rawCoefficientCodes: rawCodes,
                signedCoefficientCodes: signedCodes,
                syntaxBitCount: reader.bitOffset
            )
        default:
            throw DTSError.unsupported(
                "XLL-X private decorrelation branch \(branchCode) is not recovered"
            )
        }
    }

    func parsePredictionCRC() throws -> DTSXPrivatePredictionCRCObservation {
        let bodyByteOffset = Int(primarySixBitCode) - 7
        guard bodyByteOffset >= 0, bodyByteOffset + 2 <= body.count else {
            throw DTSError.truncated(
                field: "XLL-X private prediction CRC",
                bitOffset: max(0, bodyByteOffset * 8)
            )
        }
        let storedCRC16 = (UInt16(body[bodyByteOffset]) << 8)
            | UInt16(body[bodyByteOffset + 1])
        let serialized = try serialize()
        let protectedStart = 22
        let protectedEnd = 28 + bodyByteOffset + 2
        return DTSXPrivatePredictionCRCObservation(
            bodyByteOffset: bodyByteOffset,
            storedCRC16: storedCRC16,
            protectedByteCount: protectedEnd - protectedStart,
            isValid: DTSCRC16.checksum(serialized[protectedStart..<protectedEnd]) == 0
        )
    }

    /// Regenerates the CRC at the primary-code-derived boundary without
    /// interpreting the protected prediction payload. This is required for
    /// routing-only edits, which are proven across controlled frames whose
    /// complete prediction grammar is not yet semantic.
    func serializeRebuildingPredictionCRC() throws -> Data {
        let observation = try parsePredictionCRC()
        var serialized = try serialize()
        let crcOffset = 28 + observation.bodyByteOffset
        guard crcOffset + 2 <= serialized.count else {
            throw DTSError.truncated(
                field: "XLL-X rebuilt prediction CRC",
                bitOffset: crcOffset * 8
            )
        }
        let crc = DTSCRC16.checksum(serialized[22..<crcOffset])
        serialized[crcOffset] = UInt8(truncatingIfNeeded: crc >> 8)
        serialized[crcOffset + 1] = UInt8(truncatingIfNeeded: crc)
        return serialized
    }

    /// Parses the candidate prediction header and derives the next-section
    /// boundary observed as `primarySixBitCode - 7` body bytes.  Successful
    /// parsing does not by itself establish the private multi-channel grammar;
    /// callers must apply an evidence-qualified profile before treating these
    /// fields as semantic audio syntax.
    func parsePredictionHeaderCandidate() throws -> DTSXPrivatePredictionHeaderCandidate {
        try parsePredictionHeaderCandidates()[0]
    }

    /// Returns every CRC-bounded prediction interpretation that satisfies the
    /// recovered generic grammar. Branch two has both one- and two-coefficient
    /// forms; some official frames make both headers locally plausible, so the
    /// entropy decoder must select between them by complete NAVI closure.
    func parsePredictionHeaderCandidates() throws -> [DTSXPrivatePredictionHeaderCandidate] {
        var primary: DTSXPrivatePredictionHeaderCandidate?
        var primaryError: Error?
        do {
            primary = try parsePredictionHeaderCandidate(
                decorrelation: parseDecorrelationCandidate()
            )
        } catch {
            primaryError = error
        }

        var candidates: [DTSXPrivatePredictionHeaderCandidate] = []
        if let primary, primary.matchesObservedGenericProfile {
            candidates.append(primary)
        }

        if candidateSecondaryBranchCode == 2 {
            if let fallback = try? parsePredictionHeaderCandidate(
                decorrelation: parseBranchTwoSinglePairDecorrelationCandidate()
            ), fallback.matchesObservedGenericProfile,
               !candidates.contains(fallback) {
                candidates.append(fallback)
            }
        }
        if candidateSecondaryBranchCode == 3 {
            for destinationPair in 0..<2 {
                if let fallback = try? parsePredictionHeaderCandidate(
                    decorrelation: parseBranchThreeSinglePairDecorrelationCandidate(
                        destinationPair: destinationPair
                    )
                ), fallback.matchesObservedGenericProfile,
                   !candidates.contains(fallback) {
                    candidates.append(fallback)
                }
            }
        }
        if !candidates.isEmpty { return candidates }
        if let primary { return [primary] }
        throw primaryError ?? DTSError.malformed(
            "XLL-X candidate prediction header has no recoverable branch form"
        )
    }

    private func parseBranchTwoSinglePairDecorrelationCandidate()
        throws -> DTSXPrivateDecorrelationCandidate {
        var reader = try BitReader(data: body)
        let raw = Int(try reader.read(
            7,
            field: "XLL-X branch-two single-pair decorrelation coefficient"
        ))
        let coefficientCode = raw >> 1
        let magnitude = coefficientCode >> 1
        let signedValue = (coefficientCode & 1) == 0 ? magnitude : -magnitude - 1
        return DTSXPrivateDecorrelationCandidate(
            branchCode: candidateSecondaryBranchCode,
            rawCoefficientCodes: [raw],
            signedCoefficientCodes: [Int32(signedValue), 0],
            syntaxBitCount: reader.bitOffset
        )
    }

    private func parseBranchThreeSinglePairDecorrelationCandidate(
        destinationPair: Int
    ) throws -> DTSXPrivateDecorrelationCandidate {
        guard (0..<2).contains(destinationPair) else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X branch-three single-pair destination",
                value: String(destinationPair)
            )
        }
        var reader = try BitReader(data: body)
        let raw = Int(try reader.read(
            7,
            field: "XLL-X branch-three single-pair decorrelation coefficient"
        ))
        let coefficientCode = raw >> 1
        let signedValue: Int
        if destinationPair == 1 {
            signedValue = (raw & 1) == 0
                ? coefficientCode : -coefficientCode - 1
        } else {
            let extendedCode = (1 << 6) | coefficientCode
            let magnitude = extendedCode >> 1
            signedValue = (extendedCode & 1) == 0
                ? magnitude : -magnitude - 1
        }
        var signedCodes = Array(repeating: Int32(0), count: 2)
        signedCodes[destinationPair] = Int32(signedValue)
        return DTSXPrivateDecorrelationCandidate(
            branchCode: candidateSecondaryBranchCode,
            rawCoefficientCodes: [raw],
            signedCoefficientCodes: signedCodes,
            syntaxBitCount: reader.bitOffset
        )
    }

    /// Structural-only probe used by the authorized differential analyzer to
    /// establish the branch-qualified prefix length before assigning semantic
    /// meaning to any skipped bits. It deliberately disables decorrelation so
    /// callers cannot mistake a successful header parse for decoded PCM.
    func parsePredictionHeaderCandidateForStructuralProbe(
        syntaxStartBitOffset: Int
    ) throws -> DTSXPrivatePredictionHeaderCandidate {
        guard syntaxStartBitOffset >= 0,
              syntaxStartBitOffset <= body.count * 8 else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X structural prediction syntax start",
                value: String(syntaxStartBitOffset)
            )
        }
        return try parsePredictionHeaderCandidate(
            decorrelation: DTSXPrivateDecorrelationCandidate(
                branchCode: candidateSecondaryBranchCode,
                rawCoefficientCodes: [],
                signedCoefficientCodes: [0, 0],
                syntaxBitCount: syntaxStartBitOffset
            )
        )
    }

    private func parsePredictionHeaderCandidate(
        decorrelation: DTSXPrivateDecorrelationCandidate
    ) throws -> DTSXPrivatePredictionHeaderCandidate {
        let boundaryByteOffset = Int(primarySixBitCode) - 7
        guard boundaryByteOffset >= 0, boundaryByteOffset + 2 <= body.count else {
            throw DTSError.malformed("XLL-X candidate prediction-header boundary is outside the body")
        }
        var reader = try BitReader(data: body)
        try reader.seek(
            to: decorrelation.syntaxBitCount,
            field: "XLL-X candidate prediction syntax start"
        )
        let syntaxStartBitOffset = reader.bitOffset
        var adaptiveOrders: [Int] = []
        adaptiveOrders.reserveCapacity(4)
        for channel in 0..<4 {
            adaptiveOrders.append(Int(try reader.read(
                4,
                field: "XLL-X candidate adaptive order[\(channel)]"
            )))
        }

        var fixedOrders = Array<Int?>(repeating: nil, count: 4)
        for channel in adaptiveOrders.indices where adaptiveOrders[channel] == 0 {
            fixedOrders[channel] = Int(try reader.read(
                2,
                field: "XLL-X candidate fixed order[\(channel)]"
            ))
        }

        var rawIndices = Array(repeating: [Int](), count: 4)
        var signedIndices = Array(repeating: [Int32](), count: 4)
        var containsReserved = false
        for channel in adaptiveOrders.indices {
            rawIndices[channel].reserveCapacity(adaptiveOrders[channel])
            signedIndices[channel].reserveCapacity(adaptiveOrders[channel])
            for coefficient in 0..<adaptiveOrders[channel] {
                let raw = Int(try reader.read(
                    8,
                    field: "XLL-X candidate reflection index[\(channel)][\(coefficient)]"
                ))
                let magnitude = raw >> 1
                let signed = Int32((raw & 1) == 0 ? magnitude : -magnitude - 1)
                rawIndices[channel].append(raw)
                signedIndices[channel].append(signed)
                if signed == -128 { containsReserved = true }
            }
        }

        let syntaxBitCount = reader.bitOffset - syntaxStartBitOffset
        let boundaryBitOffset = boundaryByteOffset * 8
        guard reader.bitOffset <= boundaryBitOffset else {
            throw DTSError.malformed("XLL-X candidate prediction fields exceed their observed boundary")
        }
        var paddingIsZero = true
        while reader.bitOffset < boundaryBitOffset {
            if try reader.read(1, field: "XLL-X candidate prediction padding") != 0 {
                paddingIsZero = false
            }
        }
        return DTSXPrivatePredictionHeaderCandidate(
            decorrelation: decorrelation,
            adaptivePredictionOrders: adaptiveOrders,
            fixedPredictionOrders: fixedOrders,
            reflectionCoefficientRawIndices: rawIndices,
            reflectionCoefficientSignedIndices: signedIndices,
            syntaxBitCount: syntaxBitCount,
            syntaxStartBitOffset: syntaxStartBitOffset,
            boundaryByteOffset: boundaryByteOffset,
            zeroPaddingBitCount: boundaryBitOffset - syntaxStartBitOffset - syntaxBitCount,
            paddingIsAllZero: paddingIsZero,
            containsReservedReflectionIndex: containsReserved,
            crc: try parsePredictionCRC()
        )
    }

    /// Re-encodes the recovered four-plane prediction syntax and regenerates
    /// its CRC while preserving the still-unresolved side-info and entropy
    /// suffix. This is the encoder-side inverse of
    /// `parsePredictionHeaderCandidate()`, not a copy of the source prefix.
    func serializeRebuildingPredictionHeaderAndCRC() throws -> Data {
        let prediction = try parsePredictionHeaderCandidate()
        guard prediction.matchesObservedGenericProfile else {
            throw DTSError.unsupported(
                "XLL-X prediction header is outside the byte-exact encoder profile"
            )
        }
        guard prediction.adaptivePredictionOrders.count == 4,
              prediction.fixedPredictionOrders.count == 4,
              prediction.reflectionCoefficientRawIndices.count == 4 else {
            throw DTSError.malformed("XLL-X prediction header does not contain four coded planes")
        }

        var writer = BitWriter()
        for pair in prediction.decorrelation.rawCoefficientCodes.indices {
            try writer.write(
                UInt64(prediction.decorrelation.rawCoefficientCodes[pair]),
                bitCount: 7,
                field: "XLL-X pair decorrelation coefficient[\(pair)]"
            )
        }
        guard writer.bitCount == prediction.syntaxStartBitOffset else {
            throw DTSError.malformed("XLL-X rebuilt decorrelation syntax length changed")
        }
        for channel in 0..<4 {
            try writer.write(
                UInt64(prediction.adaptivePredictionOrders[channel]),
                bitCount: 4,
                field: "XLL-X prediction adaptive order[\(channel)]"
            )
        }
        for channel in 0..<4 where prediction.adaptivePredictionOrders[channel] == 0 {
            guard let fixedOrder = prediction.fixedPredictionOrders[channel] else {
                throw DTSError.malformed(
                    "XLL-X prediction fixed order[\(channel)] is absent for adaptive order zero"
                )
            }
            try writer.write(
                UInt64(fixedOrder),
                bitCount: 2,
                field: "XLL-X prediction fixed order[\(channel)]"
            )
        }
        for channel in 0..<4 {
            let expectedCount = prediction.adaptivePredictionOrders[channel]
            let indices = prediction.reflectionCoefficientRawIndices[channel]
            guard indices.count == expectedCount else {
                throw DTSError.malformed(
                    "XLL-X prediction reflection-index count does not match adaptive order"
                )
            }
            for coefficient in indices.indices {
                try writer.write(
                    UInt64(indices[coefficient]),
                    bitCount: 8,
                    field: "XLL-X prediction reflection index[\(channel)][\(coefficient)]"
                )
            }
        }

        guard writer.bitCount == prediction.syntaxStartBitOffset + prediction.syntaxBitCount else {
            throw DTSError.malformed("XLL-X rebuilt prediction syntax length changed")
        }
        let boundaryBitCount = prediction.boundaryByteOffset * 8
        guard writer.bitCount <= boundaryBitCount else {
            throw DTSError.malformed("XLL-X rebuilt prediction syntax exceeds its CRC boundary")
        }
        var remainingPadding = boundaryBitCount - writer.bitCount
        while remainingPadding > 0 {
            let width = min(remainingPadding, 64)
            try writer.write(0, bitCount: width, field: "XLL-X prediction zero padding")
            remainingPadding -= width
        }
        let rebuiltPrediction = Data(writer.bytes)
        guard rebuiltPrediction.count == prediction.boundaryByteOffset else {
            throw DTSError.malformed("XLL-X rebuilt prediction header is not byte aligned")
        }

        var serialized = try serialize()
        let bodyStart = 28
        let crcOffset = bodyStart + prediction.boundaryByteOffset
        guard crcOffset + 2 <= serialized.count else {
            throw DTSError.truncated(field: "XLL-X rebuilt prediction CRC", bitOffset: crcOffset * 8)
        }
        serialized.replaceSubrange(bodyStart..<crcOffset, with: rebuiltPrediction)
        let rebuilt = try DTSXPrivateFrameAST.parse(serialized[...])
        return try rebuilt.serializeRebuildingPredictionCRC()
    }
}

public struct DTSXPrivateEntropySegmentSyntax: Sendable, Equatable, Codable {
    public let segmentIndex: Int
    public let reusesPreviousParameters: Bool
    public let commonParameters: Bool
    public let riceCoding: [Bool]
    public let hybridLinearWidths: [Int]
    /// Part-B offsets carried as linear samples by Hybrid Rice.  They are
    /// syntax, not a PCM-derived heuristic, and are retained so an offline
    /// inverse verifier can regenerate the segment without copying payload.
    public let hybridIsolatedSampleOffsets: [[Int]]
    public let partABitAllocations: [Int]
    public let partBBitAllocations: [Int]
    public let partASampleCounts: [Int]
    public let partASampleValues: [[Int32]]
    public let partBMeanAbsoluteMagnitudes: [Int]
    public let partBLinearWidths: [Int]
    public let partBRicePayloadBitCounts: [[Int]]
    public let headerStartBitOffset: Int
    public let sampleDataStartBitOffset: Int
    public let sampleDataEndBitOffset: Int
}

/// Parsed control declaration for the CRC-closed, no-NAVI all-zero form.
///
/// This is intentionally a field model rather than an opaque byte suffix: its
/// checksum is regenerated by the encoder and product encoding never obtains
/// it from a reference stream.  The current observed branch-zero profile has
/// three control values, each with a declared side-info byte count.
public struct DTSXPrivateNoNavigationZeroSideInfo: Sendable, Equatable, Codable {
    public let controlCode: UInt8
    public let dataByteCount: Int

    public init(controlCode: UInt8, dataByteCount: Int) throws {
        guard [0x10, 0x20, 0x80].contains(controlCode),
              (3...6).contains(dataByteCount) else {
            throw DTSError.malformed("XLL-X no-NAVI zero side-info is outside the recovered profile")
        }
        self.controlCode = controlCode
        self.dataByteCount = dataByteCount
    }

    func serializedData() -> Data {
        var data = Data([0x00, controlCode])
        data.append(contentsOf: repeatElement(0, count: dataByteCount - data.count))
        return data
    }

    static func parse(
        _ ast: DTSXPrivateFrameAST,
        prediction: DTSXPrivatePredictionHeaderCandidate,
        segmentCount: Int,
        segmentSampleCount: Int
    ) throws -> DTSXPrivateNoNavigationZeroSideInfo? {
        guard ast.headerCRCIsValid,
              ast.matchesObservedStandardProfile,
              ast.candidateSecondaryBranchCode == 0,
              prediction.matchesObservedGenericProfile,
              prediction.adaptivePredictionOrders == [0, 0, 0, 0],
              prediction.fixedPredictionOrders.allSatisfy({ $0 == 0 }),
              prediction.boundaryByteOffset == 9,
              prediction.crc.isValid else {
            return nil
        }
        let layout: (dataByteCount: Int, entropy: Data, trailingByteCount: Int)
        switch (segmentCount, segmentSampleCount) {
        case (2, 256):
            layout = (3, Data([0x80, 0x00, 0x40]), 5)
        case (4, 128):
            let sideInfoStart = prediction.boundaryByteOffset + 2
            guard sideInfoStart + 2 <= ast.body.count else { return nil }
            layout = ast.body[sideInfoStart + 1] == 0x80
                ? (5, Data([0x80, 0x00, 0x40, 0x40, 0x40]), 5)
                : (6, Data([0x80, 0x00, 0x40, 0x40, 0x40]), 4)
        default:
            return nil
        }
        let sideInfoStart = prediction.boundaryByteOffset + 2
        let sideInfoEnd = sideInfoStart + layout.dataByteCount
        let entropyStart = sideInfoEnd + 2
        guard entropyStart + layout.entropy.count + layout.trailingByteCount == ast.body.count,
              sideInfoEnd + 2 <= ast.body.count else {
            return nil
        }
        let sideInfo = Data(ast.body[sideInfoStart..<sideInfoEnd])
        guard sideInfo.count >= 2,
              sideInfo[0] == 0,
              sideInfo.dropFirst(2).allSatisfy({ $0 == 0 }),
              let parsed = try? DTSXPrivateNoNavigationZeroSideInfo(
                  controlCode: sideInfo[1],
                  dataByteCount: layout.dataByteCount
              ),
              sideInfo == parsed.serializedData(),
              DTSCRC16.checksum(ast.body[sideInfoStart..<(sideInfoEnd + 2)]) == 0,
              Data(ast.body[entropyStart..<(entropyStart + layout.entropy.count)])
                  == layout.entropy,
              ast.body.suffix(layout.trailingByteCount).allSatisfy({ $0 == 0 }) else {
            return nil
        }
        return parsed
    }
}

public struct DTSXPrivateIsolatedDecodedFrame: Sendable, Equatable {
    public let predictionHeader: DTSXPrivatePredictionHeaderCandidate
    /// Four entropy-decoded planes before any temporal or branch-specific
    /// inverse prediction is applied. Keeping this stage explicit is required
    /// to distinguish the recovered branch-zero temporal predictor from the
    /// still-open multi-height branch semantics.
    public let predictionResidualPlanes: [[Int32]]
    /// Planes after the public-XLL temporal predictor and before the private
    /// pairwise-decorrelation lifting step.
    public let temporalPredictionPlanes: [[Int32]]
    /// Four private coded planes. In the observed isolated grammar, front
    /// height audio occupies coded plane 1 and rear height audio plane 3; the
    /// left/right selection remains external to this entropy payload.
    public let codedPlanes: [[Int32]]
    public let entropyPrefixByteCount: Int
    public let bitAllocationWidth: Int
    public let entropyStartBitOffset: Int
    public let entropyEndBitOffset: Int
    /// End of decoded sample syntax for each segment, before NAVI seek or
    /// byte alignment.
    public let segmentDataEndBitOffsets: [Int]
    /// Declared NAVI boundary, or immediate byte-aligned boundary when the
    /// legacy evidence decoder is used.
    public let segmentBoundaryBitOffsets: [Int]
    public let entropySegments: [DTSXPrivateEntropySegmentSyntax]
    /// True only for the recovered compact 4x128 all-zero form.  Its
    /// continuation bytes do not carry the ordinary entropy-state flag, so
    /// diagnostics must not count them as normal state reuse.
    public var usesCompactZeroEntropySyntax: Bool = false
    /// Present only for the recovered no-NAVI all-zero form.
    public var noNavigationZeroSideInfo: DTSXPrivateNoNavigationZeroSideInfo? = nil
    public let hybridRiceParameterCount: Int
    public let hybridIsolatedSampleCount: Int
    /// Number of bits following the four decoded planes.  It is all-zero
    /// padding for the isolated profile; generalized multi-height frames can
    /// carry branch-specific data here.
    public let trailingZeroBitCount: Int
    public let trailingBitsAreAllZero: Bool

    /// Bytes between the prediction CRC and the first entropy segment.
    public var privateSideInfoByteCount: Int {
        entropyPrefixByteCount - 2
    }
}

/// Native decoder for the zero-decorrelation, exactly-one-height-channel
/// private grammar recovered from Nature's Fury. It reuses the public XLL
/// prediction and entropy rules after a seven-byte private segment prefix.
/// Multi-height frames are rejected until their activity/reordering prefix is
/// independently closed.
public enum DTSXPrivateIsolatedFrameDecoder {
    private static let channelCount = 4
    private static let frameSampleCount = 512
    private static let isolatedEntropyPrefixByteCount = 7
    private static let bitAllocationWidth = 5

    private struct EntropyState {
        var isInitialized = false
        var commonParameters = false
        var riceCoding = Array(repeating: false, count: channelCount)
        var hybridLinearWidths = Array(repeating: 0, count: channelCount)
        var partABitAllocations = Array(repeating: 0, count: channelCount)
        var partBBitAllocations = Array(repeating: 0, count: channelCount)
        var partASampleCounts = Array(repeating: 0, count: channelCount)
    }

    public static func decode(
        _ ast: DTSXPrivateFrameAST,
        segmentCount: Int = 2,
        segmentSampleCount: Int = 256,
        collectEntropyDiagnostics: Bool = false
    ) throws -> DTSXPrivateIsolatedDecodedFrame {
        let prediction = try ast.parsePredictionHeaderCandidate()
        guard prediction.matchesObservedZeroOrSingleHeightProfile else {
            throw DTSError.unsupported("XLL-X private prediction header is outside the isolated profile")
        }
        let adaptiveChannelCount = prediction.adaptivePredictionOrders.lazy.filter { $0 > 0 }.count
        guard adaptiveChannelCount == 1 else {
            throw DTSError.unsupported("XLL-X isolated decoder requires exactly one adaptive private channel")
        }
        return try decodeWithPrediction(
            ast,
            prediction: prediction,
            entropyPrefixByteCount: isolatedEntropyPrefixByteCount,
            segmentByteCounts: (try? ast.parseNavigation(
                segmentCount: segmentCount
            ))?.segmentByteCounts,
            requireTrailingBitsToBeZero: true,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            collectEntropyDiagnostics: collectEntropyDiagnostics
        )
    }

    /// Decodes the generalized candidate grammar used by the recovered
    /// four-plane private payload.  Unlike `decode`, this accepts zero,
    /// single-, pair-, and four-height activity and non-zero fixed predictor
    /// orders.  It still intentionally leaves activity/reordering semantics
    /// outside the entropy decoder; callers must compare the returned coded
    /// planes against a known PCM timeline.
    public static func decodeGeneric(
        _ ast: DTSXPrivateFrameAST,
        segmentCount: Int = 2,
        segmentSampleCount: Int = 256,
        collectEntropyDiagnostics: Bool = false
    ) throws -> DTSXPrivateIsolatedDecodedFrame {
        // A navigation-guided decode that fails must not become terminal:
        // compact NAVI words can collide byte-identically across adjacent
        // widths, and the parser resolves that collision to the canonical
        // mid-stream width. A frame whose true form is the wider colliding
        // reading still decodes through the entropy-boundary autodetect
        // paths below, exactly as ambiguous frames always have.
        if let navigation = try? ast.parseNavigation(segmentCount: segmentCount),
           let decoded = try? decodeWithPredictionCandidates(
               ast,
               predictions: ast.parsePredictionHeaderCandidates(),
               entropyPrefixByteCount: 2 + navigation.serializedByteCount,
               segmentByteCounts: navigation.segmentByteCounts,
               requireTrailingBitsToBeZero: true,
               segmentCount: segmentCount,
               segmentSampleCount: segmentSampleCount,
               collectEntropyDiagnostics: collectEntropyDiagnostics
           ) {
            return decoded
        }
        if ast.candidateSecondaryBranchCode == 1
            || ast.candidateSecondaryBranchCode == 2
            || ast.candidateSecondaryBranchCode == 3 {
            // Do not fast-path the primary prediction header at the dominant
            // seven/eight-byte prefixes. Official even-first single-
            // coefficient frames can make the false two-coefficient header
            // close at the same prefix (frame 2867), so every branch form must
            // pass through the complete candidate selector.
            return try decodeGenericAutodetected(
                ast,
                segmentCount: segmentCount,
                segmentSampleCount: segmentSampleCount,
                collectEntropyDiagnostics: collectEntropyDiagnostics
            )
        }
        if ast.candidateSecondaryBranchCode == 0 {
            return try decodeGenericAutodetected(
                ast,
                segmentCount: segmentCount,
                segmentSampleCount: segmentSampleCount,
                collectEntropyDiagnostics: collectEntropyDiagnostics
            )
        }
        return try decodeGeneric(
            ast,
            entropyPrefixByteCount: isolatedEntropyPrefixByteCount,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            collectEntropyDiagnostics: collectEntropyDiagnostics
        )
    }

    /// Decodes one candidate private entropy layout with an explicit byte count
    /// between the prediction-header boundary and the first segment. The
    /// supplied reference contains more than one observed prefix length, so
    /// analysis code must not bake the isolated-frame value into every branch.
    public static func decodeGeneric(
        _ ast: DTSXPrivateFrameAST,
        entropyPrefixByteCount: Int,
        segmentCount: Int = 2,
        segmentSampleCount: Int = 256,
        collectEntropyDiagnostics: Bool = false
    ) throws -> DTSXPrivateIsolatedDecodedFrame {
        guard entropyPrefixByteCount >= 2 else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X private entropy prefix byte count",
                value: String(entropyPrefixByteCount)
            )
        }
        let prediction = try ast.parsePredictionHeaderCandidate()
        guard prediction.matchesObservedGenericProfile else {
            throw DTSError.unsupported("XLL-X private prediction header is outside the generic profile")
        }
        return try decodeWithPrediction(
            ast,
            prediction: prediction,
            entropyPrefixByteCount: entropyPrefixByteCount,
            segmentByteCounts: nil,
            requireTrailingBitsToBeZero: false,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            collectEntropyDiagnostics: collectEntropyDiagnostics
        )
    }

    /// Diagnostic entry point for comparing CRC-valid prediction-header
    /// interpretations without changing the production selector.
    public static func decodeGeneric(
        _ ast: DTSXPrivateFrameAST,
        prediction: DTSXPrivatePredictionHeaderCandidate,
        entropyPrefixByteCount: Int,
        segmentCount: Int = 2,
        segmentSampleCount: Int = 256,
        collectEntropyDiagnostics: Bool = false
    ) throws -> DTSXPrivateIsolatedDecodedFrame {
        guard prediction.matchesObservedGenericProfile else {
            throw DTSError.unsupported(
                "XLL-X diagnostic prediction header is outside the generic profile"
            )
        }
        return try decodeWithPrediction(
            ast,
            prediction: prediction,
            entropyPrefixByteCount: entropyPrefixByteCount,
            segmentByteCounts: nil,
            requireTrailingBitsToBeZero: false,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            collectEntropyDiagnostics: collectEntropyDiagnostics
        )
    }

    /// Selects the recovered private entropy boundary using only the
    /// bitstream. A candidate is accepted when both segments decode and every
    /// remaining bit is zero. Ambiguous and unclosed private forms are rejected
    /// instead of returning plausible but unverified PCM.
    public static func decodeGenericAutodetected(
        _ ast: DTSXPrivateFrameAST,
        segmentCount: Int = 2,
        segmentSampleCount: Int = 256,
        collectEntropyDiagnostics: Bool = false
    ) throws -> DTSXPrivateIsolatedDecodedFrame {
        if let navigation = try? ast.parseNavigation(segmentCount: segmentCount),
           let predictions = try? ast.parsePredictionHeaderCandidates(),
           let decoded = try? decodeWithPredictionCandidates(
               ast,
               predictions: predictions,
               entropyPrefixByteCount: 2 + navigation.serializedByteCount,
               segmentByteCounts: navigation.segmentByteCounts,
               requireTrailingBitsToBeZero: true,
               segmentCount: segmentCount,
               segmentSampleCount: segmentSampleCount,
               collectEntropyDiagnostics: collectEntropyDiagnostics
           ) {
            return decoded
        }
        guard (0...3).contains(ast.candidateSecondaryBranchCode) else {
            throw DTSError.unsupported(
                "XLL-X automatic entropy-boundary detection found an unsupported private branch"
            )
        }
        let predictions = try ast.parsePredictionHeaderCandidates()
        var candidates: [DTSXPrivateIsolatedDecodedFrame] = []
        candidates.reserveCapacity(predictions.count)
        // Generalized 8/16-segment frames can carry substantially longer
        // side information than the dominant two-segment profile. Thirty-one
        // bytes covers the maximum recovered NAVI/CRC/alignment envelope.
        for prefixByteCount in 2...31 {
            for prediction in predictions where prediction.matchesObservedGenericProfile {
                do {
                    let decoded = try decodeWithPrediction(
                        ast,
                        prediction: prediction,
                        entropyPrefixByteCount: prefixByteCount,
                        segmentByteCounts: nil,
                        requireTrailingBitsToBeZero: true,
                        segmentCount: segmentCount,
                        segmentSampleCount: segmentSampleCount,
                        collectEntropyDiagnostics: collectEntropyDiagnostics
                    )
                    if decoded.trailingBitsAreAllZero {
                        candidates.append(decoded)
                    }
                } catch {}
            }
        }
        if candidates.isEmpty {
            throw DTSError.unsupported(
                "XLL-X private frame has no structurally unique entropy boundary"
            )
        }
        return try selectDecodedPredictionCandidate(
            ast,
            decodedCandidates: candidates,
            permitsPrimaryFallback: false
        )
    }

    private static func decodeWithPredictionCandidates(
        _ ast: DTSXPrivateFrameAST,
        predictions: [DTSXPrivatePredictionHeaderCandidate],
        entropyPrefixByteCount: Int,
        segmentByteCounts: [Int]?,
        requireTrailingBitsToBeZero: Bool,
        segmentCount: Int,
        segmentSampleCount: Int,
        collectEntropyDiagnostics: Bool
    ) throws -> DTSXPrivateIsolatedDecodedFrame {
        var decodedCandidates: [DTSXPrivateIsolatedDecodedFrame] = []
        var firstError: Error?
        for prediction in predictions where prediction.matchesObservedGenericProfile {
            do {
                decodedCandidates.append(try decodeWithPrediction(
                    ast,
                    prediction: prediction,
                    entropyPrefixByteCount: entropyPrefixByteCount,
                    segmentByteCounts: segmentByteCounts,
                    requireTrailingBitsToBeZero: requireTrailingBitsToBeZero,
                    segmentCount: segmentCount,
                    segmentSampleCount: segmentSampleCount,
                    collectEntropyDiagnostics: collectEntropyDiagnostics
                ))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if decodedCandidates.count == 1 { return decodedCandidates[0] }
        if decodedCandidates.isEmpty {
            throw firstError ?? DTSError.unsupported(
                "XLL-X private prediction header is outside the generic profile"
            )
        }
        return try selectDecodedPredictionCandidate(
            ast,
            decodedCandidates: decodedCandidates,
            permitsPrimaryFallback: true
        )
    }

    private static func selectDecodedPredictionCandidate(
        _ ast: DTSXPrivateFrameAST,
        decodedCandidates: [DTSXPrivateIsolatedDecodedFrame],
        permitsPrimaryFallback: Bool
    ) throws -> DTSXPrivateIsolatedDecodedFrame {
        guard !decodedCandidates.isEmpty else {
            throw DTSError.unsupported(
                "XLL-X private frame has no decoded prediction candidate"
            )
        }
        if decodedCandidates.count == 1 { return decodedCandidates[0] }
        var eligibleCandidates = decodedCandidates
        // In official branch-two/three frames the canonical two-coefficient form
        // uses an odd first raw code. This distinguishes it from the locally
        // plausible single-coefficient reinterpretation in startup vectors.
        // If no unique canonical form exists, preserve the primary parser's
        // deterministic ordering; later PCM/oracle checks still audit it.
        let canonicalTwoCoefficient = eligibleCandidates.filter {
            let raw = $0.predictionHeader.decorrelation.rawCoefficientCodes
            return raw.count == 2 && !raw[0].isMultiple(of: 2)
        }
        if canonicalTwoCoefficient.count == 1 {
            return canonicalTwoCoefficient[0]
        }
        if !canonicalTwoCoefficient.isEmpty {
            eligibleCandidates = canonicalTwoCoefficient
        }
        // Branches two and three use a one-coefficient pair-zero form when the
        // first raw code is even in the official corpus. Interpreting the
        // following prediction bits as
        // a second coefficient can still consume exactly to every NAVI
        // boundary, but reconstructs entirely different LPC orders and PCM
        // (official frame 798 is the minimal counterexample). Prefer the
        // unique one-coefficient closure when no odd-first canonical pair is
        // present.
        if canonicalTwoCoefficient.isEmpty
            && (ast.candidateSecondaryBranchCode == 2
                || ast.candidateSecondaryBranchCode == 3) {
            let singleCoefficient = decodedCandidates.filter {
                let decorrelation = $0.predictionHeader.decorrelation
                return decorrelation.rawCoefficientCodes.count == 1
                    && decorrelation.signedCoefficientCodes.count == 2
                    && decorrelation.signedCoefficientCodes[1] == 0
            }
            if singleCoefficient.count == 1 {
                return singleCoefficient[0]
            }
            if !singleCoefficient.isEmpty {
                eligibleCandidates = singleCoefficient
            }
        }
        if !permitsPrimaryFallback {
            let signed24Candidates = eligibleCandidates.filter { decoded in
                decoded.codedPlanes.allSatisfy { plane in
                    plane.allSatisfy { sample in
                        sample >= -8_388_608 && sample <= 8_388_607
                    }
                }
            }
            if signed24Candidates.count == 1 { return signed24Candidates[0] }
            if !signed24Candidates.isEmpty {
                eligibleCandidates = signed24Candidates
            }
        }
        // Prediction-header shape is selected before side-info CRC. A false
        // two-coefficient interpretation can otherwise expose coincidental
        // CRC-zero bytes at a different entropy boundary (official frame
        // 2867). CRC only disambiguates boundaries within the selected shape.
        if !permitsPrimaryFallback,
           let predictionCRC = try? ast.parsePredictionCRC() {
            let sideInfoStart = predictionCRC.bodyByteOffset + 2
            let crcQualified = eligibleCandidates.filter { decoded in
                guard decoded.entropyStartBitOffset.isMultiple(of: 8) else {
                    return false
                }
                let sideInfoEnd = decoded.entropyStartBitOffset / 8
                guard sideInfoEnd - sideInfoStart >= 2,
                      sideInfoStart >= 0,
                      sideInfoEnd <= ast.body.count else {
                    return false
                }
                return DTSCRC16.checksum(ast.body[sideInfoStart..<sideInfoEnd]) == 0
            }
            if crcQualified.count == 1 { return crcQualified[0] }
            if !crcQualified.isEmpty { eligibleCandidates = crcQualified }
        }
        if eligibleCandidates.count == 1 { return eligibleCandidates[0] }
        if permitsPrimaryFallback { return eligibleCandidates[0] }
        throw DTSError.unsupported(
            "XLL-X private frame has multiple structurally unique entropy boundaries"
        )
    }

    private static func decodeWithPrediction(
        _ ast: DTSXPrivateFrameAST,
        prediction: DTSXPrivatePredictionHeaderCandidate,
        entropyPrefixByteCount: Int,
        segmentByteCounts: [Int]?,
        requireTrailingBitsToBeZero: Bool,
        segmentCount: Int,
        segmentSampleCount: Int,
        collectEntropyDiagnostics: Bool
    ) throws -> DTSXPrivateIsolatedDecodedFrame {
        guard segmentCount > 0,
              segmentSampleCount > 0,
              segmentCount * segmentSampleCount == frameSampleCount else {
            throw DTSError.unsupported(
                "XLL-X private segmentation must cover exactly \(frameSampleCount) samples"
            )
        }
        let entropyStart = (prediction.boundaryByteOffset + entropyPrefixByteCount) * 8
        guard entropyStart <= ast.body.count * 8 else {
            throw DTSError.truncated(field: "XLL-X isolated entropy prefix", bitOffset: entropyStart)
        }
        var reader = try BitReader(data: ast.body)
        try reader.seek(to: entropyStart, field: "XLL-X isolated entropy start")
        var planes = Array(
            repeating: Array(repeating: Int32(0), count: frameSampleCount),
            count: channelCount
        )
        var state = EntropyState()
        var hybridRiceParameterCount = 0
        var hybridIsolatedSampleCount = 0
        var segmentDataEnds: [Int] = []
        var segmentBoundaries: [Int] = []
        var entropySegments: [DTSXPrivateEntropySegmentSyntax] = []
        for segment in 0..<segmentCount {
            let segmentEndBitOffset: Int?
            if let segmentByteCounts {
                guard segmentByteCounts.count == segmentCount,
                      segmentByteCounts[segment] > 0 else {
                    throw DTSError.malformed(
                        "XLL-X private navigation does not match the segment layout"
                    )
                }
                segmentEndBitOffset = reader.bitOffset + segmentByteCounts[segment] * 8
                guard segmentEndBitOffset! <= ast.body.count * 8 else {
                    throw DTSError.truncated(
                        field: "XLL-X private entropy segment",
                        bitOffset: reader.bitOffset
                    )
                }
            } else {
                segmentEndBitOffset = nil
            }
            let entropySegment = try decodeSegment(
                segment: segment,
                segmentSampleCount: segmentSampleCount,
                prediction: prediction,
                reader: &reader,
                state: &state,
                planes: &planes,
                hybridRiceParameterCount: &hybridRiceParameterCount,
                hybridIsolatedSampleCount: &hybridIsolatedSampleCount,
                collectEntropyDiagnostics: collectEntropyDiagnostics
            )
            entropySegments.append(entropySegment)
            segmentDataEnds.append(reader.bitOffset)
            if let segmentEndBitOffset {
                guard reader.bitOffset <= segmentEndBitOffset else {
                    throw DTSError.malformed(
                        "XLL-X private entropy segment \(segment) ends at bit "
                            + "\(reader.bitOffset), beyond NAVI boundary "
                            + "\(segmentEndBitOffset) by "
                            + "\(reader.bitOffset - segmentEndBitOffset) bits; "
                            + "common=\(state.commonParameters), "
                            + "rice=\(state.riceCoding), "
                            + "hybrid=\(state.hybridLinearWidths), "
                            + "partA=\(state.partABitAllocations), "
                            + "partB=\(state.partBBitAllocations), "
                            + "partACount=\(state.partASampleCounts)"
                    )
                }
                try reader.seek(
                    to: segmentEndBitOffset,
                    field: "XLL-X private entropy segment end"
                )
            } else if segment + 1 < segmentCount {
                try reader.alignToByte(field: "XLL-X isolated segment alignment")
            }
            segmentBoundaries.append(reader.bitOffset)
        }
        let entropyEnd = reader.bitOffset
        var trailingIsZero = true
        while reader.bitsRemaining > 0 {
            if try reader.read(1, field: "XLL-X isolated trailing padding") != 0 {
                trailingIsZero = false
            }
        }
        guard trailingIsZero || !requireTrailingBitsToBeZero else {
            throw DTSError.malformed("XLL-X isolated frame has nonzero data after its decoded samples")
        }
        let predictionResidualPlanes = planes
        inversePrediction(prediction, planes: &planes)
        let temporalPredictionPlanes = planes
        inversePairwiseDecorrelation(prediction.decorrelation, planes: &planes)
        return DTSXPrivateIsolatedDecodedFrame(
            predictionHeader: prediction,
            predictionResidualPlanes: predictionResidualPlanes,
            temporalPredictionPlanes: temporalPredictionPlanes,
            codedPlanes: planes,
            entropyPrefixByteCount: entropyPrefixByteCount,
            bitAllocationWidth: bitAllocationWidth,
            entropyStartBitOffset: entropyStart,
            entropyEndBitOffset: entropyEnd,
            segmentDataEndBitOffsets: segmentDataEnds,
            segmentBoundaryBitOffsets: segmentBoundaries,
            entropySegments: entropySegments,
            hybridRiceParameterCount: hybridRiceParameterCount,
            hybridIsolatedSampleCount: hybridIsolatedSampleCount,
            trailingZeroBitCount: ast.body.count * 8 - entropyEnd,
            trailingBitsAreAllZero: trailingIsZero
        )
    }

    private static func decodeSegment(
        segment: Int,
        segmentSampleCount: Int,
        prediction: DTSXPrivatePredictionHeaderCandidate,
        reader: inout BitReader,
        state: inout EntropyState,
        planes: inout [[Int32]],
        hybridRiceParameterCount: inout Int,
        hybridIsolatedSampleCount: inout Int,
        collectEntropyDiagnostics: Bool
    ) throws -> DTSXPrivateEntropySegmentSyntax {
        let headerStartBitOffset = reader.bitOffset
        let reuseParameters = segment > 0
            ? try reader.read(1, field: "XLL-X bUseSegStateCodeParm[\(segment)]") == 1
            : false
        if !reuseParameters {
            state.isInitialized = true
            state.commonParameters = try reader.read(
                1,
                field: "XLL-X ncSegType[\(segment)]"
            ) == 1
            let parameterCount = state.commonParameters ? 1 : channelCount
            state.riceCoding = Array(repeating: false, count: channelCount)
            state.hybridLinearWidths = Array(repeating: 0, count: channelCount)
            for parameter in 0..<parameterCount {
                state.riceCoding[parameter] = try reader.read(
                    1,
                    field: "XLL-X bRiceCodeFlag[\(segment)][\(parameter)]"
                ) == 1
                if !state.commonParameters,
                   state.riceCoding[parameter],
                   try reader.read(
                       1,
                       field: "XLL-X bHybridRiceCode[\(segment)][\(parameter)]"
                   ) == 1 {
                    state.hybridLinearWidths[parameter] = Int(try reader.read(
                        bitAllocationWidth,
                        field: "XLL-X nHybridLinearWidth[\(segment)][\(parameter)]"
                    )) + 1
                    hybridRiceParameterCount += 1
                }
            }
            for parameter in 0..<parameterCount {
                if segment == 0 {
                    var allocation = Int(try reader.read(
                        bitAllocationWidth,
                        field: "XLL-X ABIT0[\(parameter)]"
                    ))
                    if !state.riceCoding[parameter], allocation != 0 { allocation += 1 }
                    state.partABitAllocations[parameter] = allocation
                    state.partASampleCounts[parameter] = state.commonParameters
                        ? prediction.adaptivePredictionOrders.max() ?? 0
                        : prediction.adaptivePredictionOrders[parameter]
                } else {
                    state.partABitAllocations[parameter] = 0
                    state.partASampleCounts[parameter] = 0
                }
                var allocation = Int(try reader.read(
                    bitAllocationWidth,
                    field: "XLL-X ABIT[\(segment)][\(parameter)]"
                ))
                if !state.riceCoding[parameter], allocation != 0 { allocation += 1 }
                state.partBBitAllocations[parameter] = allocation
            }
        }
        guard state.isInitialized else {
            throw DTSError.malformed("XLL-X isolated entropy reuses parameters before initialization")
        }
        let sampleDataStartBitOffset = reader.bitOffset

        let segmentOffset = segment * segmentSampleCount
        let isolatedLocationBitCount = segmentSampleCount.trailingZeroBitCount
        guard isolatedLocationBitCount > 0,
              1 << isolatedLocationBitCount == segmentSampleCount else {
            throw DTSError.unsupported(
                "XLL-X Hybrid Rice requires a power-of-two segment sample count"
            )
        }
        var hybridIsolatedSampleOffsets = Array(
            repeating: [Int](),
            count: channelCount
        )
        for channel in 0..<channelCount {
            let parameter = state.commonParameters ? 0 : channel
            let partASamples = state.partASampleCounts[parameter]
            let partBSamples = segmentSampleCount - partASamples
            guard partASamples >= 0, partBSamples >= 0 else {
                throw DTSError.malformed("XLL-X isolated entropy partition exceeds its segment")
            }
            if state.riceCoding[parameter] {
                for sample in 0..<partASamples {
                    planes[channel][segmentOffset + sample] = try readRice(
                        parameter: state.partABitAllocations[parameter],
                        reader: &reader,
                        field: "XLL-X isolated part A Rice sample"
                    )
                }
                if state.hybridLinearWidths[parameter] > 0 {
                    let isolatedCount = Int(try reader.read(
                        isolatedLocationBitCount,
                        field: "XLL-X nIsolatedSamples[\(segment)][\(channel)]"
                    ))
                    hybridIsolatedSampleCount += isolatedCount
                    var isolated = Set<Int>()
                    isolated.reserveCapacity(isolatedCount)
                    var offsets: [Int] = []
                    offsets.reserveCapacity(isolatedCount)
                    for _ in 0..<isolatedCount {
                        let location = Int(try reader.read(
                            isolatedLocationBitCount,
                            field: "XLL-X nIsolatedSampleLocation[\(segment)][\(channel)]"
                        ))
                        guard location < partBSamples else {
                            throw DTSError.malformed("XLL-X isolated sample location exceeds part B")
                        }
                        isolated.insert(location)
                        offsets.append(location)
                    }
                    hybridIsolatedSampleOffsets[channel] = offsets
                    for sample in 0..<partBSamples {
                        planes[channel][segmentOffset + partASamples + sample] = isolated.contains(sample)
                            ? try readLinear(
                                width: state.hybridLinearWidths[parameter],
                                reader: &reader,
                                field: "XLL-X isolated hybrid sample"
                            )
                            : try readRice(
                                parameter: state.partBBitAllocations[parameter],
                                reader: &reader,
                                field: "XLL-X isolated part B Rice sample"
                            )
                    }
                } else {
                    for sample in 0..<partBSamples {
                        planes[channel][segmentOffset + partASamples + sample] = try readRice(
                            parameter: state.partBBitAllocations[parameter],
                            reader: &reader,
                            field: "XLL-X isolated part B Rice sample"
                        )
                    }
                }
            } else {
                for sample in 0..<partASamples {
                    planes[channel][segmentOffset + sample] = try readLinear(
                        width: state.partABitAllocations[parameter],
                        reader: &reader,
                        field: "XLL-X isolated part A linear sample"
                    )
                }
                for sample in 0..<partBSamples {
                    planes[channel][segmentOffset + partASamples + sample] = try readLinear(
                        width: state.partBBitAllocations[parameter],
                        reader: &reader,
                        field: "XLL-X isolated part B linear sample"
                    )
                }
            }
        }
        return DTSXPrivateEntropySegmentSyntax(
            segmentIndex: segment,
            reusesPreviousParameters: reuseParameters,
            commonParameters: state.commonParameters,
            riceCoding: state.riceCoding,
            hybridLinearWidths: state.hybridLinearWidths,
            hybridIsolatedSampleOffsets: hybridIsolatedSampleOffsets,
            partABitAllocations: state.partABitAllocations,
            partBBitAllocations: state.partBBitAllocations,
            partASampleCounts: state.partASampleCounts,
            partASampleValues: (0..<channelCount).map { channel in
                let parameter = state.commonParameters ? 0 : channel
                let count = state.partASampleCounts[parameter]
                return Array(planes[channel][segmentOffset..<(segmentOffset + count)])
            },
            partBMeanAbsoluteMagnitudes: collectEntropyDiagnostics
                ? (0..<channelCount).map { channel in
                    let parameter = state.commonParameters ? 0 : channel
                    let start = segmentOffset + state.partASampleCounts[parameter]
                    return meanAbsoluteMagnitude(
                        planes[channel][start..<(segmentOffset + segmentSampleCount)]
                    )
                } : [],
            partBLinearWidths: collectEntropyDiagnostics ? (0..<channelCount).map { channel in
                let parameter = state.commonParameters ? 0 : channel
                let start = segmentOffset + state.partASampleCounts[parameter]
                return minimumLinearWidth(planes[channel][start..<(segmentOffset + segmentSampleCount)])
            } : [],
            partBRicePayloadBitCounts: collectEntropyDiagnostics ? (0..<channelCount).map { channel in
                let parameter = state.commonParameters ? 0 : channel
                let start = segmentOffset + state.partASampleCounts[parameter]
                return ricePayloadBitCounts(
                    planes[channel][start..<(segmentOffset + segmentSampleCount)]
                )
            } : [],
            headerStartBitOffset: headerStartBitOffset,
            sampleDataStartBitOffset: sampleDataStartBitOffset,
            sampleDataEndBitOffset: reader.bitOffset
        )
    }

    private static func minimumLinearWidth(_ samples: ArraySlice<Int32>) -> Int {
        var maximumMapped: UInt64 = 0
        for sample in samples {
            maximumMapped = max(maximumMapped, zigZag(sample))
        }
        return maximumMapped == 0
            ? 0 : max(2, UInt64.bitWidth - maximumMapped.leadingZeroBitCount)
    }

    private static func meanAbsoluteMagnitude(_ samples: ArraySlice<Int32>) -> Int {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(UInt64(0)) { partial, sample in
            partial + UInt64(Swift.abs(Int64(sample)))
        }
        return Int(sum / UInt64(samples.count))
    }

    private static func ricePayloadBitCounts(_ samples: ArraySlice<Int32>) -> [Int] {
        (0...31).map { parameter in
            samples.reduce(0) { total, sample in
                let mapped = zigZag(sample)
                return total + Int(mapped >> UInt64(parameter)) + 1 + parameter
            }
        }
    }

    private static func zigZag(_ value: Int32) -> UInt64 {
        let signed = Int64(value)
        return signed >= 0
            ? UInt64(signed) << 1
            : UInt64((-signed << 1) - 1)
    }

    @inline(__always)
    private static func readLinear(
        width: Int,
        reader: inout BitReader,
        field: @autoclosure () -> String
    ) throws -> Int32 {
        guard (0...32).contains(width) else {
            throw DTSError.valueOutOfRange(
                field: "\(field()).width",
                value: String(width)
            )
        }
        if width == 0 { return 0 }
        let raw = try reader.read(width, field: field())
        let magnitude = Int64(raw >> 1)
        let signed = (raw & 1) == 0 ? magnitude : -magnitude - 1
        guard signed >= Int64(Int32.min), signed <= Int64(Int32.max) else {
            throw DTSError.valueOutOfRange(
                field: field(),
                value: String(signed)
            )
        }
        return Int32(signed)
    }

    @inline(__always)
    private static func readRice(
        parameter: Int,
        reader: inout BitReader,
        field: @autoclosure () -> String
    ) throws -> Int32 {
        guard (0...31).contains(parameter) else {
            throw DTSError.valueOutOfRange(
                field: "\(field()).parameter",
                value: String(parameter)
            )
        }
        let maximumQuotient = max(0, reader.bitsRemaining - parameter - 1)
        let quotient = try reader.readUnary(
            maximumZeroBitCount: maximumQuotient,
            field: field()
        )
        let remainder = parameter > 0
            ? try reader.read(parameter, field: "\(field()).remainder") : 0
        let mapped = (UInt64(quotient) << UInt64(parameter)) | remainder
        let magnitude = Int64(mapped >> 1)
        let signed = (mapped & 1) == 0 ? magnitude : -magnitude - 1
        guard signed >= Int64(Int32.min), signed <= Int64(Int32.max) else {
            throw DTSError.valueOutOfRange(
                field: field(),
                value: String(signed)
            )
        }
        return Int32(signed)
    }

    private static func inversePrediction(
        _ prediction: DTSXPrivatePredictionHeaderCandidate,
        planes: inout [[Int32]]
    ) {
        for channel in planes.indices {
            let adaptiveOrder = prediction.adaptivePredictionOrders[channel]
            if adaptiveOrder > 0 {
                let indices = prediction.reflectionCoefficientSignedIndices[channel]
                var direct = Array(repeating: Int32(0), count: adaptiveOrder)
                for index in 0..<adaptiveOrder {
                    let signedIndex = Int(indices[index])
                    let raw = Int32(XLLSyntax.reflectionCoefficients[abs(signedIndex)])
                    let coefficient = signedIndex < 0 ? -raw : raw
                    for pairIndex in 0..<((index + 1) / 2) {
                        let opposite = index - pairIndex - 1
                        let first = direct[pairIndex]
                        let second = direct[opposite]
                        direct[pairIndex] = first &+ multiplyQ16(coefficient, second)
                        direct[opposite] = second &+ multiplyQ16(coefficient, first)
                    }
                    direct[index] = coefficient
                }
                for sample in 0..<(planes[channel].count - adaptiveOrder) {
                    var error: Int64 = 0
                    for coefficient in 0..<adaptiveOrder {
                        error += Int64(planes[channel][sample + coefficient])
                            * Int64(direct[adaptiveOrder - coefficient - 1])
                    }
                    let predicted = clip24(roundShift(error, by: 16))
                    planes[channel][sample + adaptiveOrder] =
                        planes[channel][sample + adaptiveOrder] &- predicted
                }
            } else {
                let fixedOrder = prediction.fixedPredictionOrders[channel] ?? 0
                for _ in 0..<fixedOrder {
                    for sample in 1..<planes[channel].count {
                        planes[channel][sample] = planes[channel][sample] &+ planes[channel][sample - 1]
                    }
                }
            }
        }
    }

    private static func inversePairwiseDecorrelation(
        _ decorrelation: DTSXPrivateDecorrelationCandidate,
        planes: inout [[Int32]]
    ) {
        guard decorrelation.signedCoefficientCodes.count == planes.count / 2 else {
            return
        }
        for pair in decorrelation.signedCoefficientCodes.indices {
            let coefficient = decorrelation.signedCoefficientCodes[pair]
            let source = pair * 2
            let destination = source + 1
            guard coefficient != 0 else { continue }
            for sample in planes[destination].indices {
                let delta = Int32(truncatingIfNeeded:
                    (Int64(planes[source][sample]) * Int64(coefficient) + 4) >> 3
                )
                planes[destination][sample] = planes[destination][sample] &+ delta
            }
        }
    }

    @inline(__always)
    private static func multiplyQ16(_ first: Int32, _ second: Int32) -> Int32 {
        Int32(truncatingIfNeeded: roundShift(Int64(first) * Int64(second), by: 16))
    }

    @inline(__always)
    private static func roundShift(_ value: Int64, by shift: Int) -> Int64 {
        shift > 0 ? (value + (Int64(1) << (shift - 1))) >> shift : value
    }

    @inline(__always)
    private static func clip24(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }
}

/// Generalized entry point for the recovered four-plane XLL-X candidate
/// grammar.  Plane-to-speaker activity and reordering are intentionally not
/// guessed here: the decoder returns native coded-plane order so the mapping
/// can be established with sample-exact oracle comparisons.
public enum DTSXPrivateFrameDecoder {
    public static func decode(
        _ ast: DTSXPrivateFrameAST,
        segmentCount: Int = 2,
        segmentSampleCount: Int = 256,
        collectEntropyDiagnostics: Bool = false
    ) throws -> DTSXPrivateIsolatedDecodedFrame {
        if let compactSilence = DTSXPrivateCompactSilenceDecoder.decode(
            ast,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount
        ) {
            return compactSilence
        }
        if let noNavigationSilence = try DTSXPrivateNoNavigationSilenceDecoder.decode(
            ast,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            collectEntropyDiagnostics: collectEntropyDiagnostics
        ) {
            return noNavigationSilence
        }
        return try DTSXPrivateIsolatedFrameDecoder.decodeGeneric(
            ast,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            collectEntropyDiagnostics: collectEntropyDiagnostics
        )
    }
}

/// Decoder for the CRC-closed zero-code layout that carries side information
/// instead of an XLL-X NAVI table.  Its byte count is determined by the public
/// XLL segmentation and the recovered control declaration; only then is the
/// ordinary entropy reader allowed to consume the fixed compact segments.
private enum DTSXPrivateNoNavigationSilenceDecoder {
    static func decode(
        _ ast: DTSXPrivateFrameAST,
        segmentCount: Int,
        segmentSampleCount: Int,
        collectEntropyDiagnostics: Bool
    ) throws -> DTSXPrivateIsolatedDecodedFrame? {
        guard let prediction = try? ast.parsePredictionHeaderCandidate(),
              let sideInfo = try DTSXPrivateNoNavigationZeroSideInfo.parse(
                  ast,
                  prediction: prediction,
                  segmentCount: segmentCount,
                  segmentSampleCount: segmentSampleCount
              ) else {
            return nil
        }
        let entropyPrefixByteCount = 2 + sideInfo.dataByteCount + 2
        var decoded = try DTSXPrivateIsolatedFrameDecoder.decodeGeneric(
            ast,
            entropyPrefixByteCount: entropyPrefixByteCount,
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            collectEntropyDiagnostics: collectEntropyDiagnostics
        )
        guard decoded.codedPlanes.allSatisfy({ $0.allSatisfy({ $0 == 0 }) }),
              decoded.trailingBitsAreAllZero else {
            return nil
        }
        decoded.noNavigationZeroSideInfo = sideInfo
        return decoded
    }
}

/// Decoder for the CRC-closed, compact four-segment zero-code form observed
/// when public XLL selects 4x128 while all four XLL-X planes are silent.  This
/// syntax intentionally does not pass through the ordinary entropy parser:
/// its two-byte first segment and one-byte continuations omit the normal
/// allocation declarations.  Every byte, navigation value, and checksum is
/// checked before it is accepted as 512 zero samples per plane.
private enum DTSXPrivateCompactSilenceDecoder {
    static func decode(
        _ ast: DTSXPrivateFrameAST,
        segmentCount: Int,
        segmentSampleCount: Int
    ) -> DTSXPrivateIsolatedDecodedFrame? {
        guard segmentCount == 4,
              segmentSampleCount == 128,
              ast.headerCRCIsValid,
              ast.matchesObservedStandardProfile,
              ast.candidateSecondaryBranchCode == 0,
              let prediction = try? ast.parsePredictionHeaderCandidate(),
              prediction.matchesObservedGenericProfile,
              prediction.adaptivePredictionOrders == [0, 0, 0, 0],
              prediction.fixedPredictionOrders.allSatisfy({ $0 == 0 }),
              prediction.boundaryByteOffset == 8,
              prediction.crc.isValid,
              let navigation = try? ast.parseNavigation(segmentCount: segmentCount),
              navigation.crcIsValid,
              navigation.bitWidth == 8,
              navigation.segmentByteCounts == [2, 1, 1, 1],
              navigation.trailingFrameByteCount == 3 else {
            return nil
        }
        let entropyStartByteOffset = prediction.boundaryByteOffset + 2
            + navigation.serializedByteCount
        guard ast.body.count == entropyStartByteOffset + 5 + 3,
              Data(ast.body[entropyStartByteOffset..<(entropyStartByteOffset + 5)])
                == Data([0x80, 0x00, 0x40, 0x40, 0x40]),
              ast.body.suffix(3) == Data([0, 0, 0]) else {
            return nil
        }

        let zeros = Array(
            repeating: Array(repeating: Int32(0), count: 512),
            count: 4
        )
        var entropySegments: [DTSXPrivateEntropySegmentSyntax] = []
        var segmentDataEnds: [Int] = []
        var segmentBoundaries: [Int] = []
        var bitOffset = entropyStartByteOffset * 8
        for (segment, byteCount) in navigation.segmentByteCounts.enumerated() {
            let segmentEnd = bitOffset + byteCount * 8
            entropySegments.append(DTSXPrivateEntropySegmentSyntax(
                segmentIndex: segment,
                reusesPreviousParameters: segment > 0,
                commonParameters: false,
                riceCoding: [false, false, false, false],
                hybridLinearWidths: [0, 0, 0, 0],
                hybridIsolatedSampleOffsets: [[], [], [], []],
                partABitAllocations: [0, 0, 0, 0],
                partBBitAllocations: [0, 0, 0, 0],
                partASampleCounts: [0, 0, 0, 0],
                partASampleValues: [[], [], [], []],
                partBMeanAbsoluteMagnitudes: [0, 0, 0, 0],
                partBLinearWidths: [0, 0, 0, 0],
                partBRicePayloadBitCounts: [[], [], [], []],
                headerStartBitOffset: bitOffset,
                sampleDataStartBitOffset: bitOffset,
                sampleDataEndBitOffset: segmentEnd
            ))
            segmentDataEnds.append(segmentEnd)
            segmentBoundaries.append(segmentEnd)
            bitOffset = segmentEnd
        }
        return DTSXPrivateIsolatedDecodedFrame(
            predictionHeader: prediction,
            predictionResidualPlanes: zeros,
            temporalPredictionPlanes: zeros,
            codedPlanes: zeros,
            entropyPrefixByteCount: 2 + navigation.serializedByteCount,
            bitAllocationWidth: 5,
            entropyStartBitOffset: entropyStartByteOffset * 8,
            entropyEndBitOffset: bitOffset,
            segmentDataEndBitOffsets: segmentDataEnds,
            segmentBoundaryBitOffsets: segmentBoundaries,
            entropySegments: entropySegments,
            usesCompactZeroEntropySyntax: true,
            hybridRiceParameterCount: 0,
            hybridIsolatedSampleCount: 0,
            trailingZeroBitCount: ast.body.count * 8 - bitOffset,
            trailingBitsAreAllZero: true
        )
    }
}

public struct DTSXPrivateASTVerificationReport: Sendable, Equatable, Codable {
    public let indexPath: String
    public let payloadPath: String
    public let payloadSHA256: String
    public let frameCount: Int
    public let byteExactFrameCount: Int
    public let crcValidFrameCount: Int
    public let predictionCRCValidFrameCount: Int
    public let predictionHeaderParsedFrameCount: Int
    public let predictionHeaderEncoderEligibleFrameCount: Int
    public let predictionHeaderRebuiltByteExactFrameCount: Int
    public let navigationParsedFrameCount: Int
    public let navigationRebuiltByteExactFrameCount: Int
    public let observedProfileFrameCount: Int
    public let minimumFrameByteCount: Int
    public let maximumFrameByteCount: Int
    public let totalFrameByteCount: Int
    public let allFramesRoundTripExactly: Bool
    public let allEncoderEligiblePredictionHeadersRebuiltExactly: Bool
    public let allParsedNavigationsRebuiltExactly: Bool
}

public enum DTSXPrivateASTVerifier {
    public static func verify(
        indexURL: URL,
        payloadURL: URL
    ) throws -> DTSXPrivateASTVerificationReport {
        let loaded = try DTSXPrivateArtifactLoader.load(
            indexURL: indexURL,
            payloadURL: payloadURL
        )
        var exact = 0
        var crcValid = 0
        var predictionCRCValid = 0
        var predictionHeaderParsed = 0
        var predictionHeaderEncoderEligible = 0
        var predictionHeaderRebuiltByteExact = 0
        var navigationParsed = 0
        var navigationRebuiltByteExact = 0
        var observed = 0
        var minimum = Int.max
        var maximum = 0
        var total = 0
        for record in loaded.records {
            let bytes = loaded.frameBytes(record)
            let ast = try DTSXPrivateFrameAST.parse(bytes)
            let segmentCount = record.xllSyntax?.segmentCount
            if try ast.serialize() == Data(bytes) { exact += 1 }
            if ast.headerCRCIsValid { crcValid += 1 }
            if try ast.parsePredictionCRC().isValid { predictionCRCValid += 1 }
            if let prediction = try? ast.parsePredictionHeaderCandidate() {
                predictionHeaderParsed += 1
                if prediction.matchesObservedGenericProfile {
                    predictionHeaderEncoderEligible += 1
                    if try ast.serializeRebuildingPredictionHeaderAndCRC() == Data(bytes) {
                        predictionHeaderRebuiltByteExact += 1
                    }
                }
            }
            if let segmentCount,
               segmentCount > 0,
               let navigation = try? ast.parseNavigation(segmentCount: segmentCount) {
                navigationParsed += 1
                if try ast.serializeReplacingNavigation(navigation) == Data(bytes) {
                    navigationRebuiltByteExact += 1
                }
            }
            if ast.matchesObservedStandardProfile { observed += 1 }
            minimum = min(minimum, bytes.count)
            maximum = max(maximum, bytes.count)
            total += bytes.count
        }
        return DTSXPrivateASTVerificationReport(
            indexPath: indexURL.standardizedFileURL.path,
            payloadPath: payloadURL.standardizedFileURL.path,
            payloadSHA256: SHA256Hasher.hash(loaded.payload),
            frameCount: loaded.records.count,
            byteExactFrameCount: exact,
            crcValidFrameCount: crcValid,
            predictionCRCValidFrameCount: predictionCRCValid,
            predictionHeaderParsedFrameCount: predictionHeaderParsed,
            predictionHeaderEncoderEligibleFrameCount: predictionHeaderEncoderEligible,
            predictionHeaderRebuiltByteExactFrameCount: predictionHeaderRebuiltByteExact,
            navigationParsedFrameCount: navigationParsed,
            navigationRebuiltByteExactFrameCount: navigationRebuiltByteExact,
            observedProfileFrameCount: observed,
            minimumFrameByteCount: minimum == Int.max ? 0 : minimum,
            maximumFrameByteCount: maximum,
            totalFrameByteCount: total,
            allFramesRoundTripExactly: !loaded.records.isEmpty
                && exact == loaded.records.count
                && crcValid == loaded.records.count
                && predictionCRCValid == loaded.records.count,
            allEncoderEligiblePredictionHeadersRebuiltExactly:
                predictionHeaderEncoderEligible > 0
                && predictionHeaderRebuiltByteExact == predictionHeaderEncoderEligible,
            allParsedNavigationsRebuiltExactly: navigationParsed > 0
                && navigationRebuiltByteExact == navigationParsed
        )
    }
}

struct DTSXPrivateLoadedArtifacts {
    let records: [DTSXPrivateFrameRecord]
    let payload: Data

    func frameBytes(_ record: DTSXPrivateFrameRecord) -> Data.SubSequence {
        let start = record.payloadFileOffset!
        return payload[start..<(start + record.payloadByteCount)]
    }
}

enum DTSXPrivateArtifactLoader {
    static func load(indexURL: URL, payloadURL: URL) throws -> DTSXPrivateLoadedArtifacts {
        let extraction: DTSXExtractionReport
        let payload: Data
        do {
            extraction = try JSONDecoder().decode(
                DTSXExtractionReport.self,
                from: Data(contentsOf: indexURL, options: .mappedIfSafe)
            )
            payload = try Data(contentsOf: payloadURL, options: .mappedIfSafe)
        } catch {
            throw DTSError.io("cannot read XLL-X private artifacts: \(error.localizedDescription)")
        }
        let records = extraction.frames.filter {
            $0.payloadFileOffset != nil && $0.payloadByteCount >= 30
        }
        guard !records.isEmpty else {
            throw DTSError.malformed("XLL-X private artifact contains no complete frames")
        }
        for record in records {
            let offset = record.payloadFileOffset!
            guard offset >= 0, offset + record.payloadByteCount <= payload.count else {
                throw DTSError.malformed("XLL-X private frame index is outside its payload")
            }
            if let expectedSHA = record.payloadSHA256 {
                let frame = payload[offset..<(offset + record.payloadByteCount)]
                guard SHA256Hasher.hash(Data(frame)) == expectedSHA else {
                    throw DTSError.malformed(
                        "XLL-X private frame \(record.frameIndex) SHA-256 differs from its index"
                    )
                }
            }
        }
        return DTSXPrivateLoadedArtifacts(records: records, payload: payload)
    }
}
