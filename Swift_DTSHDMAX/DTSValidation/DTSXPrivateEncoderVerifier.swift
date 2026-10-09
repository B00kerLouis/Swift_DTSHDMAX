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
    public let terminalConservativeVectorPassed: Bool
    public let terminalBranchTwoConservativeVectorPassed: Bool
    public let terminalBranchTwoPredictiveLinearVectorPassed: Bool
    public let terminalBranchTwoRiceVectorPassed: Bool
    public let terminalPredictiveVectorPassed: Bool
    public let terminalPredictiveRiceParameterSearchPassed: Bool
    public let terminalRiceParameterSearchPassed: Bool
    public let terminalRiceMeanMagnitudeSelectionPassed: Bool
    public let terminalRiceBoundedUnarySelectionPassed: Bool
    public let terminalOfficialPredictionBoundariesPassed: Bool
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
            ("hybrid-rice-outliers-four-segments", hybridRiceOutliers(), false, fourSegments),
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
                allowsExperimentalHybridRice: name.hasPrefix("hybrid-rice-outliers")
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
        let allNavigationBitWidthsRoundTrip = navigationBitWidths
            == Array(DTSXPrivateNavigation.supportedBitWidths)
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
                && report.decorrelationCoefficientCodes == [1, 16]
        }
        let hybridReports = reports.filter {
            $0.name.hasPrefix("hybrid-rice-outliers")
        }
        let hybridRiceVectorPassed = Set(hybridReports.map(\.segmentCount)) == Set([2, 4])
            && hybridReports.allSatisfy {
                $0.isBitExact
                    && $0.hybridRiceParameterCount > 0
                    && $0.hybridIsolatedSampleCount > 0
            }
        let terminalConservativeVectorPassed = try verifyTerminalConservativeVector()
        let terminalBranchTwoConservativeVectorPassed = try verifyTerminalBranchTwoConservativeVector()
        let terminalBranchTwoPredictiveLinearVectorPassed = try verifyTerminalBranchTwoPredictiveLinearVector()
        let terminalBranchTwoRiceVectorPassed = try verifyTerminalBranchTwoRiceVector()
        let terminalPredictiveVectorPassed = try verifyTerminalPredictiveVector()
        let terminalPredictiveRiceParameterSearchPassed = try verifyTerminalPredictiveRiceParameterSearch()
        let terminalRiceParameterSearchPassed = try verifyTerminalRiceParameterSearch()
        let terminalRiceMeanMagnitudeSelectionPassed = try verifyTerminalRiceMeanMagnitudeSelection()
        let terminalRiceBoundedUnarySelectionPassed = try verifyTerminalRiceBoundedUnarySelection()
        let terminalOfficialPredictionBoundariesPassed = try verifyOfficialPredictionBoundaries()
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
            terminalConservativeVectorPassed: terminalConservativeVectorPassed,
            terminalBranchTwoConservativeVectorPassed: terminalBranchTwoConservativeVectorPassed,
            terminalBranchTwoPredictiveLinearVectorPassed: terminalBranchTwoPredictiveLinearVectorPassed,
            terminalBranchTwoRiceVectorPassed: terminalBranchTwoRiceVectorPassed,
            terminalPredictiveVectorPassed: terminalPredictiveVectorPassed,
            terminalPredictiveRiceParameterSearchPassed: terminalPredictiveRiceParameterSearchPassed,
            terminalRiceParameterSearchPassed: terminalRiceParameterSearchPassed,
            terminalRiceMeanMagnitudeSelectionPassed: terminalRiceMeanMagnitudeSelectionPassed,
            terminalRiceBoundedUnarySelectionPassed: terminalRiceBoundedUnarySelectionPassed,
            terminalOfficialPredictionBoundariesPassed: terminalOfficialPredictionBoundariesPassed,
            allVectorsBitExact: !reports.isEmpty
                && terminalOfficialPredictionBoundariesPassed
                && reports.allSatisfy(\.isBitExact)
                && allNavigationBitWidthsRoundTrip
                && adaptivePredictionVectorPassed
                && pairwiseDecorrelationVectorPassed
                && deterministicTieBreakVectorPassed
                && hybridRiceVectorPassed
                && terminalConservativeVectorPassed
                && terminalBranchTwoConservativeVectorPassed
                && terminalBranchTwoPredictiveLinearVectorPassed
                && terminalBranchTwoRiceVectorPassed
                && terminalPredictiveVectorPassed
                && terminalPredictiveRiceParameterSearchPassed
                && terminalRiceParameterSearchPassed
                && terminalRiceMeanMagnitudeSelectionPassed
                && terminalRiceBoundedUnarySelectionPassed
        )
        guard report.allVectorsBitExact else {
            let failedVectors = reports.filter { !$0.isBitExact }.map(\.name).joined(separator: ",")
            throw DTSError.malformed(
                "native XLL-X encoder conformance vectors failed: vectors=[\(failedVectors)], "
                    + "navigation=\(navigationBitWidths), "
                    + "adaptive=\(adaptivePredictionVectorPassed), "
                    + "decorrelation=\(pairwiseDecorrelationVectorPassed), "
                    + "tie=\(deterministicTieBreakVectorPassed), hybrid=\(hybridRiceVectorPassed), "
                    + "terminalConservative=\(terminalConservativeVectorPassed), "
                    + "terminalBranchTwoConservative=\(terminalBranchTwoConservativeVectorPassed), "
                    + "terminalBranchTwoPredictiveLinear=\(terminalBranchTwoPredictiveLinearVectorPassed), "
                    + "terminalBranchTwoRice=\(terminalBranchTwoRiceVectorPassed), "
                    + "terminalPredictive=\(terminalPredictiveVectorPassed), "
                    + "terminalPredictiveRiceSearch=\(terminalPredictiveRiceParameterSearchPassed), "
                    + "terminalRiceSearch=\(terminalRiceParameterSearchPassed), "
                    + "terminalRiceMean=\(terminalRiceMeanMagnitudeSelectionPassed), "
                    + "terminalRiceBounded=\(terminalRiceBoundedUnarySelectionPassed)"
            )
        }
        return report
    }

    private static func verifyNavigationBitWidths() throws -> [Int] {
        var verified: [Int] = []
        for bitWidth in DTSXPrivateNavigation.supportedBitWidths {
            // Exercise every declared width with values that cannot fit in a
            // narrower representation. This also forces the recovered
            // two-segment NAVI data area to grow beyond three bytes at 13+
            // bits, as observed in official active frames.
            let expectedCounts = [1 << bitWidth, (1 << bitWidth) - 1]
            let serialized = try DTSXPrivateNavigation(
                bitWidth: bitWidth,
                segmentByteCounts: expectedCounts,
                trailingFrameByteCount: 0
            ).serialize()
            guard DTSCRC16.checksum(serialized) == 0 else {
                continue
            }
            var body = serialized
            body.append(contentsOf: repeatElement(
                0,
                count: expectedCounts.reduce(0, +)
            ))
            let parsed = try DTSXPrivateNavigation.parse(
                body: body,
                navigationStartByteOffset: 0,
                segmentCount: expectedCounts.count
            )
            guard parsed.bitWidth == bitWidth,
                  parsed.segmentByteCounts == expectedCounts,
                  parsed.trailingFrameByteCount == 0,
                  parsed.zeroPaddingBitCount
                    == (serialized.count - 2) * 8 - bitWidth * expectedCounts.count,
                  parsed.crcIsValid,
                  try parsed.serialize() == serialized else {
                continue
            }
            verified.append(bitWidth)
        }
        return verified
    }

    private static func verifyTerminalConservativeVector() throws -> Bool {
        let input = fullScaleAlternating()
        let segmentationPlan = DTSXPrivateFrameEncoder.defaultSegmentationPlan
        let encoded = try DTSXPrivateFrameEncoder(
            codingMode: .terminalConservative
        ).encode(
            codedPlanes: input,
            segmentationPlan: segmentationPlan
        )
        let ast = try DTSXPrivateFrameAST.parse(encoded[...])
        let prediction = try ast.parsePredictionHeaderCandidate()
        let decoded = try DTSXPrivateFrameDecoder.decode(
            ast,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount
        )
        return prediction.decorrelation.branchCode == 0
            // Active terminal frames carry the explicit ten-byte prediction
            // region, but terminal delivery intentionally leaves all predictor
            // orders at zero until hardware compatibility is certified.
            && ast.primarySixBitCode == 17
            && prediction.adaptivePredictionOrders.allSatisfy { $0 == 0 }
            && prediction.fixedPredictionOrders.allSatisfy { $0 == 0 }
            && decoded.entropySegments.allSatisfy {
                $0.riceCoding.allSatisfy { !$0 }
                    && $0.hybridLinearWidths.allSatisfy { $0 == 0 }
            }
            && decoded.hybridRiceParameterCount == 0
            && decoded.hybridIsolatedSampleCount == 0
            && decoded.codedPlanes == input
    }

    private static func verifyTerminalPredictiveVector() throws -> Bool {
        let input = filteredAutoregressive()
        let segmentationPlan = DTSXPrivateFrameEncoder.defaultSegmentationPlan
        let encoded = try DTSXPrivateFrameEncoder(
            codingMode: .terminalPredictive
        ).encode(
            codedPlanes: input,
            optimizePairwiseDecorrelation: true,
            segmentationPlan: segmentationPlan
        )
        let ast = try DTSXPrivateFrameAST.parse(encoded[...])
        let prediction = try ast.parsePredictionHeaderCandidate()
        let decoded = try DTSXPrivateFrameDecoder.decode(
            ast,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount
        )
        let decodedHeightPlanes = try ast.routing.heightPlanes(
            fromCodedPlanes: decoded.codedPlanes
        )
        let routing = try ast.routing
        return prediction.decorrelation.branchCode == 0
            && routing.codedPlaneToHeightPermutation == [0, 1, 2, 3]
            && prediction.adaptivePredictionOrders.contains(where: { $0 > 0 })
            && prediction.fixedPredictionOrders.allSatisfy { ($0 ?? 0) <= 1 }
            && decoded.hybridRiceParameterCount == 0
            && decoded.hybridIsolatedSampleCount == 0
            && decodedHeightPlanes == input
    }

    private static func verifyTerminalBranchTwoConservativeVector() throws -> Bool {
        let input = correlatedPairs()
        let segmentationPlan = DTSXPrivateFrameEncoder.defaultSegmentationPlan
        let encoded = try DTSXPrivateFrameEncoder(
            codingMode: .terminalBranchTwoConservative
        ).encode(
            codedPlanes: input,
            optimizePairwiseDecorrelation: true,
            segmentationPlan: segmentationPlan
        )
        let ast = try DTSXPrivateFrameAST.parse(encoded[...])
        let prediction = try ast.parsePredictionHeaderCandidate()
        let decoded = try DTSXPrivateFrameDecoder.decode(
            ast,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount
        )
        let decodedHeightPlanes = try ast.routing.heightPlanes(
            fromCodedPlanes: decoded.codedPlanes
        )
        return prediction.decorrelation.branchCode == 2
            && prediction.decorrelation.rawCoefficientCodes.count == 2
            && prediction.decorrelation.rawCoefficientCodes[0].isMultiple(of: 2) == false
            && prediction.decorrelation.rawCoefficientCodes[1].isMultiple(of: 2)
            && prediction.adaptivePredictionOrders.allSatisfy { $0 == 0 }
            && prediction.fixedPredictionOrders.allSatisfy { $0 == 0 }
            && decoded.entropySegments.allSatisfy {
                $0.riceCoding.allSatisfy { !$0 }
                    && $0.hybridLinearWidths.allSatisfy { $0 == 0 }
            }
            && decoded.hybridRiceParameterCount == 0
            && decoded.hybridIsolatedSampleCount == 0
            && decodedHeightPlanes == input
    }

    private static func verifyTerminalBranchTwoPredictiveLinearVector() throws -> Bool {
        // Keep both variables under test observable: the paired planes force a
        // nonzero branch-two lift, while terminal predictive mode forces a
        // qualified adaptive order on every nonzero plane.
        let input = correlatedPairs()
        let segmentationPlan = DTSXPrivateFrameEncoder.defaultSegmentationPlan
        let encoded = try DTSXPrivateFrameEncoder(
            codingMode: .terminalBranchTwoPredictiveLinear
        ).encode(
            codedPlanes: input,
            optimizePairwiseDecorrelation: true,
            segmentationPlan: segmentationPlan
        )
        let ast = try DTSXPrivateFrameAST.parse(encoded[...])
        let prediction = try ast.parsePredictionHeaderCandidate()
        let decoded = try DTSXPrivateFrameDecoder.decode(
            ast,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount
        )
        let decodedHeightPlanes = try ast.routing.heightPlanes(
            fromCodedPlanes: decoded.codedPlanes
        )
        return prediction.decorrelation.branchCode == 2
            && prediction.adaptivePredictionOrders.contains(where: { $0 > 0 })
            && prediction.fixedPredictionOrders.allSatisfy { ($0 ?? 0) <= 1 }
            && decoded.entropySegments.allSatisfy {
                $0.riceCoding.allSatisfy { !$0 }
                    && $0.hybridLinearWidths.allSatisfy { $0 == 0 }
            }
            && decodedHeightPlanes == input
    }

    private static func verifyTerminalBranchTwoRiceVector() throws -> Bool {
        let input = correlatedPairs()
        let segmentationPlan = DTSXPrivateFrameEncoder.defaultSegmentationPlan
        let encoded = try DTSXPrivateFrameEncoder(
            codingMode: .terminalBranchTwoRice
        ).encode(
            codedPlanes: input,
            optimizePairwiseDecorrelation: true,
            segmentationPlan: segmentationPlan
        )
        let ast = try DTSXPrivateFrameAST.parse(encoded[...])
        let prediction = try ast.parsePredictionHeaderCandidate()
        let decoded = try DTSXPrivateFrameDecoder.decode(
            ast,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount
        )
        let decodedHeightPlanes = try ast.routing.heightPlanes(
            fromCodedPlanes: decoded.codedPlanes
        )
        return prediction.decorrelation.branchCode == 2
            && prediction.adaptivePredictionOrders.allSatisfy { $0 == 0 }
            && prediction.fixedPredictionOrders.allSatisfy { ($0 ?? 0) == 0 }
            && decoded.entropySegments.allSatisfy {
                $0.riceCoding.allSatisfy { $0 }
                    && $0.hybridLinearWidths.allSatisfy { $0 == 0 }
            }
            && decodedHeightPlanes == input
    }

    /// Predictive delivery syntax is selected locally, so every emitted Rice
    /// ABIT must minimize the exact ZigZag/unary/remainder payload rather than
    /// rely on the controlled-oracle mean-magnitude approximation.
    private static func verifyTerminalPredictiveRiceParameterSearch() throws -> Bool {
        let input = filteredAutoregressive()
        let segmentationPlan = DTSXPrivateFrameEncoder.defaultSegmentationPlan
        let encoded = try DTSXPrivateFrameEncoder(
            codingMode: .terminalPredictive
        ).encode(
            codedPlanes: input,
            segmentationPlan: segmentationPlan
        )
        let ast = try DTSXPrivateFrameAST.parse(encoded[...])
        let decoded = try DTSXPrivateFrameDecoder.decode(
            ast,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount,
            collectEntropyDiagnostics: true
        )
        guard decoded.codedPlanes == input,
              decoded.entropySegments.count == segmentationPlan.segmentCount else {
            return false
        }
        var validatedRiceParameter = false
        for segment in decoded.entropySegments {
            guard segment.partBRicePayloadBitCounts.count == DTSXPrivateFrameEncoder.channelCount else {
                return false
            }
            for channel in 0..<DTSXPrivateFrameEncoder.channelCount where segment.riceCoding[channel] {
                let costs = segment.partBRicePayloadBitCounts[channel]
                let selected = segment.partBBitAllocations[channel]
                guard costs.count == 32,
                      costs.indices.contains(selected),
                      costs[selected] == (costs.min() ?? Int.max) else {
                    return false
                }
                validatedRiceParameter = true
            }
        }
        return validatedRiceParameter
    }

    /// Ensures that the terminal Rice branch selects each parameter from the
    /// exact serialized residual payload rather than from its former
    /// mean-magnitude approximation.
    private static func verifyTerminalRiceParameterSearch() throws -> Bool {
        let input = filteredAutoregressive()
        let segmentationPlan = DTSXPrivateFrameEncoder.defaultSegmentationPlan
        let encoded = try DTSXPrivateFrameEncoder(
            codingMode: .terminalRice
        ).encode(
            codedPlanes: input,
            segmentationPlan: segmentationPlan
        )
        let ast = try DTSXPrivateFrameAST.parse(encoded[...])
        let decoded = try DTSXPrivateFrameDecoder.decode(
            ast,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount,
            collectEntropyDiagnostics: true
        )
        guard decoded.codedPlanes == input,
              decoded.entropySegments.count == segmentationPlan.segmentCount else {
            return false
        }
        for segment in decoded.entropySegments {
            guard !segment.commonParameters,
                  segment.riceCoding.allSatisfy({ $0 }),
                  segment.hybridLinearWidths.allSatisfy({ $0 == 0 }),
                  segment.partBRicePayloadBitCounts.count == DTSXPrivateFrameEncoder.channelCount else {
                return false
            }
            for channel in 0..<DTSXPrivateFrameEncoder.channelCount {
                let costs = segment.partBRicePayloadBitCounts[channel]
                let selected = segment.partBBitAllocations[channel]
                guard costs.count == 32,
                      costs.indices.contains(selected),
                      costs[selected] == (costs.min() ?? Int.max) else {
                    return false
                }
            }
        }
        return true
    }

    /// Keeps the official-corpus ABIT hypothesis separate from the existing
    /// shortest-code terminal Rice mode. Every channel remains Straight Rice,
    /// while the parameter must equal the bit width of the segment mean
    /// magnitude. The vector also proves this path is not merely aliasing the
    /// exhaustive optimum by requiring at least one non-optimal selection.
    private static func verifyTerminalRiceMeanMagnitudeSelection() throws -> Bool {
        let input = meanMagnitudeRiceBoundary()
        let segmentationPlan = DTSXPrivateFrameEncoder.defaultSegmentationPlan
        let encoded = try DTSXPrivateFrameEncoder(
            codingMode: .terminalRiceMeanMagnitude
        ).encode(
            codedPlanes: input,
            segmentationPlan: segmentationPlan
        )
        let ast = try DTSXPrivateFrameAST.parse(encoded[...])
        let decoded = try DTSXPrivateFrameDecoder.decode(
            ast,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount,
            collectEntropyDiagnostics: true
        )
        guard decoded.codedPlanes == input,
              decoded.entropySegments.count == segmentationPlan.segmentCount else {
            return false
        }
        var observedNonOptimalMeanSelection = false
        for segment in decoded.entropySegments {
            guard !segment.commonParameters,
                  segment.riceCoding.allSatisfy({ $0 }),
                  segment.hybridLinearWidths.allSatisfy({ $0 == 0 }),
                  segment.partBMeanAbsoluteMagnitudes.count
                    == DTSXPrivateFrameEncoder.channelCount,
                  segment.partBRicePayloadBitCounts.count
                    == DTSXPrivateFrameEncoder.channelCount else {
                return false
            }
            for channel in 0..<DTSXPrivateFrameEncoder.channelCount {
                let meanMagnitude = segment.partBMeanAbsoluteMagnitudes[channel]
                let expected = meanMagnitude == 0
                    ? 0
                    : min(31, Int.bitWidth - meanMagnitude.leadingZeroBitCount)
                let selected = segment.partBBitAllocations[channel]
                let costs = segment.partBRicePayloadBitCounts[channel]
                guard selected == expected,
                      costs.count == 32,
                      costs.indices.contains(selected) else {
                    return false
                }
                if costs[selected] != (costs.min() ?? Int.max) {
                    observedNonOptimalMeanSelection = true
                }
            }
        }
        return observedNonOptimalMeanSelection
    }

    /// Proves that the bounded-unary diagnostic keeps candidate 20's exact
    /// minimum search whenever safe, but raises ABIT for a sparse outlier whose
    /// optimal code would exceed the official-corpus unary maximum.
    /// Decode independently declared Part-A and Part-B allocations, including
    /// transient seeds and segment edges. A symmetric PCM loop alone would
    /// miss the bounded-reader failure caused by a long seed unary code.
    private static func verifyOfficialPredictionBoundaries() throws -> Bool {
        let encoder = DTSXPrivateFrameEncoder(codingMode: .terminalPredictiveOfficial)
        var transient = filteredAutoregressive()
        for channel in transient.indices {
            for sample in [0, 1, 9, 63, 64, 127, 128, 255, 256, 511] {
                transient[channel][sample] = sample.isMultiple(of: 2) ? 8_388_607 : -8_388_608
            }
        }
        var sawAdaptive = false
        for segments in [2, 4, 8] {
            let plan = try XLLSegmentationPlan(segmentCount: segments, segmentSampleCount: 512 / segments)
            for planes in [silence(), filteredAutoregressive(), transient, fullScaleAlternating(), impulses()] {
                let frame = try encoder.encode(codedPlanes: planes, segmentationPlan: plan, forcesNavigation: true)
                guard frame == (try encoder.encode(codedPlanes: planes, segmentationPlan: plan, forcesNavigation: true)) else {
                    return false
                }
                let ast = try DTSXPrivateFrameAST.parse(frame[...])
                let prediction = try ast.parsePredictionHeaderCandidate()
                let decoded = try DTSXPrivateFrameDecoder.decode(
                    ast, segmentCount: segments, segmentSampleCount: 512 / segments,
                    collectEntropyDiagnostics: true
                )
                sawAdaptive = sawAdaptive || prediction.adaptivePredictionOrders.contains { $0 > 0 }
                guard decoded.codedPlanes == planes, ast.headerCRCIsValid, prediction.crc.isValid,
                      !prediction.containsReservedReflectionIndex,
                      prediction.decorrelation.branchCode == 0,
                      prediction.fixedPredictionOrders.compactMap({ $0 }).allSatisfy({ $0 <= 1 }) else { return false }
                for syntax in decoded.entropySegments {
                    guard syntax.riceCoding.allSatisfy({ $0 }),
                          syntax.hybridLinearWidths.allSatisfy({ $0 == 0 }),
                          !syntax.reusesPreviousParameters else { return false }
                    for channel in planes.indices {
                        let start = syntax.segmentIndex * plan.segmentSampleCount
                        let seeds = syntax.partASampleCounts[channel]
                        for offset in 0..<plan.segmentSampleCount {
                            let sample = Int64(decoded.predictionResidualPlanes[channel][start + offset])
                            let mapped = UInt64(sample >= 0 ? sample * 2 : -sample * 2 - 1)
                            let parameter = offset < seeds
                                ? syntax.partABitAllocations[channel] : syntax.partBBitAllocations[channel]
                            guard mapped >> parameter <= 22 else { return false }
                        }
                    }
                }
            }
        }
        return sawAdaptive
    }

    private static func verifyTerminalRiceBoundedUnarySelection() throws -> Bool {
        let input = boundedUnaryRiceOutlier()
        let segmentationPlan = DTSXPrivateFrameEncoder.defaultSegmentationPlan
        let encoded = try DTSXPrivateFrameEncoder(
            codingMode: .terminalRiceBoundedUnary
        ).encode(
            codedPlanes: input,
            segmentationPlan: segmentationPlan
        )
        let ast = try DTSXPrivateFrameAST.parse(encoded[...])
        let decoded = try DTSXPrivateFrameDecoder.decode(
            ast,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount,
            collectEntropyDiagnostics: true
        )
        guard decoded.codedPlanes == input,
              decoded.predictionResidualPlanes == input,
              decoded.entropySegments.count == segmentationPlan.segmentCount else {
            return false
        }

        var observedRaisedParameter = false
        for segment in decoded.entropySegments {
            guard !segment.commonParameters,
                  segment.riceCoding.allSatisfy({ $0 }),
                  segment.hybridLinearWidths.allSatisfy({ $0 == 0 }),
                  segment.partBRicePayloadBitCounts.count
                    == DTSXPrivateFrameEncoder.channelCount else {
                return false
            }
            let start = segment.segmentIndex * segmentationPlan.segmentSampleCount
            let end = start + segmentationPlan.segmentSampleCount
            for channel in 0..<DTSXPrivateFrameEncoder.channelCount {
                let costs = segment.partBRicePayloadBitCounts[channel]
                let selected = segment.partBBitAllocations[channel]
                guard costs.count == 32,
                      costs.indices.contains(selected),
                      let exactMinimum = costs.firstIndex(of: costs.min() ?? Int.max) else {
                    return false
                }
                var maximumMapped: UInt64 = 0
                for sample in input[channel][start..<end] {
                    let signed = Int64(sample)
                    let mapped = signed >= 0
                        ? UInt64(signed) << 1
                        : UInt64((-signed << 1) - 1)
                    maximumMapped = max(maximumMapped, mapped)
                }
                guard maximumMapped >> UInt64(selected) <= 22 else {
                    return false
                }
                if selected > exactMinimum {
                    observedRaisedParameter = true
                }
            }
        }
        return observedRaisedParameter
    }

    /// Three values of 683 among 256 samples produce mean magnitude 8. The
    /// official estimator therefore selects ABIT 4, while exact serialized
    /// cost is one bit smaller at ABIT 3. Repeat the pattern in both segments
    /// and all planes so the diagnostic mode cannot pass by coincidence.
    private static func meanMagnitudeRiceBoundary() -> [[Int32]] {
        (0..<DTSXPrivateFrameEncoder.channelCount).map { _ in
            var plane = Array(
                repeating: Int32(0),
                count: DTSXPrivateFrameEncoder.frameSampleCount
            )
            for segment in 0..<DTSXPrivateFrameEncoder.segmentCount {
                let end = (segment + 1) * DTSXPrivateFrameEncoder.segmentSampleCount
                for sample in (end - 3)..<end {
                    plane[sample] = 683
                }
            }
            return plane
        }
    }

    /// One sparse value per 256-sample segment makes the minimum-bit ABIT emit
    /// a long unary run. The bounded profile must increase ABIT without moving
    /// or altering the decoded sample.
    private static func boundedUnaryRiceOutlier() -> [[Int32]] {
        (0..<DTSXPrivateFrameEncoder.channelCount).map { channel in
            var plane = Array(
                repeating: Int32(0),
                count: DTSXPrivateFrameEncoder.frameSampleCount
            )
            for segment in 0..<DTSXPrivateFrameEncoder.segmentCount {
                let start = segment * DTSXPrivateFrameEncoder.segmentSampleCount
                plane[start + channel] = 683
            }
            return plane
        }
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
