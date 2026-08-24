import Foundation

public struct DTSXChannelAllocationImpulsePlacement: Sendable, Equatable, Codable {
    public let sourceChannel: DTS714Channel
    public let sourcePlaneIndex: Int
    public let impulseSample: Int
    public let impulseAmplitude: Int32
    public let destination: String
    public let destinationPlaneIndex: Int
    public let expectedAmplitude: Int32
    public let observedAmplitude: Int32
    public let isExactlyPlaced: Bool
}

public struct DTSXCoreSurroundFoldCheck: Sendable, Equatable, Codable {
    public let sourceChannel: DTS714Channel
    public let expectedCorePlaneIndex: Int
    public let expectedCorePlaneLabel: String
    public let dominantCorePlaneIndex: Int
    public let dominantCorePlaneLabel: String
    public let dominantEnergyFraction: Double
    public let isCorrectlyFolded: Bool
}

public struct DTSXChannelAllocationReport: Sendable, Equatable, Codable {
    public let sourceSampleCount: Int
    public let accessUnitCount: Int
    public let privateXLLXCodingMode: DTSXPrivateCodingMode
    public let bedPlaneOrder: [String]
    public let backSurroundBedPlaneIndices: [Int]
    public let placements: [DTSXChannelAllocationImpulsePlacement]
    public let allImpulsesExactlyPlaced: Bool
    public let backSurroundAllocationVerified: Bool
    public let decodedBedMismatchSampleCount: Int
    public let decodedBedTailNonzeroSampleCount: Int
    public let bedExactlyMatchesExpectation: Bool
    public let heightVerification: DTSXPrivateHeightVerificationReport
    public let heightsExactlyMatchSource: Bool
    public let compatibilityMasksVerified: Bool
    public let coreSurroundFolds: [DTSXCoreSurroundFoldCheck]
    public let coreBackSurroundFoldVerified: Bool
    public let isVerified: Bool
}

/// Closed-loop channel-allocation verification with controlled impulse
/// vectors, in the spirit of the local controlled-variable test corpus: one
/// uniquely timed, uniquely scaled impulse per DTS:X 7.1.4 input channel.
///
/// The production encoder is driven end to end and the decoded program is
/// compared against a hand-built expectation derived only from the published
/// channel contracts — WAVE 7.1 plane order (L, R, C, LFE, Lsr, Rsr, Lss,
/// Rss), the Q15 legacy height fold, and the equal-power 5.1 Core surround
/// fold — never from the renderer under test. A swapped pair (the classic
/// back-surround/side-surround transposition) therefore fails the check even
/// though a pure encode/decode loop would still close bit-exactly.
public enum DTSXChannelAllocationVerifier {
    /// WAVE 7.1 canonical order carried by the public compatibility bed.
    public static let bedPlaneLabels = ["L", "R", "C", "LFE", "Lsr", "Rsr", "Lss", "Rss"]
    /// WAVE 5.1(side) canonical order produced by the Core decoder.
    public static let corePlaneLabels = ["L", "R", "C", "LFE", "Ls", "Rs"]

    /// Destination bed plane for each directly carried 7.1 input channel.
    private static let bedDestination: [DTS714Channel: Int] = [
        .left: 0,
        .right: 1,
        .center: 2,
        .lfe: 3,
        .leftRearSurround: 4,
        .rightRearSurround: 5,
        .leftSideSurround: 6,
        .rightSideSurround: 7
    ]

    /// Bed plane receiving each height channel's legacy Q15 fold.
    private static let foldDestination: [DTS714Channel: Int] = [
        .leftFrontHeight: 0,
        .rightFrontHeight: 1,
        .leftRearHeight: 4,
        .rightRearHeight: 5
    ]

    /// Core plane receiving each surround input in the 7.1 -> 5.1 fold.
    private static let coreSurroundDestination: [DTS714Channel: Int] = [
        .leftSideSurround: 4,
        .leftRearSurround: 4,
        .rightSideSurround: 5,
        .rightRearSurround: 5
    ]

    public static func verify() throws -> DTSXChannelAllocationReport {
        let sampleCount = XLLSyntax.frameSampleCount * 3
        let channels = DTS714Channel.allCases
        var planes = Array(
            repeating: Array(repeating: Int32(0), count: sampleCount),
            count: channels.count
        )
        var impulseSamples: [Int] = []
        var impulseAmplitudes: [Int32] = []
        for index in channels.indices {
            // Every impulse is uniquely timed and uniquely scaled so any
            // transposition or gain error is attributable to one channel.
            let sample = XLLSyntax.frameSampleCount + index * 64
            let magnitude = Int32(1_000_000 + index * 250_000)
            let amplitude = index.isMultiple(of: 2) ? magnitude : -magnitude
            planes[index][sample] = amplitude
            impulseSamples.append(sample)
            impulseAmplitudes.append(amplitude)
        }
        let source = try DTS714PCMBuffer(planes: planes)

        let encoder = DTSXNativeHDMAEncoder(verificationPolicy: .integrated)
        let encoded = try encoder.encode(source: source, frameRate: .fps24)
        guard let compatibilitySafety = encoded.report.compatibilitySafety else {
            throw DTSError.malformed(
                "channel-allocation encode did not produce its compatibility safety report"
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swift-dtsx-channel-allocation-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw DTSError.io(
                "cannot create channel-allocation directory: \(error.localizedDescription)"
            )
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let streamURL = temporaryDirectory.appendingPathComponent("program.dtshd")
        do {
            try encoded.stream.write(to: streamURL, options: .atomic)
        } catch {
            throw DTSError.io(
                "cannot write channel-allocation stream: \(error.localizedDescription)"
            )
        }

        // Hand-built bed expectation from the WAVE 7.1 contract and the Q15
        // legacy height fold, independent of DTS714CompatibilityBedRenderer.
        var expectedBed = Array(
            repeating: Array(repeating: Int32(0), count: sampleCount),
            count: bedPlaneLabels.count
        )
        for (index, channel) in channels.enumerated() {
            if let bedIndex = bedDestination[channel] {
                expectedBed[bedIndex][impulseSamples[index]] = impulseAmplitudes[index]
            } else if let foldIndex = foldDestination[channel] {
                expectedBed[foldIndex][impulseSamples[index]] = legacyHeightFold(
                    impulseAmplitudes[index]
                )
            }
        }

        let decodedBed = try DTSHDMADecoder().decode(encoded.stream)
        guard decodedBed.planes.count == bedPlaneLabels.count,
              decodedBed.sampleCount >= sampleCount else {
            throw DTSError.malformed("decoded compatibility bed has an unexpected shape")
        }
        var bedMismatchSampleCount = 0
        for plane in expectedBed.indices {
            for sample in 0..<sampleCount
            where decodedBed.planes[plane][sample] != expectedBed[plane][sample] {
                bedMismatchSampleCount += 1
            }
        }
        var bedTailNonzeroSampleCount = 0
        for plane in decodedBed.planes.indices {
            for sample in sampleCount..<decodedBed.sampleCount
            where decodedBed.planes[plane][sample] != 0 {
                bedTailNonzeroSampleCount += 1
            }
        }

        let heightVerification = try DTSXPrivateHeightVerifier.verify(
            inputURL: streamURL,
            source: source
        )

        var placements: [DTSXChannelAllocationImpulsePlacement] = []
        placements.reserveCapacity(channels.count)
        for (index, channel) in channels.enumerated() {
            let destinationIndex: Int
            let destination: String
            let expectedAmplitude: Int32
            if let bedIndex = bedDestination[channel] {
                destinationIndex = bedIndex
                destination = "bed[\(bedIndex)] \(bedPlaneLabels[bedIndex])"
                expectedAmplitude = impulseAmplitudes[index]
            } else if let foldIndex = foldDestination[channel] {
                destinationIndex = foldIndex
                destination = "bed[\(foldIndex)] \(bedPlaneLabels[foldIndex]) (Q15 fold)"
                expectedAmplitude = legacyHeightFold(impulseAmplitudes[index])
            } else {
                throw DTSError.malformed("unmapped DTS:X 7.1.4 channel \(channel.rawValue)")
            }
            let observed = decodedBed.planes[destinationIndex][impulseSamples[index]]
            // Exact placement also requires that no other bed plane carries
            // anything at this impulse time.
            let leakageFree = decodedBed.planes.indices.allSatisfy { plane in
                plane == destinationIndex
                    || decodedBed.planes[plane][impulseSamples[index]]
                        == expectedBed[plane][impulseSamples[index]]
            }
            placements.append(DTSXChannelAllocationImpulsePlacement(
                sourceChannel: channel,
                sourcePlaneIndex: index,
                impulseSample: impulseSamples[index],
                impulseAmplitude: impulseAmplitudes[index],
                destination: destination,
                destinationPlaneIndex: destinationIndex,
                expectedAmplitude: expectedAmplitude,
                observedAmplitude: observed,
                isExactlyPlaced: observed == expectedAmplitude && leakageFree
            ))
        }
        let allImpulsesExactlyPlaced = placements.allSatisfy(\.isExactlyPlaced)
        let backSurroundAllocationVerified = placements.contains {
            $0.sourceChannel == .leftRearSurround
                && $0.destinationPlaneIndex == 4
                && $0.isExactlyPlaced
        } && placements.contains {
            $0.sourceChannel == .rightRearSurround
                && $0.destinationPlaneIndex == 5
                && $0.isExactlyPlaced
        }

        let coreSurroundFolds = try verifyCoreSurroundFolds(
            in: temporaryDirectory
        )
        let coreBackSurroundFoldVerified = coreSurroundFolds.count == 4
            && coreSurroundFolds.allSatisfy(\.isCorrectlyFolded)

        let bedExactlyMatchesExpectation = bedMismatchSampleCount == 0
            && bedTailNonzeroSampleCount == 0
        let verified = encoded.report.isInternallyBitExact
            && compatibilitySafety.isCompatible
            && bedExactlyMatchesExpectation
            && allImpulsesExactlyPlaced
            && backSurroundAllocationVerified
            && heightVerification.isBitExact
            && coreBackSurroundFoldVerified
        return DTSXChannelAllocationReport(
            sourceSampleCount: sampleCount,
            accessUnitCount: encoded.report.accessUnitCount,
            privateXLLXCodingMode: encoded.report.privateXLLXCodingMode,
            bedPlaneOrder: bedPlaneLabels,
            backSurroundBedPlaneIndices: [4, 5],
            placements: placements,
            allImpulsesExactlyPlaced: allImpulsesExactlyPlaced,
            backSurroundAllocationVerified: backSurroundAllocationVerified,
            decodedBedMismatchSampleCount: bedMismatchSampleCount,
            decodedBedTailNonzeroSampleCount: bedTailNonzeroSampleCount,
            bedExactlyMatchesExpectation: bedExactlyMatchesExpectation,
            heightVerification: heightVerification,
            heightsExactlyMatchSource: heightVerification.isBitExact,
            compatibilityMasksVerified: compatibilitySafety.isCompatible,
            coreSurroundFolds: coreSurroundFolds,
            coreBackSurroundFoldVerified: coreBackSurroundFoldVerified,
            isVerified: verified
        )
    }

    /// The Core is lossy, so the fold is verified by energy allocation
    /// instead of sample equality: one isolated surround impulse per encode
    /// must place essentially all decoded Core energy on the folded 5.1
    /// plane. Side and rear surrounds are exercised separately so a swapped
    /// back-surround assignment cannot hide behind its sibling.
    private static func verifyCoreSurroundFolds(
        in temporaryDirectory: URL
    ) throws -> [DTSXCoreSurroundFoldCheck] {
        let surrounds: [DTS714Channel] = [
            .leftSideSurround,
            .rightSideSurround,
            .leftRearSurround,
            .rightRearSurround
        ]
        let channels = DTS714Channel.allCases
        var checks: [DTSXCoreSurroundFoldCheck] = []
        checks.reserveCapacity(surrounds.count)
        for surround in surrounds {
            let sampleCount = XLLSyntax.frameSampleCount * 3
            var planes = Array(
                repeating: Array(repeating: Int32(0), count: sampleCount),
                count: channels.count
            )
            let planeIndex = channels.firstIndex(of: surround)!
            planes[planeIndex][XLLSyntax.frameSampleCount + 200] = 4_000_000
            let source = try DTS714PCMBuffer(planes: planes)
            let encoded = try DTSXNativeHDMAEncoder(verificationPolicy: .none)
                .encode(source: source, frameRate: .fps24)
            let streamURL = temporaryDirectory.appendingPathComponent(
                "core-fold-\(surround.rawValue).dtshd"
            )
            do {
                try encoded.stream.write(to: streamURL, options: .atomic)
            } catch {
                throw DTSError.io(
                    "cannot write Core fold stream: \(error.localizedDescription)"
                )
            }
            let core = try DTSCoreStreamDecoder.decode(inputURL: streamURL)
            var energies = [Double](repeating: 0, count: core.planes.count)
            for plane in core.planes.indices {
                for sample in core.planes[plane] {
                    let value = Double(sample)
                    energies[plane] += value * value
                }
            }
            let totalEnergy = energies.reduce(0, +)
            let dominantIndex = energies.indices.max { energies[$0] < energies[$1] }!
            let dominantFraction = totalEnergy > 0
                ? energies[dominantIndex] / totalEnergy
                : 0
            let expectedIndex = coreSurroundDestination[surround]!
            checks.append(DTSXCoreSurroundFoldCheck(
                sourceChannel: surround,
                expectedCorePlaneIndex: expectedIndex,
                expectedCorePlaneLabel: corePlaneLabels[expectedIndex],
                dominantCorePlaneIndex: dominantIndex,
                dominantCorePlaneLabel: corePlaneLabels[dominantIndex],
                dominantEnergyFraction: dominantFraction,
                isCorrectlyFolded: dominantIndex == expectedIndex
                    && dominantFraction > 0.99
                    && totalEnergy > 0
            ))
        }
        return checks
    }

    /// The observable Q15 legacy fold: round(2^15 / sqrt(2)) = 23170.
    private static func legacyHeightFold(_ height: Int32) -> Int32 {
        Int32(clamping: (Int64(height) * 23_170 + (1 << 14)) >> 15)
    }
}
