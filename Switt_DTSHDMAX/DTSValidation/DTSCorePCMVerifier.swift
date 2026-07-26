import Foundation

public struct DTSCorePCMVerificationReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let oraclePath: String
    public let inputSHA256: String
    public let oracleSHA256: String
    public let frameCount: Int
    public let sampleCount: Int
    public let channelOrder: [String]
    public let mismatchCounts: [Int]
    public let firstMismatchSamples: [Int?]
    public let firstMismatchAccessUnits: [Int?]
    public let firstMismatchSamplesWithinAccessUnit: [Int?]
    public let expectedAtFirstMismatch: [Int32?]
    public let actualAtFirstMismatch: [Int32?]
    public let maximumAbsoluteDifferences: [Int64]
    public let maximumDifferenceSamples: [Int?]
    public let maximumDifferenceAccessUnits: [Int?]
    public let maximumDifferenceSamplesWithinAccessUnit: [Int?]
    public let isBitExact: Bool
}

public enum DTSCorePCMVerifier {
    public static func verify(inputURL: URL, oraclePCMURL: URL) throws -> DTSCorePCMVerificationReport {
        let input = inputURL.standardizedFileURL
        let oracleURL = oraclePCMURL.standardizedFileURL
        let oracle = try WaveFile.readIntegerPCM(from: oracleURL)
        guard oracle.sampleRate == 48_000,
              (oracle.validBits == 24 || oracle.validBits == 32),
              oracle.layout == .fiveOneSide else {
            throw DTSError.invalidArgument("Core oracle PCM must be 48 kHz integer 5.1(side)")
        }
        let accessUnits = try DTSStreamInspector().inspect(url: input, maximumAccessUnits: Int.max)
        let decoded = try DTSCoreStreamDecoder.decode(inputURL: input)
        let decodedCount = decoded.sampleCount
        var mismatches = Array(repeating: 0, count: 6)
        var firstMismatch: [Int?] = Array(repeating: nil, count: 6)
        var expectedAtFirst: [Int32?] = Array(repeating: nil, count: 6)
        var actualAtFirst: [Int32?] = Array(repeating: nil, count: 6)
        var maxima = Array(repeating: Int64(0), count: 6)
        var maximumSamples: [Int?] = Array(repeating: nil, count: 6)

        guard decodedCount == oracle.sampleCount else {
            throw DTSError.malformed(
                "native Core PCM has \(decodedCount) samples, oracle has \(oracle.sampleCount)"
            )
        }
        for channel in 0..<6 {
            for sample in 0..<decodedCount {
                    let expected = oracle.planes[channel][sample]
                    let actual = decoded.planes[channel][sample]
                    let difference = abs(Int64(expected) - Int64(actual))
                    if difference > maxima[channel] {
                        maxima[channel] = difference
                        maximumSamples[channel] = sample
                    }
                    if expected != actual {
                        mismatches[channel] += 1
                        if firstMismatch[channel] == nil {
                            firstMismatch[channel] = sample
                            expectedAtFirst[channel] = expected
                            actualAtFirst[channel] = actual
                        }
                    }
            }
        }
        return DTSCorePCMVerificationReport(
            inputPath: input.path,
            oraclePath: oracleURL.path,
            inputSHA256: try SHA256Hasher.hash(fileAt: input),
            oracleSHA256: try SHA256Hasher.hash(fileAt: oracleURL),
            frameCount: accessUnits.count,
            sampleCount: decodedCount,
            channelOrder: ["L", "R", "C", "LFE", "Ls", "Rs"],
            mismatchCounts: mismatches,
            firstMismatchSamples: firstMismatch,
            firstMismatchAccessUnits: firstMismatch.map {
                $0.flatMap { accessUnitLocation(sample: $0, accessUnits: accessUnits)?.index }
            },
            firstMismatchSamplesWithinAccessUnit: firstMismatch.map {
                $0.flatMap { accessUnitLocation(sample: $0, accessUnits: accessUnits)?.sample }
            },
            expectedAtFirstMismatch: expectedAtFirst,
            actualAtFirstMismatch: actualAtFirst,
            maximumAbsoluteDifferences: maxima,
            maximumDifferenceSamples: maximumSamples,
            maximumDifferenceAccessUnits: maximumSamples.map {
                $0.flatMap { accessUnitLocation(sample: $0, accessUnits: accessUnits)?.index }
            },
            maximumDifferenceSamplesWithinAccessUnit: maximumSamples.map {
                $0.flatMap { accessUnitLocation(sample: $0, accessUnits: accessUnits)?.sample }
            },
            isBitExact: mismatches.allSatisfy { $0 == 0 }
        )
    }

    private static func accessUnitLocation(
        sample: Int,
        accessUnits: [DTSAccessUnitInfo]
    ) -> (index: Int, sample: Int)? {
        guard sample >= 0 else { return nil }
        var start = 0
        for (index, accessUnit) in accessUnits.enumerated() {
            let end = start + accessUnit.pcmSampleCount
            if sample < end { return (index, sample - start) }
            start = end
        }
        return nil
    }
}
