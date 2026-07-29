import Foundation

public struct DTSXPrivateEncoderVectorReport: Sendable, Equatable, Codable {
    public let name: String
    public let frameByteCount: Int
    public let frameSHA256: String
    public let headerCRCIsValid: Bool
    public let predictionCRCIsValid: Bool
    public let navigationPresent: Bool
    public let navigationCRCIsValid: Bool
    public let segmentCount: Int
    public let segmentSampleCount: Int
    public let adaptivePredictionOrders: [Int]
    public let containsReservedReflectionIndex: Bool
    public let decorrelationBranchCode: Int
    public let decorrelationCoefficientCodes: [Int]
    public let hybridRiceParameterCount: Int
    public let hybridIsolatedSampleCount: Int
    public let deterministic: Bool
    public let decodedSampleMismatchCount: Int
    public let isBitExact: Bool
}

public struct DTSXPrivateEncoderVerificationReport: Sendable, Equatable, Codable {
    public let vectors: [DTSXPrivateEncoderVectorReport]
    public let navigationBitWidthsRoundTripped: [Int]
    public let minimumFrameByteCount: Int
    public let maximumFrameByteCount: Int
    public let allNavigationBitWidthsRoundTrip: Bool
    public let adaptivePredictionVectorPassed: Bool
    public let pairwiseDecorrelationVectorPassed: Bool
    public let deterministicTieBreakVectorPassed: Bool
    public let hybridRiceVectorPassed: Bool
    public let allVectorsBitExact: Bool
}

public enum DTSXPrivateEncoderVerifier {
    public static func verify() throws -> DTSXPrivateEncoderVerificationReport {
        let twoSegments = DTSXPrivateFrameEncoder.defaultSegmentationPlan
        let fourSegments = try XLLSegmentationPlan(segmentCount: 4, segmentSampleCount: 128)
        let eightSegments = try XLLSegmentationPlan(segmentCount: 8, segmentSampleCount: 64)
        let vectors: [(String, [[Int32]], Bool, XLLSegmentationPlan)] = [
            ("silence", silence(), false, twoSegments),
            ("four-plane-impulses", impulses(), false, twoSegments),
            ("signed-full-scale-alternating", fullScaleAlternating(), false, twoSegments),
            ("deterministic-wide-ramp", wideRamp(), false, twoSegments),
            ("filtered-autoregressive", filteredAutoregressive(), false, twoSegments),
            ("hybrid-rice-outliers", hybridRiceOutliers(), false, twoSegments),
            ("correlated-pairs", correlatedPairs(), true, twoSegments),
            ("decorrelation-coefficient-tie", decorrelationCoefficientTie(), true, twoSegments),
            ("silence-four-segments", silence(), false, fourSegments),
            ("impulses-four-segments", impulses(), false, fourSegments),
            ("wide-ramp-eight-segments", wideRamp(), false, eightSegments)
        ]
        var reports: [DTSXPrivateEncoderVectorReport] = []
        reports.reserveCapacity(vectors.count)
        for (name, planes, optimizePairwiseDecorrelation, segmentationPlan) in vectors {
            let encoder = DTSXPrivateFrameEncoder(
                allowsExperimentalHybridRice: name == "hybrid-rice-outliers"
            )
            let first = try encoder.encode(
                codedPlanes: planes,
                optimizePairwiseDecorrelation: optimizePairwiseDecorrelation,
                segmentationPlan: segmentationPlan
            )
            let second = try encoder.encode(
                codedPlanes: planes,
                optimizePairwiseDecorrelation: optimizePairwiseDecorrelation,
                segmentationPlan: segmentationPlan
            )
            let ast = try DTSXPrivateFrameAST.parse(first[...])
            let prediction = try ast.parsePredictionHeaderCandidate()
            let decoded = try DTSXPrivateFrameDecoder.decode(
                ast,
                segmentCount: segmentationPlan.segmentCount,
                segmentSampleCount: segmentationPlan.segmentSampleCount
            )
            var mismatches = 0
            for channel in 0..<DTSXPrivateFrameEncoder.channelCount {
                for sample in 0..<DTSXPrivateFrameEncoder.frameSampleCount
                    where decoded.codedPlanes[channel][sample] != planes[channel][sample] {
                    mismatches += 1
                }
            }
            let predictionCRC = try ast.parsePredictionCRC()
            let navigation = try? ast.parseNavigation(
                segmentCount: segmentationPlan.segmentCount
            )
            let deterministic = first == second
            let exact = mismatches == 0
                && ast.headerCRCIsValid
                && predictionCRC.isValid
                && (navigation?.crcIsValid ?? true)
                && !prediction.containsReservedReflectionIndex
                && deterministic
            reports.append(DTSXPrivateEncoderVectorReport(
                name: name,
                frameByteCount: first.count,
                frameSHA256: SHA256Hasher.hash(first),
                headerCRCIsValid: ast.headerCRCIsValid,
                predictionCRCIsValid: predictionCRC.isValid,
                navigationPresent: navigation != nil,
                navigationCRCIsValid: navigation?.crcIsValid ?? true,
                segmentCount: segmentationPlan.segmentCount,
                segmentSampleCount: segmentationPlan.segmentSampleCount,
                adaptivePredictionOrders: prediction.adaptivePredictionOrders,
                containsReservedReflectionIndex: prediction.containsReservedReflectionIndex,
                decorrelationBranchCode: prediction.decorrelation.branchCode,
                decorrelationCoefficientCodes: prediction.decorrelation.rawCoefficientCodes,
                hybridRiceParameterCount: decoded.hybridRiceParameterCount,
                hybridIsolatedSampleCount: decoded.hybridIsolatedSampleCount,
                deterministic: deterministic,
                decodedSampleMismatchCount: mismatches,
                isBitExact: exact
            ))
        }
        let navigationBitWidths = try verifyNavigationBitWidths()
        let allNavigationBitWidthsRoundTrip = navigationBitWidths == Array(8...12)
        let adaptivePredictionVectorPassed = reports.contains { report in
            report.name == "filtered-autoregressive"
                && report.isBitExact
                && report.adaptivePredictionOrders.contains(where: { $0 > 0 })
        }
        let pairwiseDecorrelationVectorPassed = reports.contains { report in
            report.name == "correlated-pairs"
                && report.isBitExact
                && report.decorrelationBranchCode == 2
                && report.decorrelationCoefficientCodes.count == 2
        }
        let deterministicTieBreakVectorPassed = reports.contains { report in
            report.name == "decorrelation-coefficient-tie"
                && report.isBitExact
                && report.decorrelationBranchCode == 2
                && report.decorrelationCoefficientCodes == [0, 16]
        }
        let hybridRiceVectorPassed = reports.contains { report in
            report.name == "hybrid-rice-outliers"
                && report.isBitExact
                && report.hybridRiceParameterCount > 0
                && report.hybridIsolatedSampleCount > 0
        }
        let report = DTSXPrivateEncoderVerificationReport(
            vectors: reports,
            navigationBitWidthsRoundTripped: navigationBitWidths,
            minimumFrameByteCount: reports.map(\.frameByteCount).min() ?? 0,
            maximumFrameByteCount: reports.map(\.frameByteCount).max() ?? 0,
            allNavigationBitWidthsRoundTrip: allNavigationBitWidthsRoundTrip,
            adaptivePredictionVectorPassed: adaptivePredictionVectorPassed,
            pairwiseDecorrelationVectorPassed: pairwiseDecorrelationVectorPassed,
            deterministicTieBreakVectorPassed: deterministicTieBreakVectorPassed,
            hybridRiceVectorPassed: hybridRiceVectorPassed,
            allVectorsBitExact: !reports.isEmpty
                && reports.allSatisfy(\.isBitExact)
                && allNavigationBitWidthsRoundTrip
                && adaptivePredictionVectorPassed
                && pairwiseDecorrelationVectorPassed
                && deterministicTieBreakVectorPassed
                && hybridRiceVectorPassed
        )
        guard report.allVectorsBitExact else {
            let failedVectors = reports.filter { !$0.isBitExact }.map(\.name).joined(separator: ",")
            throw DTSError.malformed(
                "native XLL-X encoder conformance vectors failed: vectors=[\(failedVectors)], "
                    + "navigation=\(navigationBitWidths), "
                    + "adaptive=\(adaptivePredictionVectorPassed), "
                    + "decorrelation=\(pairwiseDecorrelationVectorPassed), "
                    + "tie=\(deterministicTieBreakVectorPassed), hybrid=\(hybridRiceVectorPassed)"
            )
        }
        return report
    }

    private static func verifyNavigationBitWidths() throws -> [Int] {
        var verified: [Int] = []
        for bitWidth in 8...12 {
            let expectedCounts = [1, 2]
            let serialized = try DTSXPrivateNavigation(
                bitWidth: bitWidth,
                segmentByteCounts: expectedCounts,
                trailingFrameByteCount: 0
            ).serialize()
            guard serialized.count == DTSXPrivateNavigation.byteCount,
                  DTSCRC16.checksum(serialized) == 0 else {
                continue
            }
            let parsed = try DTSXPrivateNavigation.parse(
                serialized,
                entropyStartByteOffset: 0,
                frameBodyByteCount: expectedCounts.reduce(0, +)
            )
            guard parsed.bitWidth == bitWidth,
                  parsed.segmentByteCounts == expectedCounts,
                  parsed.trailingFrameByteCount == 0,
                  parsed.zeroPaddingBitCount == 24 - bitWidth * 2,
                  parsed.crcIsValid,
                  try parsed.serialize() == serialized else {
                continue
            }
            verified.append(bitWidth)
        }
        return verified
    }

    private static func silence() -> [[Int32]] {
        Array(
            repeating: Array(
                repeating: 0,
                count: DTSXPrivateFrameEncoder.frameSampleCount
            ),
            count: DTSXPrivateFrameEncoder.channelCount
        )
    }

    private static func impulses() -> [[Int32]] {
        var planes = silence()
        planes[0][0] = 1
        planes[1][127] = -1
        planes[2][256] = 8_388_607
        planes[3][511] = -8_388_608
        return planes
    }

    private static func fullScaleAlternating() -> [[Int32]] {
        (0..<DTSXPrivateFrameEncoder.channelCount).map { channel in
            (0..<DTSXPrivateFrameEncoder.frameSampleCount).map { sample in
                (sample + channel).isMultiple(of: 2) ? 8_388_607 : -8_388_608
            }
        }
    }

    private static func wideRamp() -> [[Int32]] {
        (0..<DTSXPrivateFrameEncoder.channelCount).map { channel in
            (0..<DTSXPrivateFrameEncoder.frameSampleCount).map { sample in
                let phase = (sample * (channel * 2 + 1) * 32_771) & 0x00ff_ffff
                return phase < 0x0080_0000
                    ? Int32(phase)
                    : Int32(phase - 0x0100_0000)
            }
        }
    }

    private static func filteredAutoregressive() -> [[Int32]] {
        (0..<DTSXPrivateFrameEncoder.channelCount).map { channel in
            var state = UInt32(0x9e37_79b9 &+ UInt32(channel) &* 0x10001)
            var plane = Array(
                repeating: Int32(0),
                count: DTSXPrivateFrameEncoder.frameSampleCount
            )
            for sample in 2..<plane.count {
                state = state &* 1_664_525 &+ 1_013_904_223
                let excitation = Int32(truncatingIfNeeded: (state >> 20) & 0xfff) - 2_048
                plane[sample] = Int32(
                    (Int64(plane[sample - 1]) * 3 - Int64(plane[sample - 2])) / 4
                ) &+ excitation
            }
            return plane
        }
    }

    private static func correlatedPairs() -> [[Int32]] {
        let first = (0..<DTSXPrivateFrameEncoder.frameSampleCount).map { sample in
            Int32((sample * 7_919) % 200_001 - 100_000)
        }
        let second = (0..<DTSXPrivateFrameEncoder.frameSampleCount).map { sample in
            Int32((sample * 5_123) % 160_001 - 80_000)
        }
        return [first, first, second, second]
    }

    private static func hybridRiceOutliers() -> [[Int32]] {
        (0..<DTSXPrivateFrameEncoder.channelCount).map { channel in
            (0..<DTSXPrivateFrameEncoder.frameSampleCount).map { sample in
                if sample % (61 + channel * 2) == channel {
                    return sample.isMultiple(of: 2) ? 8_000_000 : -8_000_000
                }
                return Int32((sample * (channel + 3) * 29) % 257 - 128)
            }
        }
    }

    private static func decorrelationCoefficientTie() -> [[Int32]] {
        let zero = Array(
            repeating: Int32(0),
            count: DTSXPrivateFrameEncoder.frameSampleCount
        )
        let independent = (0..<DTSXPrivateFrameEncoder.frameSampleCount).map { sample in
            Int32((sample * 3_571) % 120_001 - 60_000)
        }
        let correlated = (0..<DTSXPrivateFrameEncoder.frameSampleCount).map { sample in
            Int32((sample * 7_123) % 180_001 - 90_000)
        }
        return [zero, independent, correlated, correlated]
    }
}
