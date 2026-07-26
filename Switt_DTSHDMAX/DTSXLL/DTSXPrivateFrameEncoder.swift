import Foundation

/// Encoder-side inverse of the recovered four-plane XLL-X frame grammar.
///
/// The native branch-zero profile uses identity plane routing, independently
/// selected fixed or adaptive prediction and per-segment signed-linear/Rice
/// entropy coding. It does not copy an oracle payload; every entropy bit is
/// produced from the supplied 512-sample height planes and is verified through
/// ``DTSXPrivateFrameDecoder`` before being returned.
public struct DTSXPrivateFrameEncoder: Sendable {
    public static let channelCount = 4
    public static let frameSampleCount = 512
    public static let segmentCount = 2
    public static let segmentSampleCount = 256
    public static let defaultSegmentationPlan = try! XLLSegmentationPlan(
        segmentCount: segmentCount,
        segmentSampleCount: segmentSampleCount
    )

    private static let predictionBoundaryByteCount = 8
    private static let bitAllocationWidth = 5
    private static let fixedHeaderBytes = Data([
        0x28, 0x4b, 0xfa, 0x71, 0x0d, 0x62, 0x02, 0xfa,
        0x02, 0xdc, 0x13, 0x71, 0x0d, 0xc8, 0x37
    ])
    private static let fixedHeaderCRC16: UInt16 = 0x3cf1

    private let allowsExperimentalHybridRice: Bool

    private enum EntropyMode: Equatable {
        case linear(width: Int)
        case rice(parameter: Int)
        case hybridRice(parameter: Int, linearWidth: Int, isolatedSampleOffsets: [Int])

        var isRice: Bool {
            switch self {
            case .linear: return false
            case .rice, .hybridRice: return true
            }
        }
    }

    private struct PredictionSelection {
        let residualPlanes: [[Int32]]
        let adaptiveOrders: [Int]
        let reflectionCoefficientIndices: [[Int32]]
        let fixedOrders: [Int]
    }

    private struct DecorrelationSelection {
        let planes: [[Int32]]
        let branchCode: Int
        let rawCoefficientCodes: [Int]
    }

    public init(allowsExperimentalHybridRice: Bool = false) {
        self.allowsExperimentalHybridRice = allowsExperimentalHybridRice
    }

    public func encode(
        codedPlanes: [[Int32]],
        routing: DTSXPrivateRouting = try! DTSXPrivateRouting(
            codedPlaneToHeightPermutation: [0, 1, 2, 3],
            branchCode: 0
        ),
        optimizePairwiseDecorrelation: Bool = false,
        segmentationPlan: XLLSegmentationPlan = Self.defaultSegmentationPlan
    ) throws -> Data {
        try validate(codedPlanes: codedPlanes, routing: routing)

        let decorrelation = optimizePairwiseDecorrelation
            ? selectPairwiseDecorrelation(codedPlanes, segmentationPlan: segmentationPlan)
            : DecorrelationSelection(
                planes: codedPlanes,
                branchCode: 0,
                rawCoefficientCodes: []
            )
        let effectiveRouting = try DTSXPrivateRouting(
            codedPlaneToHeightPermutation: routing.codedPlaneToHeightPermutation,
            branchCode: decorrelation.branchCode
        )
        let selectedPrediction = selectPrediction(
            decorrelation.planes,
            segmentationPlan: segmentationPlan
        )
        return try encodeSelected(
            codedPlanes: codedPlanes,
            effectiveRouting: effectiveRouting,
            decorrelation: decorrelation,
            selectedPrediction: selectedPrediction,
            segmentationPlan: segmentationPlan
        )
    }

    /// Reference-verification entry point. The prediction declaration must have
    /// been parsed from a qualified branch-zero official frame. Product encoding
    /// continues to select prediction independently and never reads oracle data.
    func encodeUsingQualifiedPrediction(
        codedPlanes: [[Int32]],
        routing: DTSXPrivateRouting,
        prediction: DTSXPrivatePredictionHeaderCandidate,
        navigation: DTSXPrivateNavigation?,
        segmentationPlan: XLLSegmentationPlan = Self.defaultSegmentationPlan
    ) throws -> Data {
        try validate(codedPlanes: codedPlanes, routing: routing)
        guard prediction.decorrelation.branchCode == 0,
              prediction.decorrelation.rawCoefficientCodes.isEmpty,
              prediction.matchesObservedGenericProfile else {
            throw DTSError.unsupported(
                "official XLL-X inverse verification requires a qualified branch-zero prediction"
            )
        }

        var residualPlanes: [[Int32]] = []
        var fixedOrders: [Int] = []
        residualPlanes.reserveCapacity(Self.channelCount)
        fixedOrders.reserveCapacity(Self.channelCount)
        for channel in 0..<Self.channelCount {
            let adaptiveOrder = prediction.adaptivePredictionOrders[channel]
            if adaptiveOrder > 0 {
                guard let residuals = adaptivePredictionResiduals(
                    codedPlanes[channel],
                    reflectionIndices: prediction.reflectionCoefficientSignedIndices[channel]
                ) else {
                    throw DTSError.malformed(
                        "official XLL-X adaptive prediction could not be inverted for encoding"
                    )
                }
                residualPlanes.append(residuals)
                fixedOrders.append(0)
            } else {
                let fixedOrder = prediction.fixedPredictionOrders[channel] ?? 0
                guard let residuals = fixedPredictionResiduals(
                    codedPlanes[channel],
                    order: fixedOrder
                ) else {
                    throw DTSError.malformed(
                        "official XLL-X fixed prediction could not be inverted for encoding"
                    )
                }
                residualPlanes.append(residuals)
                fixedOrders.append(fixedOrder)
            }
        }
        return try encodeSelected(
            codedPlanes: codedPlanes,
            effectiveRouting: routing,
            decorrelation: DecorrelationSelection(
                planes: codedPlanes,
                branchCode: 0,
                rawCoefficientCodes: []
            ),
            selectedPrediction: PredictionSelection(
                residualPlanes: residualPlanes,
                adaptiveOrders: prediction.adaptivePredictionOrders,
                reflectionCoefficientIndices:
                    prediction.reflectionCoefficientSignedIndices,
                fixedOrders: fixedOrders
            ),
            navigationTemplate: navigation,
            predictionBoundaryByteCount: prediction.boundaryByteOffset,
            segmentationPlan: segmentationPlan
        )
    }

    private func encodeSelected(
        codedPlanes: [[Int32]],
        effectiveRouting: DTSXPrivateRouting,
        decorrelation: DecorrelationSelection,
        selectedPrediction: PredictionSelection,
        navigationTemplate: DTSXPrivateNavigation? = nil,
        predictionBoundaryByteCount: Int? = nil,
        segmentationPlan: XLLSegmentationPlan
    ) throws -> Data {
        let isSilent = codedPlanes.allSatisfy { plane in
            plane.allSatisfy { $0 == 0 }
        }
        // The recovered compact no-NAVI suffix is specific to 2x256. Dynamic
        // 4/8-segment silence uses explicit generalized NAVI so the partition is
        // unambiguous to a decoder.
        let usesNavigation = !isSilent || segmentationPlan.segmentCount != Self.segmentCount
        let segments = try (0..<segmentationPlan.segmentCount).map {
            try encodeEntropySegment(
                residualPlanes: selectedPrediction.residualPlanes,
                adaptiveOrders: selectedPrediction.adaptiveOrders,
                segment: $0,
                segmentSampleCount: segmentationPlan.segmentSampleCount
            )
        }
        let prediction = try encodePredictionHeader(
            decorrelationRawCoefficientCodes: decorrelation.rawCoefficientCodes,
            adaptiveOrders: selectedPrediction.adaptiveOrders,
            reflectionCoefficientIndices: selectedPrediction.reflectionCoefficientIndices,
            fixedOrders: selectedPrediction.fixedOrders,
            usesNavigation: usesNavigation,
            forcedBoundaryByteCount: predictionBoundaryByteCount
        )
        var body = Data()
        body.append(prediction)
        body.append(contentsOf: [0, 0]) // prediction CRC, rebuilt below
        if usesNavigation {
            let selectedNavigation = try selectNavigation(
                predictionByteCount: prediction.count,
                segmentByteCounts: segments.map(\.count),
                preferredBitWidth: navigationTemplate?.bitWidth,
                preferredTrailingFrameByteCount:
                    navigationTemplate?.trailingFrameByteCount
            )
            body.append(try selectedNavigation.navigation.serialize())
            for segment in segments { body.append(segment) }
            body.append(contentsOf: repeatElement(
                0,
                count: selectedNavigation.trailingFrameByteCount
            ))
        } else {
            // The supplied DTS:X references use a canonical no-NAVI form for
            // all-zero private frames. The post-CRC six-bit/segment fields are
            // not arbitrary padding: this ten-byte suffix is byte-identical in
            // the official DTS:X stream and every ALL_MUTE_X test vector.
            body.append(contentsOf: [
                0x02, 0x00, 0x7b, 0x6d, 0x80,
                0x00, 0x40, 0x00, 0x00, 0x00
            ])
            guard 28 + body.count == 48 else {
                throw DTSError.malformed(
                    "XLL-X canonical no-NAVI silence did not close at 48 bytes"
                )
            }
        }

        let ast = DTSXPrivateFrameAST(
            fixedHeaderBytes: Self.fixedHeaderBytes,
            headerCRC16: Self.fixedHeaderCRC16,
            packetType: 0x02,
            reservedHighFourBits: 0,
            primarySixBitCode: UInt8(prediction.count + 7),
            separatorSixBits: 0x0f,
            secondarySyncWord: 0xef7c,
            secondaryPrefixSixBits: 0x01,
            secondaryTenBitCode: effectiveRouting.packedTenBitCode,
            body: body
        )
        let serialized = try ast.serializeRebuildingPredictionCRC()
        try verify(
            serialized,
            expectedPlanes: codedPlanes,
            expectedRouting: effectiveRouting,
            expectsNavigation: usesNavigation,
            segmentationPlan: segmentationPlan
        )
        return serialized
    }

    private func selectNavigation(
        predictionByteCount: Int,
        segmentByteCounts: [Int],
        preferredBitWidth: Int?,
        preferredTrailingFrameByteCount: Int?
    ) throws -> (
        navigation: DTSXPrivateNavigation,
        trailingFrameByteCount: Int
    ) {
        var trailingFrameByteCounts = Array(2...7)
        if let preferredTrailingFrameByteCount,
           let index = trailingFrameByteCounts.firstIndex(of: preferredTrailingFrameByteCount) {
            trailingFrameByteCounts.remove(at: index)
            trailingFrameByteCounts.insert(preferredTrailingFrameByteCount, at: 0)
        }
        for bitWidth in try navigationBitWidthCandidates(
            segmentByteCounts: segmentByteCounts,
            preferredBitWidth: preferredBitWidth
        ) {
            let navigationByteCount = (
                bitWidth * segmentByteCounts.count + 7
            ) / 8 + 2
            let fixedBodyByteCount = predictionByteCount + 2 + navigationByteCount
                + segmentByteCounts.reduce(0, +)
            for trailingFrameByteCount in trailingFrameByteCounts
            where (28 + fixedBodyByteCount + trailingFrameByteCount).isMultiple(of: 4) {
                let navigation = try DTSXPrivateNavigation(
                    bitWidth: bitWidth,
                    segmentByteCounts: segmentByteCounts,
                    trailingFrameByteCount: trailingFrameByteCount
                )
                let serialized = try navigation.serialize()
                let navigationStartByteOffset = predictionByteCount + 2
                var validationBody = Data(repeating: 0, count: navigationStartByteOffset)
                validationBody.append(serialized)
                validationBody.append(contentsOf: repeatElement(
                    0,
                    count: segmentByteCounts.reduce(0, +) + trailingFrameByteCount
                ))
                guard let parsed = try? DTSXPrivateNavigation.parse(
                    body: validationBody,
                    navigationStartByteOffset: navigationStartByteOffset,
                    segmentCount: segmentByteCounts.count
                ),
                    parsed.bitWidth == bitWidth,
                    parsed.segmentByteCounts == segmentByteCounts,
                    parsed.trailingFrameByteCount == trailingFrameByteCount else {
                    continue
                }
                return (navigation, trailingFrameByteCount)
            }
        }
        throw DTSError.malformed(
            "XLL-X native navigation has no unambiguous aligned representation "
                + "for \(segmentByteCounts.count) segments sized \(segmentByteCounts)"
        )
    }

    private func navigationBitWidthCandidates(
        segmentByteCounts: [Int],
        preferredBitWidth: Int?
    ) throws -> [Int] {
        let maximumSegmentByteCount = segmentByteCounts.max() ?? 0
        let requiredBitWidth = max(
            8,
            requiredUnsignedBitCount(maximumSegmentByteCount - 1)
        )
        guard requiredBitWidth <= 12 else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X native navigation width",
                value: String(requiredBitWidth)
            )
        }
        if let preferredBitWidth {
            guard (requiredBitWidth...12).contains(preferredBitWidth) else {
                throw DTSError.valueOutOfRange(
                    field: "XLL-X qualified navigation width",
                    value: String(preferredBitWidth)
                )
            }
            return [preferredBitWidth]
        }
        // Width is inferred from the byte-aligned NAVI payload.  Retain the
        // 11-bit canonical choice first so qualified/reference vectors remain
        // byte-identical, then try the remaining representable forms.  A form
        // is selected only after the decoder's parser accepts it uniquely.
        let canonicalBitWidth = requiredBitWidth <= 11 ? 11 : requiredBitWidth
        return [canonicalBitWidth] + (requiredBitWidth...12).filter {
            $0 != canonicalBitWidth
        }
    }

    private func validate(
        codedPlanes: [[Int32]],
        routing: DTSXPrivateRouting
    ) throws {
        guard routing.branchCode == 0 else {
            throw DTSError.unsupported(
                "the first native XLL-X encoder profile supports private branch zero only"
            )
        }
        guard codedPlanes.count == Self.channelCount,
              codedPlanes.allSatisfy({ $0.count == Self.frameSampleCount }) else {
            throw DTSError.malformed(
                "XLL-X native frame requires four 512-sample coded planes"
            )
        }
        for (channel, plane) in codedPlanes.enumerated() {
            if let invalid = plane.first(where: { $0 < -8_388_608 || $0 > 8_388_607 }) {
                throw DTSError.valueOutOfRange(
                    field: "XLL-X native coded plane[\(channel)]",
                    value: String(invalid)
                )
            }
        }
    }

    /// Searches only branch 2, whose two-pair transform has a controlled,
    /// sample-exact encode/decode vector. Branches 1 and 3 remain parser-only
    /// until equivalent encoder interoperability evidence exists.
    private func selectPairwiseDecorrelation(
        _ codedPlanes: [[Int32]],
        segmentationPlan: XLLSegmentationPlan
    ) -> DecorrelationSelection {
        let baselineScore = codedPlanes.reduce(0) {
            $0 + estimatedEntropyBitCount(
                $1,
                adaptiveOrder: 0,
                segmentationPlan: segmentationPlan
            )
        }
        var selected = DecorrelationSelection(
            planes: codedPlanes,
            branchCode: 0,
            rawCoefficientCodes: []
        )
        var selectedScore = baselineScore

        for branchCode in [2] {
            var transformed = codedPlanes
            var rawCodes: [Int] = []
            var score = 14
            var valid = true
            for pair in 0..<Self.channelCount / 2 {
                let sourceIndex = pair * 2
                let destinationIndex = sourceIndex + 1
                let source = codedPlanes[sourceIndex]
                let destination = codedPlanes[destinationIndex]
                score += estimatedEntropyBitCount(
                    source,
                    adaptiveOrder: 0,
                    segmentationPlan: segmentationPlan
                )

                guard let pairSelection = selectPairDecorrelation(
                    branchCode: branchCode,
                    pair: pair,
                    source: source,
                    destination: destination,
                    segmentationPlan: segmentationPlan
                ) else {
                    valid = false
                    break
                }
                rawCodes.append(pairSelection.rawCode)
                transformed[destinationIndex] = pairSelection.plane
                score += pairSelection.score
            }
            if valid, score < selectedScore {
                selected = DecorrelationSelection(
                    planes: transformed,
                    branchCode: branchCode,
                    rawCoefficientCodes: rawCodes
                )
                selectedScore = score
            }
        }
        guard selected.branchCode != 0 else { return selected }

        let baselinePrediction = selectPrediction(
            codedPlanes,
            segmentationPlan: segmentationPlan
        )
        let selectedPrediction = selectPrediction(
            selected.planes,
            segmentationPlan: segmentationPlan
        )
        let baselineFinalScore = predictionBitCount(
            baselinePrediction,
            segmentationPlan: segmentationPlan
        )
        let selectedFinalScore = predictionBitCount(
            selectedPrediction,
            segmentationPlan: segmentationPlan
        )
            + 14
        return selectedFinalScore < baselineFinalScore
            ? selected
            : DecorrelationSelection(
                planes: codedPlanes,
                branchCode: 0,
                rawCoefficientCodes: []
            )
    }

    private func predictionBitCount(
        _ selection: PredictionSelection,
        segmentationPlan: XLLSegmentationPlan
    ) -> Int {
        var total = 16
        for channel in selection.residualPlanes.indices {
            let adaptiveOrder = selection.adaptiveOrders[channel]
            total += estimatedEntropyBitCount(
                selection.residualPlanes[channel],
                adaptiveOrder: adaptiveOrder,
                segmentationPlan: segmentationPlan
            )
            total += adaptiveOrder == 0 ? 2 : adaptiveOrder * 8
        }
        return total
    }

    private func selectPairDecorrelation(
        branchCode: Int,
        pair: Int,
        source: [Int32],
        destination: [Int32],
        segmentationPlan: XLLSegmentationPlan
    ) -> (rawCode: Int, plane: [Int32], score: Int)? {
        guard source.count == destination.count else { return nil }
        let target = leastSquaresDecorrelationCoefficient(
            source: source,
            destination: destination
        )
        var rawByCoefficient: [Int32: Int] = [:]
        for rawCode in 0..<128 {
            let coefficient = decodedDecorrelationCoefficient(
                rawCode: rawCode,
                branchCode: branchCode,
                pair: pair
            )
            rawByCoefficient[coefficient] = min(rawByCoefficient[coefficient] ?? rawCode, rawCode)
        }
        let availableCoefficients = rawByCoefficient.keys.sorted()
        let nearby = availableCoefficients.filter { abs(Int($0) - target) <= 4 }
        let closest = availableCoefficients.min { lhs, rhs in
            let lhsDistance = abs(Int(lhs) - target)
            let rhsDistance = abs(Int(rhs) - target)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return rawByCoefficient[lhs]! < rawByCoefficient[rhs]!
        }
        var coefficientCandidates = Set(nearby)
        coefficientCandidates.insert(0)
        if let closest { coefficientCandidates.insert(closest) }

        var selected: (rawCode: Int, plane: [Int32], score: Int)?
        for coefficient in coefficientCandidates.sorted() {
            guard let rawCode = rawByCoefficient[coefficient] else { continue }
            var plane = Array(repeating: Int32(0), count: destination.count)
            var fits = true
            for sample in destination.indices {
                let delta = (Int64(source[sample]) * Int64(coefficient) + 4) >> 3
                let value = Int64(destination[sample]) - delta
                guard value >= Int64(Int32.min), value <= Int64(Int32.max) else {
                    fits = false
                    break
                }
                plane[sample] = Int32(value)
            }
            guard fits else { continue }
            let score = estimatedEntropyBitCount(
                plane,
                adaptiveOrder: 0,
                segmentationPlan: segmentationPlan
            )
            if selected == nil
                || score < selected!.score
                || (score == selected!.score && rawCode < selected!.rawCode) {
                selected = (rawCode, plane, score)
            }
        }
        return selected
    }

    private func leastSquaresDecorrelationCoefficient(
        source: [Int32],
        destination: [Int32]
    ) -> Int {
        var cross = 0.0
        var energy = 0.0
        for sample in source.indices {
            let sourceValue = Double(source[sample])
            cross += sourceValue * Double(destination[sample])
            energy += sourceValue * sourceValue
        }
        guard energy.isFinite, energy > 0, cross.isFinite else { return 0 }
        return Int((8 * cross / energy).rounded())
    }

    private func decodedDecorrelationCoefficient(
        rawCode: Int,
        branchCode: Int,
        pair: Int
    ) -> Int32 {
        let coefficientCode = rawCode >> 1
        if branchCode == 1 || (branchCode == 3 && pair == 1) {
            return Int32((rawCode & 1) == 0 ? coefficientCode : -coefficientCode - 1)
        }
        if (rawCode & 1) == 0 { return Int32(coefficientCode) }
        let extensionBit = (branchCode >> pair) & 1
        let extendedCode = (extensionBit << 6) | coefficientCode
        let magnitude = extendedCode >> 1
        return Int32((extendedCode & 1) == 0 ? magnitude : -magnitude - 1)
    }

    private func encodePredictionHeader(
        decorrelationRawCoefficientCodes: [Int],
        adaptiveOrders: [Int],
        reflectionCoefficientIndices: [[Int32]],
        fixedOrders: [Int],
        usesNavigation: Bool,
        forcedBoundaryByteCount: Int?
    ) throws -> Data {
        guard decorrelationRawCoefficientCodes.count == 0
                || decorrelationRawCoefficientCodes.count == 1
                || decorrelationRawCoefficientCodes.count == 2,
              decorrelationRawCoefficientCodes.allSatisfy({ (0..<128).contains($0) }),
              adaptiveOrders.count == Self.channelCount,
              reflectionCoefficientIndices.count == Self.channelCount,
              fixedOrders.count == Self.channelCount,
              adaptiveOrders.allSatisfy({ (0...10).contains($0) }),
              reflectionCoefficientIndices.enumerated().allSatisfy({
                  $0.element.count == adaptiveOrders[$0.offset]
              }),
              fixedOrders.allSatisfy({ (0...3).contains($0) }) else {
            throw DTSError.malformed(
                "XLL-X prediction order or reflection coefficient is invalid"
            )
        }
        var writer = BitWriter(reservingCapacity: 128)
        for pair in decorrelationRawCoefficientCodes.indices {
            try writer.write(
                UInt64(decorrelationRawCoefficientCodes[pair]),
                bitCount: 7,
                field: "XLL-X pair decorrelation coefficient[\(pair)]"
            )
        }
        for channel in 0..<Self.channelCount {
            try writer.write(
                UInt64(adaptiveOrders[channel]),
                bitCount: 4,
                field: "XLL-X adaptive order[\(channel)]"
            )
        }
        for channel in 0..<Self.channelCount where adaptiveOrders[channel] == 0 {
            try writer.write(
                UInt64(fixedOrders[channel]),
                bitCount: 2,
                field: "XLL-X fixed order[\(channel)]"
            )
        }
        for channel in 0..<Self.channelCount {
            for (coefficient, index) in reflectionCoefficientIndices[channel].enumerated() {
                try writer.writeSignedZigZag(
                    index,
                    bitCount: 8,
                    field: "XLL-X reflection index[\(channel)][\(coefficient)]"
                )
            }
        }
        let syntaxByteCount = (writer.bitCount + 7) / 8
        let defaultBoundaryByteCount = usesNavigation
            ? syntaxByteCount + 6
            : max(Self.predictionBoundaryByteCount, syntaxByteCount)
        let boundaryByteCount = forcedBoundaryByteCount ?? defaultBoundaryByteCount
        guard boundaryByteCount >= syntaxByteCount else {
            throw DTSError.malformed(
                "XLL-X prediction fields exceed the selected boundary"
            )
        }
        guard boundaryByteCount <= 56 else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X prediction header byte count",
                value: String(boundaryByteCount)
            )
        }
        let targetBitCount = boundaryByteCount * 8
        while writer.bitCount < targetBitCount {
            let width = min(64, targetBitCount - writer.bitCount)
            try writer.write(0, bitCount: width, field: "XLL-X prediction padding")
        }
        guard writer.bitCount == targetBitCount,
              writer.byteCount == boundaryByteCount else {
            throw DTSError.malformed("XLL-X prediction header did not close")
        }
        return writer.data()
    }

    private func encodeEntropySegment(
        residualPlanes: [[Int32]],
        adaptiveOrders: [Int],
        segment: Int,
        segmentSampleCount: Int
    ) throws -> Data {
        let start = segment * segmentSampleCount
        let end = start + segmentSampleCount
        let modes = residualPlanes.enumerated().map { channel, plane in
            let partASampleCount = segment == 0 ? adaptiveOrders[channel] : 0
            return selectEntropyMode(
                plane[(start + partASampleCount)..<end],
                initializationSamples: plane[start..<(start + partASampleCount)]
            )
        }
        let partAModes = residualPlanes.enumerated().map { channel, plane in
            entropyMode(
                matching: modes[channel],
                samples: plane[start..<(start + (segment == 0 ? adaptiveOrders[channel] : 0))]
            )
        }
        var writer = BitWriter(
            reservingCapacity: max(
                64,
                Self.channelCount * segmentSampleCount * 3 + 128
            )
        )

        if segment > 0 {
            try writer.write(0, bitCount: 1, field: "XLL-X bUseSegStateCodeParm[\(segment)]")
        }
        try writer.write(0, bitCount: 1, field: "XLL-X ncSegType[\(segment)]")
        for channel in 0..<Self.channelCount {
            switch modes[channel] {
            case .linear:
                try writer.write(
                    0,
                    bitCount: 1,
                    field: "XLL-X bRiceCodeFlag[\(segment)][\(channel)]"
                )
            case .rice:
                try writer.write(
                    1,
                    bitCount: 1,
                    field: "XLL-X bRiceCodeFlag[\(segment)][\(channel)]"
                )
                try writer.write(
                    0,
                    bitCount: 1,
                    field: "XLL-X bHybridRiceCode[\(segment)][\(channel)]"
                )
            case .hybridRice(_, let linearWidth, _):
                try writer.write(
                    1,
                    bitCount: 1,
                    field: "XLL-X bRiceCodeFlag[\(segment)][\(channel)]"
                )
                try writer.write(
                    1,
                    bitCount: 1,
                    field: "XLL-X bHybridRiceCode[\(segment)][\(channel)]"
                )
                try writer.write(
                    UInt64(linearWidth - 1),
                    bitCount: Self.bitAllocationWidth,
                    field: "XLL-X nHybridLinearWidth[\(segment)][\(channel)]"
                )
            }
        }
        for channel in 0..<Self.channelCount {
            if segment == 0 {
                try writeEntropyAllocation(
                    partAModes[channel],
                    to: &writer,
                    field: "XLL-X ABIT0[\(channel)]"
                )
            }
            try writeEntropyAllocation(
                modes[channel],
                to: &writer,
                field: "XLL-X ABIT[\(segment)][\(channel)]"
            )
        }
        for channel in 0..<Self.channelCount {
            let partASampleCount = segment == 0 ? adaptiveOrders[channel] : 0
            for sample in start..<(start + partASampleCount) {
                try writeEntropySample(
                    residualPlanes[channel][sample],
                    mode: partAModes[channel],
                    writer: &writer,
                    field: "XLL-X part A sample[\(segment)][\(channel)][\(sample - start)]"
                )
            }
            let partBStart = start + partASampleCount
            switch modes[channel] {
            case .linear, .rice:
                for sample in partBStart..<end {
                    try writeEntropySample(
                        residualPlanes[channel][sample],
                        mode: modes[channel],
                        writer: &writer,
                        field: "XLL-X part B sample[\(segment)][\(channel)][\(sample - partBStart)]"
                    )
                }
            case .hybridRice(let parameter, let linearWidth, let isolatedSampleOffsets):
                guard isolatedSampleOffsets.count <= Int(UInt8.max),
                      isolatedSampleOffsets == isolatedSampleOffsets.sorted(),
                      isolatedSampleOffsets.allSatisfy({
                          (0..<(end - partBStart)).contains($0)
                      }) else {
                    throw DTSError.malformed("XLL-X Hybrid Rice locations are invalid")
                }
                try writer.write(
                    UInt64(isolatedSampleOffsets.count),
                    bitCount: 8,
                    field: "XLL-X nIsolatedSamples[\(segment)][\(channel)]"
                )
                for offset in isolatedSampleOffsets {
                    try writer.write(
                        UInt64(offset),
                        bitCount: 8,
                        field: "XLL-X nIsolatedSampleLocation[\(segment)][\(channel)]"
                    )
                }
                var isolatedIndex = 0
                for sample in partBStart..<end {
                    let offset = sample - partBStart
                    if isolatedIndex < isolatedSampleOffsets.count,
                       isolatedSampleOffsets[isolatedIndex] == offset {
                        try writer.writeSignedZigZag(
                            residualPlanes[channel][sample],
                            bitCount: linearWidth,
                            field: "XLL-X Hybrid Rice linear sample[\(segment)][\(channel)][\(offset)]"
                        )
                        isolatedIndex += 1
                    } else {
                        try writeRice(
                            residualPlanes[channel][sample],
                            parameter: parameter,
                            writer: &writer,
                            field: "XLL-X Hybrid Rice sample[\(segment)][\(channel)][\(offset)]"
                        )
                    }
                }
            }
        }
        writer.alignToByte()
        return writer.data()
    }

    private func selectPrediction(
        _ codedPlanes: [[Int32]],
        segmentationPlan: XLLSegmentationPlan
    ) -> PredictionSelection {
        var residualPlanes: [[Int32]] = []
        var adaptiveOrders: [Int] = []
        var reflectionIndices: [[Int32]] = []
        var fixedOrders: [Int] = []
        residualPlanes.reserveCapacity(codedPlanes.count)
        adaptiveOrders.reserveCapacity(codedPlanes.count)
        reflectionIndices.reserveCapacity(codedPlanes.count)
        fixedOrders.reserveCapacity(codedPlanes.count)

        for plane in codedPlanes {
            var bestPlane = plane
            var bestFixedOrder = 0
            var bestAdaptiveOrder = 0
            var bestReflectionIndices: [Int32] = []
            var bestBitCount = estimatedEntropyBitCount(
                plane,
                adaptiveOrder: 0,
                segmentationPlan: segmentationPlan
            ) + 2
            for order in 1...3 {
                guard let candidate = fixedPredictionResiduals(plane, order: order) else {
                    continue
                }
                let bitCount = estimatedEntropyBitCount(
                    candidate,
                    adaptiveOrder: 0,
                    segmentationPlan: segmentationPlan
                ) + 2
                if bitCount < bestBitCount {
                    bestPlane = candidate
                    bestFixedOrder = order
                    bestAdaptiveOrder = 0
                    bestReflectionIndices = []
                    bestBitCount = bitCount
                }
            }
            if let candidates = levinsonReflectionCandidates(plane) {
                for (offset, indices) in candidates.enumerated() {
                    let order = offset + 1
                    guard let candidate = adaptivePredictionResiduals(
                        plane,
                        reflectionIndices: indices
                    ) else { continue }
                    let bitCount = estimatedEntropyBitCount(
                        candidate,
                        adaptiveOrder: order,
                        segmentationPlan: segmentationPlan
                    ) + indices.count * 8
                    if bitCount < bestBitCount {
                        bestPlane = candidate
                        bestFixedOrder = 0
                        bestAdaptiveOrder = order
                        bestReflectionIndices = indices
                        bestBitCount = bitCount
                    }
                }
            }
            residualPlanes.append(bestPlane)
            adaptiveOrders.append(bestAdaptiveOrder)
            reflectionIndices.append(bestReflectionIndices)
            fixedOrders.append(bestFixedOrder)
        }
        return PredictionSelection(
            residualPlanes: residualPlanes,
            adaptiveOrders: adaptiveOrders,
            reflectionCoefficientIndices: reflectionIndices,
            fixedOrders: fixedOrders
        )
    }

    private func levinsonReflectionCandidates(_ plane: [Int32]) -> [[Int32]]? {
        let maximumOrder = min(10, plane.count - 1)
        guard maximumOrder > 0 else { return nil }

        var autocorrelation = Array(repeating: 0.0, count: maximumOrder + 1)
        for lag in 0...maximumOrder {
            var sum = 0.0
            for sample in lag..<plane.count {
                sum += Double(plane[sample]) * Double(plane[sample - lag])
            }
            autocorrelation[lag] = sum
        }
        guard autocorrelation[0].isFinite, autocorrelation[0] > 0 else { return nil }

        var direct = [1.0]
        var error = autocorrelation[0]
        var quantized: [Int32] = []
        var candidates: [[Int32]] = []
        candidates.reserveCapacity(maximumOrder)
        for order in 1...maximumOrder {
            var numerator = autocorrelation[order]
            if order > 1 {
                for coefficient in 1..<order {
                    numerator += direct[coefficient] * autocorrelation[order - coefficient]
                }
            }
            guard error.isFinite, error > 0 else { break }
            let reflection = -numerator / error
            guard reflection.isFinite, abs(reflection) < 1 else { break }
            quantized.append(quantizedReflectionIndex(reflection))
            candidates.append(quantized)

            var updated = Array(repeating: 0.0, count: order + 1)
            updated[0] = 1
            if order > 1 {
                for coefficient in 1..<order {
                    updated[coefficient] = direct[coefficient]
                        + reflection * direct[order - coefficient]
                }
            }
            updated[order] = reflection
            direct = updated
            error *= max(1e-12, 1 - reflection * reflection)
        }
        return candidates.isEmpty ? nil : candidates
    }

    private func quantizedReflectionIndex(_ coefficient: Double) -> Int32 {
        let maximum = Double(XLLSyntax.reflectionCoefficients.last ?? 0) / 65_536.0
        let target = min(maximum, abs(coefficient)) * 65_536.0
        var low = 0
        var high = XLLSyntax.reflectionCoefficients.count - 1
        while low < high {
            let middle = (low + high) / 2
            if Double(XLLSyntax.reflectionCoefficients[middle]) < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let upper = low
        let lower = max(0, upper - 1)
        let magnitude = abs(Double(XLLSyntax.reflectionCoefficients[upper]) - target)
            < abs(Double(XLLSyntax.reflectionCoefficients[lower]) - target)
            ? upper : lower
        return coefficient < 0 ? -Int32(magnitude) : Int32(magnitude)
    }

    private func adaptivePredictionResiduals(
        _ plane: [Int32],
        reflectionIndices: [Int32]
    ) -> [Int32]? {
        let order = reflectionIndices.count
        guard order > 0,
              order <= 10,
              plane.count > order,
              reflectionIndices.allSatisfy({
                  let magnitude = Int(abs($0))
                  return $0 != -128 && XLLSyntax.reflectionCoefficients.indices.contains(magnitude)
              }) else {
            return nil
        }

        let direct = directPredictionCoefficients(reflectionIndices)
        var residuals = plane
        for sample in order..<plane.count {
            var accumulator: Int64 = 0
            for coefficient in 0..<order {
                accumulator += Int64(plane[sample - order + coefficient])
                    * Int64(direct[order - coefficient - 1])
            }
            let prediction = clip24(roundShift(accumulator, by: 16))
            residuals[sample] = plane[sample] &+ prediction
        }
        return residuals
    }

    private func directPredictionCoefficients(_ indices: [Int32]) -> [Int32] {
        var direct = Array(repeating: Int32(0), count: indices.count)
        for index in indices.indices {
            let signedIndex = indices[index]
            let raw = Int32(XLLSyntax.reflectionCoefficients[Int(abs(signedIndex))])
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
        return direct
    }

    @inline(__always)
    private func multiplyQ16(_ first: Int32, _ second: Int32) -> Int32 {
        Int32(truncatingIfNeeded: roundShift(Int64(first) * Int64(second), by: 16))
    }

    @inline(__always)
    private func roundShift(_ value: Int64, by shift: Int) -> Int64 {
        shift > 0 ? (value + (Int64(1) << (shift - 1))) >> shift : value
    }

    @inline(__always)
    private func clip24(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }

    private func fixedPredictionResiduals(_ plane: [Int32], order: Int) -> [Int32]? {
        guard (0...3).contains(order) else { return nil }
        var residuals = plane
        for _ in 0..<order {
            var differenced = residuals
            for sample in residuals.indices.dropFirst() {
                let value = Int64(residuals[sample]) - Int64(residuals[sample - 1])
                guard value >= Int64(Int32.min), value <= Int64(Int32.max) else {
                    return nil
                }
                differenced[sample] = Int32(value)
            }
            residuals = differenced
        }
        return residuals
    }

    private func estimatedEntropyBitCount(
        _ plane: [Int32],
        adaptiveOrder: Int,
        segmentationPlan: XLLSegmentationPlan
    ) -> Int {
        var total = 0
        for segment in 0..<segmentationPlan.segmentCount {
            let start = segment * segmentationPlan.segmentSampleCount
            let end = start + segmentationPlan.segmentSampleCount
            let partASampleCount = segment == 0 ? adaptiveOrder : 0
            let mode = selectEntropyMode(
                plane[(start + partASampleCount)..<end],
                initializationSamples: plane[start..<(start + partASampleCount)]
            )
            let modeBits = entropyPayloadBitCount(
                plane[(start + partASampleCount)..<end],
                mode: mode
            )
            let partAMode = entropyMode(
                matching: mode,
                samples: plane[start..<(start + partASampleCount)]
            )
            let partABits = entropyPayloadBitCount(
                plane[start..<(start + partASampleCount)],
                mode: partAMode
            )
            // Rice modes carry bHybridRiceCode. Hybrid-specific width, count,
            // and location fields are included by entropyPayloadBitCount.
            total += modeBits + partABits + (mode.isRice ? 1 : 0)
        }
        return total
    }

    private func selectEntropyMode(
        _ samples: ArraySlice<Int32>,
        initializationSamples: ArraySlice<Int32>
    ) -> EntropyMode {
        let linearWidth = minimumLinearWidth(samples)
        var selected = EntropyMode.linear(width: linearWidth)
        let linearInitializationMode = entropyMode(
            matching: selected,
            samples: initializationSamples
        )
        var selectedBitCount = entropyPayloadBitCount(samples, mode: selected)
            + entropyPayloadBitCount(
                initializationSamples,
                mode: linearInitializationMode
            )

        // Controlled official frames estimate ABIT from mean magnitude. The
        // estimate usually equals an exhaustive Rice minimum, but its boundary
        // cases are observable and must remain deterministic for byte parity.
        let parameter = initialRiceParameter(samples)
        let rice = EntropyMode.rice(parameter: parameter)
        let riceInitializationMode = entropyMode(
            matching: rice,
            samples: initializationSamples
        )
        let riceBitCount = 1 // bHybridRiceCode
            + entropyPayloadBitCount(samples, mode: rice)
            + entropyPayloadBitCount(
                initializationSamples,
                mode: riceInitializationMode
            )
        if riceBitCount < selectedBitCount {
            selected = rice
            selectedBitCount = riceBitCount
        }

        if allowsExperimentalHybridRice,
           let hybrid = selectHybridRiceMode(samples, parameter: parameter) {
            let hybridInitializationMode = entropyMode(
                matching: hybrid.mode,
                samples: initializationSamples
            )
            let hybridBitCount = hybrid.bitCount
                + entropyPayloadBitCount(
                    initializationSamples,
                    mode: hybridInitializationMode
                )
            if hybridBitCount < selectedBitCount {
                selected = hybrid.mode
            }
        }
        return selected
    }

    private func entropyMode(
        matching mode: EntropyMode,
        samples: ArraySlice<Int32>
    ) -> EntropyMode {
        guard !samples.isEmpty else {
            switch mode {
            case .linear: return .linear(width: 0)
            case .rice, .hybridRice: return .rice(parameter: 0)
            }
        }
        switch mode {
        case .linear:
            return .linear(width: minimumLinearWidth(samples))
        case .rice, .hybridRice:
            return .rice(parameter: initialRiceParameter(samples))
        }
    }

    /// ABIT0 describes the predictor initialization values. Controlled oracle
    /// frames select the bit width of their mean absolute magnitude rather than
    /// minimizing this very short prefix as an independent Rice block.
    private func initialRiceParameter(_ samples: ArraySlice<Int32>) -> Int {
        guard !samples.isEmpty else { return 0 }
        var magnitudeSum: UInt64 = 0
        for sample in samples {
            magnitudeSum += UInt64(Swift.abs(Int64(sample)))
        }
        let meanMagnitude = magnitudeSum / UInt64(samples.count)
        guard meanMagnitude > 0 else { return 0 }
        return min(31, UInt64.bitWidth - meanMagnitude.leadingZeroBitCount)
    }

    private func entropyPayloadBitCount(
        _ samples: ArraySlice<Int32>,
        mode: EntropyMode
    ) -> Int {
        switch mode {
        case .linear(let width):
            return width * samples.count
        case .rice(let parameter):
            return samples.reduce(0) { total, sample in
                let mapped = zigZag(sample)
                return total + Int(mapped >> UInt64(parameter)) + 1 + parameter
            }
        case .hybridRice(let parameter, let linearWidth, let isolatedSampleOffsets):
            var isolatedIndex = 0
            var bits = Self.bitAllocationWidth + 8 + isolatedSampleOffsets.count * 8
            for (offset, sample) in samples.enumerated() {
                if isolatedIndex < isolatedSampleOffsets.count,
                   isolatedSampleOffsets[isolatedIndex] == offset {
                    bits += linearWidth
                    isolatedIndex += 1
                } else {
                    let mapped = zigZag(sample)
                    bits += Int(mapped >> UInt64(parameter)) + 1 + parameter
                }
            }
            return bits
        }
    }

    private func selectHybridRiceMode(
        _ samples: ArraySlice<Int32>,
        parameter: Int
    ) -> (mode: EntropyMode, bitCount: Int)? {
        guard !samples.isEmpty else { return nil }

        var riceBitCounts: [Int] = []
        var requiredWidths: [Int] = []
        riceBitCounts.reserveCapacity(samples.count)
        requiredWidths.reserveCapacity(samples.count)
        var riceTotal = 0
        var countDelta = Array(repeating: 0, count: 34)
        var sumDelta = Array(repeating: 0, count: 34)

        for sample in samples {
            let mapped = zigZag(sample)
            let riceBits = Int(mapped >> UInt64(parameter)) + 1 + parameter
            let requiredWidth = max(1, 64 - mapped.leadingZeroBitCount)
            riceBitCounts.append(riceBits)
            requiredWidths.append(requiredWidth)
            riceTotal += riceBits

            // Replacing one Rice value costs its linear width plus an 8-bit
            // location. Add it to every width for which that replacement saves
            // at least one bit and the value remains representable.
            let lowerWidth = requiredWidth
            let upperWidth = min(32, riceBits - 9)
            if lowerWidth <= upperWidth {
                countDelta[lowerWidth] += 1
                countDelta[upperWidth + 1] -= 1
                sumDelta[lowerWidth] += riceBits
                sumDelta[upperWidth + 1] -= riceBits
            }
        }

        var activeCount = 0
        var activeRiceBitSum = 0
        var best: (width: Int, bitCount: Int)?
        for width in 1...32 {
            activeCount += countDelta[width]
            activeRiceBitSum += sumDelta[width]
            guard activeCount > 0 else { continue }

            var selectedCount = activeCount
            var saving = activeRiceBitSum - activeCount * (width + 8)
            if selectedCount > Int(UInt8.max) {
                var smallestSaving = Int.max
                for index in riceBitCounts.indices
                where requiredWidths[index] <= width && riceBitCounts[index] > width + 8 {
                    smallestSaving = min(
                        smallestSaving,
                        riceBitCounts[index] - width - 8
                    )
                }
                saving -= smallestSaving
                selectedCount = Int(UInt8.max)
            }
            guard selectedCount > 0, saving > 0 else { continue }

            // Five bits declare the linear width and eight bits declare the
            // isolated-sample count. Per-location overhead is already included
            // in saving above. bHybridRiceCode is counted by the caller.
            let candidateBitCount = riceTotal - saving
                + Self.bitAllocationWidth + 8
            if best == nil
                || candidateBitCount < best!.bitCount
                || (candidateBitCount == best!.bitCount && width < best!.width) {
                best = (width, candidateBitCount)
            }
        }
        guard let best else { return nil }

        var offsets = riceBitCounts.indices.filter {
            requiredWidths[$0] <= best.width
                && riceBitCounts[$0] > best.width + 8
        }
        if offsets.count > Int(UInt8.max) {
            let omitted = offsets.min { lhs, rhs in
                if riceBitCounts[lhs] != riceBitCounts[rhs] {
                    return riceBitCounts[lhs] < riceBitCounts[rhs]
                }
                return lhs > rhs
            }!
            offsets.removeAll { $0 == omitted }
        }
        return (
            .hybridRice(
                parameter: parameter,
                linearWidth: best.width,
                isolatedSampleOffsets: offsets
            ),
            best.bitCount + 1
        )
    }

    @inline(__always)
    private func writeRice(
        _ value: Int32,
        parameter: Int,
        writer: inout BitWriter,
        field: @autoclosure () -> String
    ) throws {
        guard (0...31).contains(parameter) else {
            throw DTSError.valueOutOfRange(
                field: "\(field()).parameter",
                value: String(parameter)
            )
        }
        let mapped = zigZag(value)
        let quotient = mapped >> UInt64(parameter)
        guard quotient <= UInt64(Int.max) else {
            throw DTSError.valueOutOfRange(
                field: "\(field()).quotient",
                value: String(quotient)
            )
        }
        try writer.writeUnary(Int(quotient), field: "\(field()).unary")
        if parameter > 0 {
            let mask = (UInt64(1) << UInt64(parameter)) - 1
            try writer.write(
                mapped & mask,
                bitCount: parameter,
                field: "\(field()).remainder"
            )
        }
    }

    @inline(__always)
    private func writeEntropyAllocation(
        _ mode: EntropyMode,
        to writer: inout BitWriter,
        field: @autoclosure () -> String
    ) throws {
        let allocation: Int
        switch mode {
        case .linear(let width):
            allocation = width == 0 ? 0 : width - 1
        case .rice(let parameter), .hybridRice(let parameter, _, _):
            allocation = parameter
        }
        try writer.write(
            UInt64(allocation),
            bitCount: Self.bitAllocationWidth,
            field: field()
        )
    }

    @inline(__always)
    private func writeEntropySample(
        _ sample: Int32,
        mode: EntropyMode,
        writer: inout BitWriter,
        field: @autoclosure () -> String
    ) throws {
        switch mode {
        case .linear(let width):
            if width > 0 {
                try writer.writeSignedZigZag(
                    sample,
                    bitCount: width,
                    field: field()
                )
            }
        case .rice(let parameter), .hybridRice(let parameter, _, _):
            try writeRice(
                sample,
                parameter: parameter,
                writer: &writer,
                field: field()
            )
        }
    }

    private func zigZag(_ value: Int32) -> UInt64 {
        let signed = Int64(value)
        return signed >= 0
            ? UInt64(signed) << 1
            : UInt64((-signed << 1) - 1)
    }

    private func minimumLinearWidth(_ samples: ArraySlice<Int32>) -> Int {
        var maximumMapped: UInt64 = 0
        for value in samples {
            maximumMapped = max(maximumMapped, zigZag(value))
        }
        guard maximumMapped > 0 else { return 0 }
        // The recovered non-Rice allocation maps stored zero to width zero and
        // stored values 1...31 to widths 2...32; width one is not representable.
        return max(2, 64 - maximumMapped.leadingZeroBitCount)
    }

    private func requiredUnsignedBitCount(_ maximumValue: Int) -> Int {
        guard maximumValue > 0 else { return 1 }
        return Int.bitWidth - maximumValue.leadingZeroBitCount
    }

    private func verify(
        _ frame: Data,
        expectedPlanes: [[Int32]],
        expectedRouting: DTSXPrivateRouting,
        expectsNavigation: Bool,
        segmentationPlan: XLLSegmentationPlan
    ) throws {
        guard frame.count.isMultiple(of: 4) else {
            throw DTSError.malformed("XLL-X native frame is not 32-bit aligned")
        }
        let parsed = try DTSXPrivateFrameAST.parse(frame[...])
        guard parsed.headerCRCIsValid,
              try parsed.parsePredictionCRC().isValid,
              try parsed.routing == expectedRouting,
              parsed.matchesObservedStandardProfile else {
            throw DTSError.malformed("XLL-X native frame header verification failed")
        }
        if expectsNavigation {
            guard try parsed.parseNavigation(
                segmentCount: segmentationPlan.segmentCount
            ).crcIsValid else {
                throw DTSError.checksumMismatch(component: "XLL-X native navigation")
            }
        } else if (try? parsed.parseNavigation(
            segmentCount: segmentationPlan.segmentCount
        )) != nil {
            throw DTSError.malformed(
                "XLL-X canonical no-NAVI silence was misclassified as navigation"
            )
        }
        let decoded = try DTSXPrivateFrameDecoder.decode(
            parsed,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount
        )
        guard decoded.codedPlanes == expectedPlanes,
              decoded.trailingBitsAreAllZero else {
            throw DTSError.malformed("XLL-X native encoder round-trip is not sample-exact")
        }
    }
}

public struct DTSXPrivateStreamEncodingReport: Sendable, Equatable, Codable {
    public let sourceSampleCount: Int
    public let encodedSourceSampleCount: Int
    public let primingSampleCount: Int
    public let frameCount: Int
    public let minimumFrameByteCount: Int
    public let maximumFrameByteCount: Int
    public let totalByteCount: Int
    public let payloadSHA256: String
    public let decodedSampleMismatchCount: Int
    public let maximumAbsoluteInputSample: Int64
    public let maximumAbsoluteDecodedSample: Int64
    public let inputFullScaleSampleCount: Int
    public let decodedFullScaleSampleCount: Int
    public let inputSamplesOutsideSigned24Bit: Int
    public let decodedSamplesOutsideSigned24Bit: Int
    public let frameBoundaryDeltaMismatchCount: Int
    public let decoderStateResetVerified: Bool
    public let adaptivePredictionOrderHistogram: [Int]
    public let fixedPredictionOrderHistogram: [Int]
    public let adaptivePredictedPlaneCount: Int
    public let decorrelationBranchHistogram: [Int]
    public let hybridRiceParameterCount: Int
    public let hybridIsolatedSampleCount: Int
    public let parallelWorkerCount: Int
    public let isBitExact: Bool
}

public struct DTSXPrivateEncodedStream: Sendable {
    public let frames: [Data]
    public let report: DTSXPrivateStreamEncodingReport

    public var data: Data {
        var output = Data()
        output.reserveCapacity(report.totalByteCount)
        for frame in frames { output.append(frame) }
        return output
    }
}

private struct DTSXPrivateMeasuredFrame: Sendable {
        let data: Data
        let inputFirst: [Int32]
        let inputLast: [Int32]
        let decodedFirst: [Int32]
        let decodedLast: [Int32]
        let decodedSampleMismatchCount: Int
        let maximumAbsoluteInputSample: Int64
        let maximumAbsoluteDecodedSample: Int64
        let inputFullScaleSampleCount: Int
        let decodedFullScaleSampleCount: Int
        let inputSamplesOutsideSigned24Bit: Int
        let decodedSamplesOutsideSigned24Bit: Int
        let adaptivePredictionOrders: [Int]
        let fixedPredictionOrders: [Int?]
        let decorrelationBranchCode: Int
        let hybridRiceParameterCount: Int
        let hybridIsolatedSampleCount: Int
}

/// Prepared, thread-safe XLL-X source. Public XLL workers call ``encodeFrame``
/// only after their final segmentation has been selected, which makes the two
/// layers share one sample partition without serializing the entropy work.
public final class DTSXPrivateStreamEncodingSession: @unchecked Sendable {
    public let sourceSampleCount: Int
    public let encodedSourceSampleCount: Int
    public let primingFrameCount: Int
    public let frameCount: Int

    private let sourceHeightPlanes: [[Int32]]
    private let routing: DTSXPrivateRouting
    private let silent: [[Int32]]
    private var measuredFrames: [DTSXPrivateMeasuredFrame?]
    private let lock = NSLock()

    public init(
        source: DTS714PCMBuffer,
        maximumSourceFrameCount: Int? = nil
    ) throws {
        let requestedSampleCount: Int
        if let maximumSourceFrameCount {
            guard maximumSourceFrameCount > 0 else {
                throw DTSError.invalidArgument("XLL-X maximum source frame count must be positive")
            }
            let (maximumSampleCount, overflow) = maximumSourceFrameCount.multipliedReportingOverflow(
                by: DTSXPrivateFrameEncoder.frameSampleCount
            )
            guard !overflow else {
                throw DTSError.valueOutOfRange(
                    field: "XLL-X maximum source frame count",
                    value: String(maximumSourceFrameCount)
                )
            }
            requestedSampleCount = min(source.sampleCount, maximumSampleCount)
        } else {
            requestedSampleCount = source.sampleCount
        }
        guard requestedSampleCount > 0 else {
            throw DTSError.invalidArgument("XLL-X source must contain PCM samples")
        }

        sourceSampleCount = requestedSampleCount
        encodedSourceSampleCount = (
            (requestedSampleCount + DTSXPrivateFrameEncoder.frameSampleCount - 1)
                / DTSXPrivateFrameEncoder.frameSampleCount
        ) * DTSXPrivateFrameEncoder.frameSampleCount
        primingFrameCount = XLLSyntax.coreCompatiblePrimingSampleCount
            / DTSXPrivateFrameEncoder.frameSampleCount
        frameCount = primingFrameCount
            + encodedSourceSampleCount / DTSXPrivateFrameEncoder.frameSampleCount
        sourceHeightPlanes = [
            source[DTS714Channel.leftFrontHeight],
            source[DTS714Channel.rightFrontHeight],
            source[DTS714Channel.leftRearHeight],
            source[DTS714Channel.rightRearHeight]
        ]
        routing = try DTSXPrivateRouting(
            codedPlaneToHeightPermutation: [1, 0, 3, 2],
            branchCode: 0
        )
        silent = Array(
            repeating: Array(
                repeating: Int32(0),
                count: DTSXPrivateFrameEncoder.frameSampleCount
            ),
            count: DTSXPrivateFrameEncoder.channelCount
        )
        measuredFrames = Array(repeating: nil, count: frameCount)
    }

    public func encodeFrame(
        at frameIndex: Int,
        segmentationPlan: XLLSegmentationPlan
    ) throws -> Data {
        guard (0..<frameCount).contains(frameIndex) else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X frame index",
                value: String(frameIndex)
            )
        }
        let inputHeightPlanes: [[Int32]]
        let codedPlanes: [[Int32]]
        if frameIndex < primingFrameCount {
            inputHeightPlanes = silent
            codedPlanes = silent
        } else {
            let sourceStart = (frameIndex - primingFrameCount)
                * DTSXPrivateFrameEncoder.frameSampleCount
            inputHeightPlanes = sourceHeightPlanes.map { plane in
                let available = max(0, min(
                    DTSXPrivateFrameEncoder.frameSampleCount,
                    sourceSampleCount - sourceStart
                ))
                var frame = available > 0
                    ? Array(plane[sourceStart..<(sourceStart + available)])
                    : []
                if frame.count < DTSXPrivateFrameEncoder.frameSampleCount {
                    frame.append(contentsOf: repeatElement(
                        0,
                        count: DTSXPrivateFrameEncoder.frameSampleCount - frame.count
                    ))
                }
                return frame
            }
            codedPlanes = try routing.codedPlanes(fromHeightPlanes: inputHeightPlanes)
        }

        let frame = try DTSXPrivateFrameEncoder().encode(
            codedPlanes: codedPlanes,
            routing: routing,
            optimizePairwiseDecorrelation: false,
            segmentationPlan: segmentationPlan
        )
        let ast = try DTSXPrivateFrameAST.parse(frame[...])
        let prediction = try ast.parsePredictionHeaderCandidate()
        let decoded = try DTSXPrivateFrameDecoder.decode(
            ast,
            segmentCount: segmentationPlan.segmentCount,
            segmentSampleCount: segmentationPlan.segmentSampleCount
        )
        let decodedHeightPlanes = try routing.heightPlanes(
            fromCodedPlanes: decoded.codedPlanes
        )
        var maximumAbsoluteInputSample: Int64 = 0
        var maximumAbsoluteDecodedSample: Int64 = 0
        var inputFullScaleSampleCount = 0
        var decodedFullScaleSampleCount = 0
        var inputSamplesOutsideSigned24Bit = 0
        var decodedSamplesOutsideSigned24Bit = 0
        var decodedSampleMismatchCount = 0
        for channel in 0..<DTSXPrivateFrameEncoder.channelCount {
            let inputPlane = inputHeightPlanes[channel]
            let decodedPlane = decodedHeightPlanes[channel]
            for sample in 0..<DTSXPrivateFrameEncoder.frameSampleCount {
                let inputValue = Int64(inputPlane[sample])
                let decodedValue = Int64(decodedPlane[sample])
                maximumAbsoluteInputSample = max(maximumAbsoluteInputSample, abs(inputValue))
                maximumAbsoluteDecodedSample = max(maximumAbsoluteDecodedSample, abs(decodedValue))
                if inputValue == -8_388_608 || inputValue == 8_388_607 {
                    inputFullScaleSampleCount += 1
                }
                if decodedValue == -8_388_608 || decodedValue == 8_388_607 {
                    decodedFullScaleSampleCount += 1
                }
                if inputValue < -8_388_608 || inputValue > 8_388_607 {
                    inputSamplesOutsideSigned24Bit += 1
                }
                if decodedValue < -8_388_608 || decodedValue > 8_388_607 {
                    decodedSamplesOutsideSigned24Bit += 1
                }
                if decodedPlane[sample] != inputPlane[sample] {
                    decodedSampleMismatchCount += 1
                }
            }
        }
        let measured = DTSXPrivateMeasuredFrame(
            data: frame,
            inputFirst: inputHeightPlanes.map { $0[0] },
            inputLast: inputHeightPlanes.map { $0[$0.count - 1] },
            decodedFirst: decodedHeightPlanes.map { $0[0] },
            decodedLast: decodedHeightPlanes.map { $0[$0.count - 1] },
            decodedSampleMismatchCount: decodedSampleMismatchCount,
            maximumAbsoluteInputSample: maximumAbsoluteInputSample,
            maximumAbsoluteDecodedSample: maximumAbsoluteDecodedSample,
            inputFullScaleSampleCount: inputFullScaleSampleCount,
            decodedFullScaleSampleCount: decodedFullScaleSampleCount,
            inputSamplesOutsideSigned24Bit: inputSamplesOutsideSigned24Bit,
            decodedSamplesOutsideSigned24Bit: decodedSamplesOutsideSigned24Bit,
            adaptivePredictionOrders: prediction.adaptivePredictionOrders,
            fixedPredictionOrders: prediction.fixedPredictionOrders,
            decorrelationBranchCode: prediction.decorrelation.branchCode,
            hybridRiceParameterCount: decoded.hybridRiceParameterCount,
            hybridIsolatedSampleCount: decoded.hybridIsolatedSampleCount
        )
        lock.lock()
        defer { lock.unlock() }
        guard measuredFrames[frameIndex] == nil else {
            throw DTSError.malformed("XLL-X frame \(frameIndex) was encoded more than once")
        }
        measuredFrames[frameIndex] = measured
        return frame
    }

    public func finalize(parallelWorkerCount: Int) throws -> DTSXPrivateEncodedStream {
        lock.lock()
        let completed = measuredFrames
        lock.unlock()
        guard completed.allSatisfy({ $0 != nil }) else {
            throw DTSError.malformed("XLL-X encoding session did not produce every frame")
        }
        let encodedFrames = completed.compactMap { $0 }
        var frames = encodedFrames.map(\.data)
        frames.reserveCapacity(frameCount)
        var hasher = SHA256Hasher()
        var minimumFrameByteCount = Int.max
        var maximumFrameByteCount = 0
        var totalByteCount = 0
        var mismatchCount = 0
        var maximumAbsoluteInputSample: Int64 = 0
        var maximumAbsoluteDecodedSample: Int64 = 0
        var inputFullScaleSampleCount = 0
        var decodedFullScaleSampleCount = 0
        var inputSamplesOutsideSigned24Bit = 0
        var decodedSamplesOutsideSigned24Bit = 0
        var frameBoundaryDeltaMismatchCount = 0
        var adaptivePredictionOrderHistogram = Array(repeating: 0, count: 11)
        var fixedPredictionOrderHistogram = Array(repeating: 0, count: 4)
        var decorrelationBranchHistogram = Array(repeating: 0, count: 4)
        var hybridRiceParameterCount = 0
        var hybridIsolatedSampleCount = 0
        var previousInputLast: [Int32]?
        var previousDecodedLast: [Int32]?

        for encoded in encodedFrames {
            for channel in 0..<DTSXPrivateFrameEncoder.channelCount {
                if let previousInputLast, let previousDecodedLast {
                    let inputDelta = Int64(encoded.inputFirst[channel])
                        - Int64(previousInputLast[channel])
                    let decodedDelta = Int64(encoded.decodedFirst[channel])
                        - Int64(previousDecodedLast[channel])
                    if inputDelta != decodedDelta { frameBoundaryDeltaMismatchCount += 1 }
                }
            }
            previousInputLast = encoded.inputLast
            previousDecodedLast = encoded.decodedLast
            mismatchCount += encoded.decodedSampleMismatchCount
            hasher.update(encoded.data)
            minimumFrameByteCount = min(minimumFrameByteCount, encoded.data.count)
            maximumFrameByteCount = max(maximumFrameByteCount, encoded.data.count)
            totalByteCount += encoded.data.count
            maximumAbsoluteInputSample = max(
                maximumAbsoluteInputSample,
                encoded.maximumAbsoluteInputSample
            )
            maximumAbsoluteDecodedSample = max(
                maximumAbsoluteDecodedSample,
                encoded.maximumAbsoluteDecodedSample
            )
            inputFullScaleSampleCount += encoded.inputFullScaleSampleCount
            decodedFullScaleSampleCount += encoded.decodedFullScaleSampleCount
            inputSamplesOutsideSigned24Bit += encoded.inputSamplesOutsideSigned24Bit
            decodedSamplesOutsideSigned24Bit += encoded.decodedSamplesOutsideSigned24Bit
            for channel in encoded.adaptivePredictionOrders.indices {
                let adaptiveOrder = encoded.adaptivePredictionOrders[channel]
                adaptivePredictionOrderHistogram[adaptiveOrder] += 1
                if adaptiveOrder == 0,
                   let fixedOrder = encoded.fixedPredictionOrders[channel] {
                    fixedPredictionOrderHistogram[fixedOrder] += 1
                }
            }
            decorrelationBranchHistogram[encoded.decorrelationBranchCode] += 1
            hybridRiceParameterCount += encoded.hybridRiceParameterCount
            hybridIsolatedSampleCount += encoded.hybridIsolatedSampleCount
        }

        let report = DTSXPrivateStreamEncodingReport(
            sourceSampleCount: sourceSampleCount,
            encodedSourceSampleCount: encodedSourceSampleCount,
            primingSampleCount: XLLSyntax.coreCompatiblePrimingSampleCount,
            frameCount: frames.count,
            minimumFrameByteCount: minimumFrameByteCount == Int.max ? 0 : minimumFrameByteCount,
            maximumFrameByteCount: maximumFrameByteCount,
            totalByteCount: totalByteCount,
            payloadSHA256: hasher.finalizeHex(),
            decodedSampleMismatchCount: mismatchCount,
            maximumAbsoluteInputSample: maximumAbsoluteInputSample,
            maximumAbsoluteDecodedSample: maximumAbsoluteDecodedSample,
            inputFullScaleSampleCount: inputFullScaleSampleCount,
            decodedFullScaleSampleCount: decodedFullScaleSampleCount,
            inputSamplesOutsideSigned24Bit: inputSamplesOutsideSigned24Bit,
            decodedSamplesOutsideSigned24Bit: decodedSamplesOutsideSigned24Bit,
            frameBoundaryDeltaMismatchCount: frameBoundaryDeltaMismatchCount,
            decoderStateResetVerified: frameBoundaryDeltaMismatchCount == 0,
            adaptivePredictionOrderHistogram: adaptivePredictionOrderHistogram,
            fixedPredictionOrderHistogram: fixedPredictionOrderHistogram,
            adaptivePredictedPlaneCount: adaptivePredictionOrderHistogram.dropFirst().reduce(0, +),
            decorrelationBranchHistogram: decorrelationBranchHistogram,
            hybridRiceParameterCount: hybridRiceParameterCount,
            hybridIsolatedSampleCount: hybridIsolatedSampleCount,
            parallelWorkerCount: parallelWorkerCount,
            isBitExact: !frames.isEmpty
                && mismatchCount == 0
                && maximumAbsoluteInputSample <= 8_388_608
                && maximumAbsoluteDecodedSample <= 8_388_608
                && inputFullScaleSampleCount == decodedFullScaleSampleCount
                && inputSamplesOutsideSigned24Bit == 0
                && decodedSamplesOutsideSigned24Bit == 0
                && frameBoundaryDeltaMismatchCount == 0
        )
        guard report.isBitExact else {
            throw DTSError.malformed("XLL-X native stream encoder failed its decoder round-trip")
        }
        return DTSXPrivateEncodedStream(frames: frames, report: report)
    }
}

public enum DTSXPrivateStreamEncoder {

    public static func encode(
        source: DTS714PCMBuffer,
        maximumSourceFrameCount: Int? = nil,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> DTSXPrivateEncodedStream {
        let session = try DTSXPrivateStreamEncodingSession(
            source: source,
            maximumSourceFrameCount: maximumSourceFrameCount
        )
        let parallelWorkerCount = DTSParallel.workerCount(for: session.frameCount)
        _ = try DTSParallel.map(
            count: session.frameCount,
            workerCount: parallelWorkerCount,
            progress: progress
        ) { frameIndex -> Int in
            _ = try session.encodeFrame(
                at: frameIndex,
                segmentationPlan: DTSXPrivateFrameEncoder.defaultSegmentationPlan
            )
            return frameIndex
        }
        return try session.finalize(parallelWorkerCount: parallelWorkerCount)
    }
}
