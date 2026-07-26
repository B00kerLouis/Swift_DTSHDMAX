import Foundation

public struct DTSCoreChannelQuality: Sendable, Equatable, Codable {
    public let channel: String
    public let sourcePeak: Int64
    public let decodedPeak: Int64
    public let errorPeak: Int64
    public let meanAbsoluteError: Double
    public let rootMeanSquareError: Double
    public let signalToNoiseRatioDB: Double?
    public let minimumRiceParameter: Int
    public let riceBitsPerSample: Double
    public let deltaMinimumRiceParameter: Int
    public let deltaRiceBitsPerSample: Double
}

public struct DTSCoreQualityReport: Sendable, Equatable, Codable {
    public let sourcePath: String
    public let inputPath: String
    public let sourceSHA256: String
    public let inputSHA256: String
    public let alignmentSampleCount: Int
    public let comparedSampleCount: Int
    public let decodedSampleCount: Int
    public let channelOrder: [String]
    public let channels: [DTSCoreChannelQuality]
    public let aggregateRootMeanSquareError: Double
    public let aggregateSignalToNoiseRatioDB: Double?
    public let aggregateRiceBitsPerSample: Double
    public let aggregateDeltaRiceBitsPerSample: Double
}

public enum DTSCoreQualityAnalyzer {
    public static func analyze(
        sourceURL: URL,
        inputURL: URL,
        alignmentSampleCount: Int = 1_024
    ) throws -> DTSCoreQualityReport {
        guard alignmentSampleCount >= 0 else {
            throw DTSError.invalidArgument("Core quality alignment must be nonnegative")
        }
        let sourcePath = sourceURL.standardizedFileURL
        let inputPath = inputURL.standardizedFileURL
        let source = try WaveFile.read(from: sourcePath)
        guard source.format == (try PCMFormat(
            sampleRate: 48_000,
            bitDepth: 24,
            layout: .fiveOneSide
        )) else {
            throw DTSError.invalidArgument("Core quality source must be 48 kHz/24-bit 5.1(side) PCM")
        }
        let decoded = try DTSCoreStreamDecoder.decode(inputURL: inputPath)
        guard alignmentSampleCount <= decoded.sampleCount,
              source.sampleCount <= decoded.sampleCount - alignmentSampleCount else {
            throw DTSError.malformed("aligned Core PCM has fewer samples than the source")
        }

        let names = ["L", "R", "C", "LFE", "Ls", "Rs"]
        var channels: [DTSCoreChannelQuality] = []
        channels.reserveCapacity(names.count)
        var aggregateSignalSquares = 0.0
        var aggregateErrorSquares = 0.0
        var aggregateRiceBits: UInt64 = 0
        var aggregateDeltaRiceBits: UInt64 = 0

        for channel in source.planes.indices {
            let sourcePlane = source.planes[channel]
            let decodedPlane = decoded.planes[channel]
            var sourcePeak: Int64 = 0
            var decodedPeak: Int64 = 0
            var errorPeak: Int64 = 0
            var absoluteErrorSum: Int64 = 0
            var signalSquares = 0.0
            var errorSquares = 0.0
            var riceCosts = Array(repeating: UInt64(0), count: 32)
            var deltaRiceCosts = Array(repeating: UInt64(0), count: 32)
            var previousError: Int64 = 0

            for sample in sourcePlane.indices {
                let expected = Int64(sourcePlane[sample])
                let actual = Int64(decodedPlane[sample + alignmentSampleCount])
                let error = expected - actual
                let absoluteError = abs(error)
                sourcePeak = max(sourcePeak, abs(expected))
                decodedPeak = max(decodedPeak, abs(actual))
                errorPeak = max(errorPeak, absoluteError)
                absoluteErrorSum += absoluteError
                signalSquares += Double(expected) * Double(expected)
                errorSquares += Double(error) * Double(error)
                accumulateRiceCosts(mappedSigned(error), into: &riceCosts)
                let delta = sample == 0 ? error : error - previousError
                accumulateRiceCosts(mappedSigned(delta), into: &deltaRiceCosts)
                previousError = error
            }

            let minimumRice = riceCosts.enumerated().min { $0.element < $1.element }!
            let minimumDeltaRice = deltaRiceCosts.enumerated().min { $0.element < $1.element }!
            let count = Double(sourcePlane.count)
            let rmse = sqrt(errorSquares / count)
            let snr = errorSquares == 0
                ? nil
                : 10.0 * log10(signalSquares / errorSquares)
            channels.append(DTSCoreChannelQuality(
                channel: names[channel],
                sourcePeak: sourcePeak,
                decodedPeak: decodedPeak,
                errorPeak: errorPeak,
                meanAbsoluteError: Double(absoluteErrorSum) / count,
                rootMeanSquareError: rmse,
                signalToNoiseRatioDB: snr?.isFinite == true ? snr : nil,
                minimumRiceParameter: minimumRice.offset,
                riceBitsPerSample: Double(minimumRice.element) / count,
                deltaMinimumRiceParameter: minimumDeltaRice.offset,
                deltaRiceBitsPerSample: Double(minimumDeltaRice.element) / count
            ))
            aggregateSignalSquares += signalSquares
            aggregateErrorSquares += errorSquares
            aggregateRiceBits += minimumRice.element
            aggregateDeltaRiceBits += minimumDeltaRice.element
        }

        let totalSampleCount = Double(source.sampleCount * source.format.layout.channelCount)
        let aggregateSNR = aggregateErrorSquares == 0
            ? nil
            : 10.0 * log10(aggregateSignalSquares / aggregateErrorSquares)
        return DTSCoreQualityReport(
            sourcePath: sourcePath.path,
            inputPath: inputPath.path,
            sourceSHA256: try SHA256Hasher.hash(fileAt: sourcePath),
            inputSHA256: try SHA256Hasher.hash(fileAt: inputPath),
            alignmentSampleCount: alignmentSampleCount,
            comparedSampleCount: source.sampleCount,
            decodedSampleCount: decoded.sampleCount,
            channelOrder: names,
            channels: channels,
            aggregateRootMeanSquareError: sqrt(aggregateErrorSquares / totalSampleCount),
            aggregateSignalToNoiseRatioDB: aggregateSNR?.isFinite == true ? aggregateSNR : nil,
            aggregateRiceBitsPerSample: Double(aggregateRiceBits) / totalSampleCount,
            aggregateDeltaRiceBitsPerSample: Double(aggregateDeltaRiceBits) / totalSampleCount
        )
    }

    @inline(__always)
    private static func mappedSigned(_ value: Int64) -> UInt64 {
        value >= 0 ? UInt64(value) << 1 : (UInt64(-value) << 1) - 1
    }

    @inline(__always)
    private static func accumulateRiceCosts(_ value: UInt64, into costs: inout [UInt64]) {
        for parameter in costs.indices {
            costs[parameter] += (value >> UInt64(parameter)) + 1 + UInt64(parameter)
        }
    }
}
