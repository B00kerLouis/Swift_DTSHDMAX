import Foundation

public struct DTSXPrivatePCMHeightChannelMetric: Sendable, Equatable, Codable {
    public let channel: DTS714Channel
    public let nonzeroSampleCount: Int
    public let absoluteSum: Int64
    public let firstDifferenceAbsoluteSum: Int64
    public let squaredEnergy: Int64
    public let firstDifferenceRiceBits: Int64
}

public struct DTSXPrivatePCMFrameMetric: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let sourceSampleStart: Int
    public let sourceSampleCount: Int
    public let payloadByteCount: Int
    public let primarySixBitCode: Int
    public let secondaryTenBitCode: Int
    public let activeHeightChannelCount: Int
    public let nonzeroHeightSampleCount: Int
    public let heightAbsoluteSum: Int64
    public let heightFirstDifferenceAbsoluteSum: Int64
    public let heightSquaredEnergy: Int64
    public let heightFirstDifferenceRiceBits: Int64
    public let allChannelFirstDifferenceRiceBits: Int64
    public let heightChannels: [DTSXPrivatePCMHeightChannelMetric]
}

public struct DTSXPrivatePCMCorrelationValue: Sendable, Equatable, Codable {
    public let leftMetric: String
    public let rightMetric: String
    public let sampleCount: Int
    public let pearsonCorrelation: Double
}

public struct DTSXPrivatePCMChannelCorrelation: Sendable, Equatable, Codable {
    public let channel: DTS714Channel
    public let payloadByteCountToRiceBits: Double
    public let primaryCodeToRiceBits: Double
}

public struct DTSXPrivatePCMLagCorrelation: Sendable, Equatable, Codable {
    /// Positive means the PCM metric is taken from a later frame than the
    /// private payload metric.
    public let sourceLagFrames: Int
    public let sampleCount: Int
    public let payloadByteCountToHeightRiceBits: Double
}

public struct DTSXPrivatePCMLinearRegression: Sendable, Equatable, Codable {
    public let independentMetric: String
    public let dependentMetric: String
    public let slope: Double
    public let intercept: Double
    public let rSquared: Double
    public let meanAbsoluteError: Double
}

public struct DTSXPrivatePCMCorrelationReport: Sendable, Equatable, Codable {
    public let indexPath: String
    public let payloadPath: String
    public let sourceDirectory: String
    public let payloadSHA256: String
    public let sourcePCM_SHA256: String
    public let frameCount: Int
    public let frameSampleCount: Int
    public let leadingPrimingSampleCount: Int
    public let sourceSampleCount: Int
    public let trailingPaddingSampleCount: Int
    public let timelineIsExactlyCovered: Bool
    public let correlations: [DTSXPrivatePCMCorrelationValue]
    public let channelCorrelations: [DTSXPrivatePCMChannelCorrelation]
    public let lagCorrelations: [DTSXPrivatePCMLagCorrelation]
    public let strongestHeightRiceLagFrames: Int
    public let heightRiceToPayloadBitRegression: DTSXPrivatePCMLinearRegression
    public let frames: [DTSXPrivatePCMFrameMetric]
}

public enum DTSXPrivatePCMCorrelator {
    private static let frameSampleCount = XLLSyntax.frameSampleCount
    private static let leadingPrimingSampleCount = XLLSyntax.coreCompatiblePrimingSampleCount

    public static func analyze(
        indexURL: URL,
        payloadURL: URL,
        sourceDirectory: URL,
        outputURL: URL
    ) throws -> DTSXPrivatePCMCorrelationReport {
        let loaded = try DTSXPrivateArtifactLoader.load(
            indexURL: indexURL,
            payloadURL: payloadURL
        )
        let source = try DTS714SourceSet.load(directory: sourceDirectory)
        let channels = DTS714Channel.allCases
        let heightIndices = Array(8..<12)
        let timelineSampleCount = loaded.records.count * frameSampleCount
        let trailingPadding = timelineSampleCount
            - leadingPrimingSampleCount
            - source.sampleCount
        guard trailingPadding >= 0 else {
            throw DTSError.truncated(field: "XLL-X PCM timeline", bitOffset: timelineSampleCount * 24)
        }

        var metrics: [DTSXPrivatePCMFrameMetric] = []
        metrics.reserveCapacity(loaded.records.count)
        var riceBitsByChannel = Array(
            repeating: [Double](),
            count: channels.count
        )
        for channel in riceBitsByChannel.indices {
            riceBitsByChannel[channel].reserveCapacity(loaded.records.count)
        }

        for (position, record) in loaded.records.enumerated() {
            guard record.frameIndex == position else {
                throw DTSError.malformed("XLL-X private frame indices are not contiguous")
            }
            if let syntax = record.xllSyntax {
                guard syntax.segmentCount * syntax.segmentSampleCount == frameSampleCount else {
                    throw DTSError.unsupported("XLL-X PCM correlation requires 512-sample XLL frames")
                }
            }
            let privateBytes = loaded.frameBytes(record)
            let ast = try DTSXPrivateFrameAST.parse(privateBytes)
            let sourceStart = position * frameSampleCount - leadingPrimingSampleCount
            let validStart = max(0, sourceStart)
            let validEnd = min(source.sampleCount, sourceStart + frameSampleCount)
            let validCount = max(0, validEnd - validStart)

            var activeHeights = 0
            var nonzeroHeights = 0
            var heightAbsoluteSum: Int64 = 0
            var heightDifferenceAbsoluteSum: Int64 = 0
            var heightSquaredEnergy: Int64 = 0
            var channelRice = Array(repeating: Int64(0), count: channels.count)
            var channelNonzero = Array(repeating: 0, count: channels.count)
            var channelAbsolute = Array(repeating: Int64(0), count: channels.count)
            var channelDifferenceAbsolute = Array(repeating: Int64(0), count: channels.count)
            var channelSquaredEnergy = Array(repeating: Int64(0), count: channels.count)

            for channel in channels.indices {
                var previous: Int64 = 0
                var riceCosts = (0..<24).map {
                    Int64(frameSampleCount * (1 + $0))
                }
                var channelHasSignal = false
                for localSample in 0..<frameSampleCount {
                    let sourceSample = sourceStart + localSample
                    let value = sourceSample >= 0 && sourceSample < source.sampleCount
                        ? Int64(source.planes[channel][sourceSample])
                        : 0
                    let residual = value - previous
                    previous = value
                    let unsignedResidual = residual < 0
                        ? UInt64((-residual << 1) - 1)
                        : UInt64(residual << 1)
                    for parameter in riceCosts.indices {
                        riceCosts[parameter] += Int64(unsignedResidual >> UInt64(parameter))
                    }
                    if heightIndices.contains(channel) {
                        if value != 0 {
                            channelHasSignal = true
                            nonzeroHeights += 1
                            channelNonzero[channel] += 1
                        }
                        heightAbsoluteSum += abs(value)
                        heightDifferenceAbsoluteSum += abs(residual)
                        heightSquaredEnergy += value * value
                        channelAbsolute[channel] += abs(value)
                        channelDifferenceAbsolute[channel] += abs(residual)
                        channelSquaredEnergy[channel] += value * value
                    }
                }
                if heightIndices.contains(channel), channelHasSignal { activeHeights += 1 }
                channelRice[channel] = riceCosts.min()!
                riceBitsByChannel[channel].append(Double(channelRice[channel]))
            }

            metrics.append(DTSXPrivatePCMFrameMetric(
                frameIndex: position,
                sourceSampleStart: sourceStart,
                sourceSampleCount: validCount,
                payloadByteCount: privateBytes.count,
                primarySixBitCode: Int(ast.primarySixBitCode),
                secondaryTenBitCode: Int(ast.secondaryTenBitCode),
                activeHeightChannelCount: activeHeights,
                nonzeroHeightSampleCount: nonzeroHeights,
                heightAbsoluteSum: heightAbsoluteSum,
                heightFirstDifferenceAbsoluteSum: heightDifferenceAbsoluteSum,
                heightSquaredEnergy: heightSquaredEnergy,
                heightFirstDifferenceRiceBits: heightIndices.reduce(0) {
                    $0 + channelRice[$1]
                },
                allChannelFirstDifferenceRiceBits: channelRice.reduce(0, +),
                heightChannels: heightIndices.map { channel in
                    DTSXPrivatePCMHeightChannelMetric(
                        channel: channels[channel],
                        nonzeroSampleCount: channelNonzero[channel],
                        absoluteSum: channelAbsolute[channel],
                        firstDifferenceAbsoluteSum: channelDifferenceAbsolute[channel],
                        squaredEnergy: channelSquaredEnergy[channel],
                        firstDifferenceRiceBits: channelRice[channel]
                    )
                }
            ))
        }

        let payloadBytes = metrics.map { Double($0.payloadByteCount) }
        let payloadBits = payloadBytes.map { $0 * 8 }
        let primaryCodes = metrics.map { Double($0.primarySixBitCode) }
        let secondaryCodes = metrics.map { Double($0.secondaryTenBitCode) }
        let heightRice = metrics.map { Double($0.heightFirstDifferenceRiceBits) }
        let allRice = metrics.map { Double($0.allChannelFirstDifferenceRiceBits) }
        let heightLogAbsolute = metrics.map { log2(Double($0.heightAbsoluteSum) + 1) }
        let heightLogDifference = metrics.map {
            log2(Double($0.heightFirstDifferenceAbsoluteSum) + 1)
        }
        let heightLogEnergy = metrics.map { log2(Double($0.heightSquaredEnergy) + 1) }
        let heightNonzero = metrics.map { Double($0.nonzeroHeightSampleCount) }
        let correlations = [
            correlation("payloadByteCount", payloadBytes, "heightFirstDifferenceRiceBits", heightRice),
            correlation("payloadByteCount", payloadBytes, "allChannelFirstDifferenceRiceBits", allRice),
            correlation("payloadByteCount", payloadBytes, "log2HeightAbsoluteSum", heightLogAbsolute),
            correlation("payloadByteCount", payloadBytes, "log2HeightFirstDifferenceAbsoluteSum", heightLogDifference),
            correlation("payloadByteCount", payloadBytes, "log2HeightSquaredEnergy", heightLogEnergy),
            correlation("payloadByteCount", payloadBytes, "nonzeroHeightSampleCount", heightNonzero),
            correlation("primarySixBitCode", primaryCodes, "heightFirstDifferenceRiceBits", heightRice),
            correlation("secondaryTenBitCode", secondaryCodes, "heightFirstDifferenceRiceBits", heightRice)
        ]
        let channelCorrelations = channels.indices.map { channel in
            DTSXPrivatePCMChannelCorrelation(
                channel: channels[channel],
                payloadByteCountToRiceBits: pearson(payloadBytes, riceBitsByChannel[channel]),
                primaryCodeToRiceBits: pearson(primaryCodes, riceBitsByChannel[channel])
            )
        }
        let lagCorrelations = (-6...6).map { lag in
            let pair = lagged(payloadBytes, heightRice, lag: lag)
            return DTSXPrivatePCMLagCorrelation(
                sourceLagFrames: lag,
                sampleCount: pair.left.count,
                payloadByteCountToHeightRiceBits: pearson(pair.left, pair.right)
            )
        }
        let strongestLag = lagCorrelations.max {
            abs($0.payloadByteCountToHeightRiceBits) < abs($1.payloadByteCountToHeightRiceBits)
        }?.sourceLagFrames ?? 0
        let report = DTSXPrivatePCMCorrelationReport(
            indexPath: indexURL.standardizedFileURL.path,
            payloadPath: payloadURL.standardizedFileURL.path,
            sourceDirectory: sourceDirectory.standardizedFileURL.path,
            payloadSHA256: SHA256Hasher.hash(loaded.payload),
            sourcePCM_SHA256: hashPCM(source.planes),
            frameCount: metrics.count,
            frameSampleCount: frameSampleCount,
            leadingPrimingSampleCount: leadingPrimingSampleCount,
            sourceSampleCount: source.sampleCount,
            trailingPaddingSampleCount: trailingPadding,
            timelineIsExactlyCovered: timelineSampleCount
                == leadingPrimingSampleCount + source.sampleCount + trailingPadding,
            correlations: correlations,
            channelCorrelations: channelCorrelations,
            lagCorrelations: lagCorrelations,
            strongestHeightRiceLagFrames: strongestLag,
            heightRiceToPayloadBitRegression: linearRegression(
                independentName: "heightFirstDifferenceRiceBits",
                independent: heightRice,
                dependentName: "payloadBitCount",
                dependent: payloadBits
            ),
            frames: metrics
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try encoder.encode(report).write(to: outputURL, options: .atomic) }
        catch { throw DTSError.io("cannot write XLL-X PCM correlation: \(error.localizedDescription)") }
        return report
    }

    private static func correlation(
        _ leftName: String,
        _ left: [Double],
        _ rightName: String,
        _ right: [Double]
    ) -> DTSXPrivatePCMCorrelationValue {
        DTSXPrivatePCMCorrelationValue(
            leftMetric: leftName,
            rightMetric: rightName,
            sampleCount: min(left.count, right.count),
            pearsonCorrelation: pearson(left, right)
        )
    }

    private static func pearson(_ left: [Double], _ right: [Double]) -> Double {
        let count = min(left.count, right.count)
        guard count > 1 else { return 0 }
        let leftMean = left.prefix(count).reduce(0, +) / Double(count)
        let rightMean = right.prefix(count).reduce(0, +) / Double(count)
        var covariance = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for index in 0..<count {
            let leftDelta = left[index] - leftMean
            let rightDelta = right[index] - rightMean
            covariance += leftDelta * rightDelta
            leftVariance += leftDelta * leftDelta
            rightVariance += rightDelta * rightDelta
        }
        let denominator = sqrt(leftVariance * rightVariance)
        return denominator > 0 ? covariance / denominator : 0
    }

    private static func lagged(
        _ left: [Double],
        _ right: [Double],
        lag: Int
    ) -> (left: [Double], right: [Double]) {
        let count = min(left.count, right.count)
        if lag >= 0 {
            guard lag < count else { return ([], []) }
            return (Array(left[0..<(count - lag)]), Array(right[lag..<count]))
        }
        let offset = -lag
        guard offset < count else { return ([], []) }
        return (Array(left[offset..<count]), Array(right[0..<(count - offset)]))
    }

    private static func linearRegression(
        independentName: String,
        independent: [Double],
        dependentName: String,
        dependent: [Double]
    ) -> DTSXPrivatePCMLinearRegression {
        let count = min(independent.count, dependent.count)
        guard count > 1 else {
            return DTSXPrivatePCMLinearRegression(
                independentMetric: independentName,
                dependentMetric: dependentName,
                slope: 0,
                intercept: 0,
                rSquared: 0,
                meanAbsoluteError: 0
            )
        }
        let xMean = independent.prefix(count).reduce(0, +) / Double(count)
        let yMean = dependent.prefix(count).reduce(0, +) / Double(count)
        var covariance = 0.0
        var variance = 0.0
        for index in 0..<count {
            let delta = independent[index] - xMean
            covariance += delta * (dependent[index] - yMean)
            variance += delta * delta
        }
        let slope = variance > 0 ? covariance / variance : 0
        let intercept = yMean - slope * xMean
        var absoluteError = 0.0
        for index in 0..<count {
            absoluteError += abs(dependent[index] - (intercept + slope * independent[index]))
        }
        let correlation = pearson(independent, dependent)
        return DTSXPrivatePCMLinearRegression(
            independentMetric: independentName,
            dependentMetric: dependentName,
            slope: slope,
            intercept: intercept,
            rSquared: correlation * correlation,
            meanAbsoluteError: absoluteError / Double(count)
        )
    }

    static func hashPCM(_ planes: [[Int32]]) -> String {
        var hasher = SHA256Hasher()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(1 << 16)
        for plane in planes {
            for value in plane {
                let sample = UInt32(bitPattern: value) & 0x00ff_ffff
                bytes.append(UInt8(truncatingIfNeeded: sample))
                bytes.append(UInt8(truncatingIfNeeded: sample >> 8))
                bytes.append(UInt8(truncatingIfNeeded: sample >> 16))
                if bytes.count >= 1 << 16 {
                    hasher.update(bytes)
                    bytes.removeAll(keepingCapacity: true)
                }
            }
        }
        hasher.update(bytes)
        return hasher.finalizeHex()
    }
}
