import Foundation

/// One sample carrying the longest effective Straight/Hybrid Rice unary code.
/// Hybrid-isolated samples are deliberately excluded because they are emitted
/// with the declared signed-linear width instead of the Rice code.
public struct DTSXPrivateUnaryRiskLocation: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let segmentIndex: Int
    public let parameterIndex: Int
    public let channelIndex: Int
    public let sampleOffsetInSegment: Int
    public let riceParameter: Int
    public let quotient: UInt64
    public let mappedMagnitude: UInt64
    public let isHybridRice: Bool
}

public struct DTSXPrivateUnaryRiskThreshold: Sendable, Equatable, Codable {
    public let quotient: UInt64
    public let sampleCountAtOrAbove: Int
    public let parameterApplicationCountAtOrAbove: Int
}

/// A decoder-independent safety audit of the recovered XLL-X entropy syntax.
/// It operates on the native Swift inverse and measures the exact unary values
/// read by the bitstream grammar.  The report intentionally distinguishes an
/// entropy parameter *application* from a serialized declaration: a common
/// `ncSegType=1` parameter is one application shared by all four coded planes.
public struct DTSXPrivateEntropySafetyReport: Sendable, Equatable, Codable {
    public let indexPath: String
    public let payloadPath: String
    public let frameCount: Int
    public let decodedFrameCount: Int
    public let entropySegmentCount: Int
    public let commonParameterSegmentCount: Int
    public let independentParameterSegmentCount: Int
    public let parameterApplicationCount: Int
    public let straightRiceParameterApplicationCount: Int
    public let hybridRiceParameterApplicationCount: Int
    public let activeLinearParameterApplicationCount: Int
    public let zeroLinearParameterApplicationCount: Int
    public let riceParameterEqualsMeanMagnitudeCount: Int
    public let riceParameterEqualsExactMinimumCount: Int
    public let riceCodedSampleCount: Int
    public let hybridIsolatedSampleCount: Int
    public let maximumUnaryQuotient: UInt64
    public let thresholds: [DTSXPrivateUnaryRiskThreshold]
    public let topRiskLocations: [DTSXPrivateUnaryRiskLocation]
}

/// Quantifies the long-unary condition that remains a hardware-compatibility
/// suspect after native XLL-X PCM, CRC, NAVI, and boundary checks close.
public enum DTSXPrivateEntropySafetyAnalyzer {
    private static let channelCount = 4
    private static let retainedRiskLocationCount = 64
    private static let thresholds: [UInt64] = [
        1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1_024, 4_096, 65_536
    ]

    public static func analyze(
        indexURL: URL,
        payloadURL: URL,
        outputURL: URL? = nil,
        maximumFrameCount: Int? = nil
    ) throws -> DTSXPrivateEntropySafetyReport {
        if let maximumFrameCount, maximumFrameCount <= 0 {
            throw DTSError.invalidArgument(
                "XLL-X entropy safety maximum frame count must be positive"
            )
        }
        let loaded = try DTSXPrivateArtifactLoader.load(
            indexURL: indexURL,
            payloadURL: payloadURL
        )
        let records = maximumFrameCount.map {
            Array(loaded.records.prefix($0))
        } ?? loaded.records
        var decodedFrameCount = 0
        var entropySegmentCount = 0
        var commonParameterSegmentCount = 0
        var independentParameterSegmentCount = 0
        var parameterApplicationCount = 0
        var straightRiceParameterApplicationCount = 0
        var hybridRiceParameterApplicationCount = 0
        var activeLinearParameterApplicationCount = 0
        var zeroLinearParameterApplicationCount = 0
        var riceParameterEqualsMeanMagnitudeCount = 0
        var riceParameterEqualsExactMinimumCount = 0
        var riceCodedSampleCount = 0
        var hybridIsolatedSampleCount = 0
        var maximumUnaryQuotient: UInt64 = 0
        var sampleThresholdCounts = Array(repeating: 0, count: thresholds.count)
        var applicationThresholdCounts = Array(repeating: 0, count: thresholds.count)
        var topRiskLocations: [DTSXPrivateUnaryRiskLocation] = []
        topRiskLocations.reserveCapacity(retainedRiskLocationCount)
        var leastRiskyRetainedIndex: Int?

        for record in records {
            let segmentCount = record.xllSyntax?.segmentCount ?? 2
            let segmentSampleCount = record.xllSyntax?.segmentSampleCount ?? 256
            guard segmentCount > 0,
                  segmentSampleCount > 0,
                  segmentCount * segmentSampleCount
                    == DTSXPrivateFrameEncoder.frameSampleCount else {
                throw DTSError.malformed(
                    "XLL-X frame \(record.frameIndex) has an invalid segmentation plan"
                )
            }
            let ast = try DTSXPrivateFrameAST.parse(loaded.frameBytes(record))
            let decoded = try DTSXPrivateFrameDecoder.decode(
                ast,
                segmentCount: segmentCount,
                segmentSampleCount: segmentSampleCount,
                collectEntropyDiagnostics: true
            )
            guard decoded.predictionResidualPlanes.count == channelCount,
                  decoded.predictionResidualPlanes.allSatisfy({
                      $0.count == DTSXPrivateFrameEncoder.frameSampleCount
                  }),
                  decoded.entropySegments.count == segmentCount else {
                throw DTSError.malformed(
                    "XLL-X frame \(record.frameIndex) entropy diagnostics are incomplete"
                )
            }
            decodedFrameCount += 1


            for syntax in decoded.entropySegments {
                entropySegmentCount += 1
                if syntax.commonParameters {
                    commonParameterSegmentCount += 1
                } else {
                    independentParameterSegmentCount += 1
                }
                let parameterCount = syntax.commonParameters ? 1 : channelCount
                guard syntax.riceCoding.count == channelCount,
                      syntax.hybridLinearWidths.count == channelCount,
                      syntax.partBBitAllocations.count == channelCount,
                      syntax.partASampleCounts.count == channelCount,
                      syntax.partBRicePayloadBitCounts.count == channelCount else {
                    throw DTSError.malformed(
                        "XLL-X frame \(record.frameIndex) has malformed entropy parameters"
                    )
                }

                for parameter in 0..<parameterCount {
                    parameterApplicationCount += 1
                    if !syntax.riceCoding[parameter] {
                        if syntax.partBBitAllocations[parameter] == 0 {
                            zeroLinearParameterApplicationCount += 1
                        } else {
                            activeLinearParameterApplicationCount += 1
                        }
                        continue
                    }

                    let isHybrid = syntax.hybridLinearWidths[parameter] > 0
                    if isHybrid {
                        hybridRiceParameterApplicationCount += 1
                    } else {
                        straightRiceParameterApplicationCount += 1
                    }
                    let channels = syntax.commonParameters
                        ? Array(0..<channelCount)
                        : [parameter]
                    let allocation = syntax.partBBitAllocations[parameter]
                    guard (0...31).contains(allocation) else {
                        throw DTSError.valueOutOfRange(
                            field: "XLL-X entropy safety ABIT",
                            value: String(allocation)
                        )
                    }

                    var absoluteMagnitudeSum: UInt64 = 0
                    var partBSampleCount = 0
                    var aggregateRiceCosts = Array(repeating: 0, count: 32)
                    var applicationMaximumQuotient: UInt64 = 0
                    for channel in channels {
                        let partASampleCount = syntax.partASampleCounts[parameter]
                        let segmentStart = syntax.segmentIndex * segmentSampleCount
                        let partBStart = segmentStart + partASampleCount
                        let segmentEnd = segmentStart + segmentSampleCount
                        guard partASampleCount >= 0,
                              partBStart <= segmentEnd,
                              segmentEnd <= decoded.predictionResidualPlanes[channel].count,
                              syntax.partBRicePayloadBitCounts[channel].count == 32 else {
                            throw DTSError.malformed(
                                "XLL-X frame \(record.frameIndex) part-B range is invalid"
                            )
                        }
                        for riceParameter in 0..<32 {
                            aggregateRiceCosts[riceParameter] +=
                                syntax.partBRicePayloadBitCounts[channel][riceParameter]
                        }

                        let isolatedOffsets = isHybrid
                            ? Set(syntax.hybridIsolatedSampleOffsets[channel])
                            : []
                        for sampleIndex in partBStart..<segmentEnd {
                            let sample = decoded.predictionResidualPlanes[channel][sampleIndex]
                            absoluteMagnitudeSum += UInt64(Swift.abs(Int64(sample)))
                            partBSampleCount += 1
                            let offset = sampleIndex - partBStart
                            if isolatedOffsets.contains(offset) {
                                hybridIsolatedSampleCount += 1
                                continue
                            }

                            let mapped = zigZag(sample)
                            let quotient = mapped >> UInt64(allocation)
                            riceCodedSampleCount += 1
                            maximumUnaryQuotient = max(maximumUnaryQuotient, quotient)
                            applicationMaximumQuotient = max(
                                applicationMaximumQuotient,
                                quotient
                            )
                            for thresholdIndex in thresholds.indices
                            where quotient >= thresholds[thresholdIndex] {
                                sampleThresholdCounts[thresholdIndex] += 1
                            }
                            retainRiskLocation(
                                DTSXPrivateUnaryRiskLocation(
                                    frameIndex: record.frameIndex,
                                    segmentIndex: syntax.segmentIndex,
                                    parameterIndex: parameter,
                                    channelIndex: channel,
                                    sampleOffsetInSegment: sampleIndex - segmentStart,
                                    riceParameter: allocation,
                                    quotient: quotient,
                                    mappedMagnitude: mapped,
                                    isHybridRice: isHybrid
                                ),
                                in: &topRiskLocations,
                                leastRiskyIndex: &leastRiskyRetainedIndex
                            )
                        }
                    }
                    for thresholdIndex in thresholds.indices
                    where applicationMaximumQuotient >= thresholds[thresholdIndex] {
                        applicationThresholdCounts[thresholdIndex] += 1
                    }

                    let meanMagnitudeParameter: Int
                    if partBSampleCount == 0 {
                        meanMagnitudeParameter = 0
                    } else {
                        meanMagnitudeParameter = bitWidth(
                            absoluteMagnitudeSum / UInt64(partBSampleCount)
                        )
                    }
                    if allocation == meanMagnitudeParameter {
                        riceParameterEqualsMeanMagnitudeCount += 1
                    }
                    let minimumCost = aggregateRiceCosts.min() ?? 0
                    let exactMinimumParameter = aggregateRiceCosts.firstIndex(of: minimumCost) ?? 0
                    if allocation == exactMinimumParameter {
                        riceParameterEqualsExactMinimumCount += 1
                    }
                }
            }
        }

        topRiskLocations.sort(by: riskSort)
        let report = DTSXPrivateEntropySafetyReport(
            indexPath: indexURL.standardizedFileURL.path,
            payloadPath: payloadURL.standardizedFileURL.path,
            frameCount: records.count,
            decodedFrameCount: decodedFrameCount,
            entropySegmentCount: entropySegmentCount,
            commonParameterSegmentCount: commonParameterSegmentCount,
            independentParameterSegmentCount: independentParameterSegmentCount,
            parameterApplicationCount: parameterApplicationCount,
            straightRiceParameterApplicationCount: straightRiceParameterApplicationCount,
            hybridRiceParameterApplicationCount: hybridRiceParameterApplicationCount,
            activeLinearParameterApplicationCount: activeLinearParameterApplicationCount,
            zeroLinearParameterApplicationCount: zeroLinearParameterApplicationCount,
            riceParameterEqualsMeanMagnitudeCount: riceParameterEqualsMeanMagnitudeCount,
            riceParameterEqualsExactMinimumCount: riceParameterEqualsExactMinimumCount,
            riceCodedSampleCount: riceCodedSampleCount,
            hybridIsolatedSampleCount: hybridIsolatedSampleCount,
            maximumUnaryQuotient: maximumUnaryQuotient,
            thresholds: thresholds.indices.map {
                DTSXPrivateUnaryRiskThreshold(
                    quotient: thresholds[$0],
                    sampleCountAtOrAbove: sampleThresholdCounts[$0],
                    parameterApplicationCountAtOrAbove: applicationThresholdCounts[$0]
                )
            },
            topRiskLocations: topRiskLocations
        )
        if let outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try encoder.encode(report).write(
                    to: outputURL.standardizedFileURL,
                    options: .atomic
                )
            } catch {
                throw DTSError.io(
                    "cannot write XLL-X entropy safety report: \(error.localizedDescription)"
                )
            }
        }
        return report
    }

    @inline(__always)
    private static func zigZag(_ value: Int32) -> UInt64 {
        let signed = Int64(value)
        return signed >= 0
            ? UInt64(signed) << 1
            : UInt64((-signed << 1) - 1)
    }

    @inline(__always)
    private static func bitWidth(_ value: UInt64) -> Int {
        value == 0 ? 0 : UInt64.bitWidth - value.leadingZeroBitCount
    }

    private static func retainRiskLocation(
        _ location: DTSXPrivateUnaryRiskLocation,
        in locations: inout [DTSXPrivateUnaryRiskLocation],
        leastRiskyIndex: inout Int?
    ) {
        if locations.count < retainedRiskLocationCount {
            locations.append(location)
            if locations.count == retainedRiskLocationCount {
                leastRiskyIndex = locations.indices.min(by: {
                    riskSort(locations[$1], locations[$0])
                })
            }
            return
        }
        guard let retainedIndex = leastRiskyIndex,
              riskSort(location, locations[retainedIndex]) else {
            return
        }
        locations[retainedIndex] = location
        leastRiskyIndex = locations.indices.min(by: {
            riskSort(locations[$1], locations[$0])
        })
    }

    private static func riskSort(
        _ lhs: DTSXPrivateUnaryRiskLocation,
        _ rhs: DTSXPrivateUnaryRiskLocation
    ) -> Bool {
        if lhs.quotient != rhs.quotient { return lhs.quotient > rhs.quotient }
        if lhs.frameIndex != rhs.frameIndex { return lhs.frameIndex < rhs.frameIndex }
        if lhs.segmentIndex != rhs.segmentIndex { return lhs.segmentIndex < rhs.segmentIndex }
        if lhs.channelIndex != rhs.channelIndex { return lhs.channelIndex < rhs.channelIndex }
        return lhs.sampleOffsetInSegment < rhs.sampleOffsetInSegment
    }
}
