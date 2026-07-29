import Foundation

public struct DTSBitrateStreamMetrics: Sendable, Equatable, Codable {
    public let inputPath: String
    public let authoringFrameRate: DTSFrameRate?
    public let fileByteCount: UInt64
    public let elementaryStreamByteCount: Int64
    public let accessUnitCount: Int
    public let pcmSampleCount: Int64
    public let durationSeconds: Double
    public let coreByteCount: Int64
    public let exssByteCount: Int64
    public let xllFrameByteCount: Int64
    public let publicXLLByteCount: Int64
    public let privateXLLXByteCount: Int64
    public let framingOverheadByteCount: Int64
    public let averageBitrateKbps: Double
    public let peakAccessUnitBitrateKbps: Double
    public let peakOneSecondBitrateKbps: Double
    public let perSecondByteCounts: [Int64]
    public let perSecondCoreByteCounts: [Int64]
    public let perSecondExSSByteCounts: [Int64]
    public let perSecondPublicXLLByteCounts: [Int64]
    public let perSecondPrivateXLLXByteCounts: [Int64]
    public let perSecondFramingOverheadByteCounts: [Int64]
    public let measurementIsWholeStream: Bool
}

public struct DTSBitrateParityReport: Sendable, Equatable, Codable {
    public let requestedMaximumAccessUnitCount: Int?
    public let reference: DTSBitrateStreamMetrics
    public let candidate: DTSBitrateStreamMetrics
    public let accessUnitCountMatches: Bool
    public let pcmSampleCountMatches: Bool
    public let authoringFrameRateMatches: Bool?
    public let elementaryStreamByteRatio: Double?
    public let coreByteRatio: Double?
    public let publicXLLByteRatio: Double?
    public let privateXLLXByteRatio: Double?
    public let averageBitrateDeltaKbps: Double
    public let peakAccessUnitBitrateDeltaKbps: Double
    public let peakOneSecondBitrateDeltaKbps: Double
    public let perSecondByteRatios: [Double?]
    public let perSecondCoreByteRatios: [Double?]
    public let perSecondPublicXLLByteRatios: [Double?]
    public let perSecondPrivateXLLXByteRatios: [Double?]
    public let maximumPerSecondByteRatio: Double?
    public let maximumPerSecondByteRatioIndex: Int?
    public let minimumPerSecondByteRatio: Double?
    public let minimumPerSecondByteRatioIndex: Int?
}

/// Compares complete elementary-stream data volume without treating byte
/// identity as a codec-validity requirement. Public XLL and aligned XLL-X are
/// measured independently so entropy regressions cannot hide in total size.
public enum DTSBitrateParityVerifier {
    public static func compare(
        referenceURL: URL,
        candidateURL: URL,
        maximumAccessUnitCount: Int? = nil
    ) throws -> DTSBitrateParityReport {
        if let maximumAccessUnitCount, maximumAccessUnitCount <= 0 {
            throw DTSError.invalidArgument("maximum bitrate comparison access-unit count must be positive")
        }
        let reference = try metrics(
            inputURL: referenceURL,
            maximumAccessUnitCount: maximumAccessUnitCount
        )
        let candidate = try metrics(
            inputURL: candidateURL,
            maximumAccessUnitCount: maximumAccessUnitCount
        )
        let secondCount = max(
            reference.perSecondByteCounts.count,
            candidate.perSecondByteCounts.count
        )
        var perSecondRatios: [Double?] = []
        perSecondRatios.reserveCapacity(secondCount)
        var maximumRatio: Double?
        var maximumRatioIndex: Int?
        var minimumRatio: Double?
        var minimumRatioIndex: Int?
        for index in 0..<secondCount {
            let referenceBytes = reference.perSecondByteCounts.indices.contains(index)
                ? reference.perSecondByteCounts[index] : 0
            let candidateBytes = candidate.perSecondByteCounts.indices.contains(index)
                ? candidate.perSecondByteCounts[index] : 0
            let ratio = byteRatio(candidateBytes, referenceBytes)
            perSecondRatios.append(ratio)
            if let ratio, maximumRatio == nil || ratio > maximumRatio! {
                maximumRatio = ratio
                maximumRatioIndex = index
            }
            if let ratio, minimumRatio == nil || ratio < minimumRatio! {
                minimumRatio = ratio
                minimumRatioIndex = index
            }
        }
        let frameRateMatches: Bool?
        switch (reference.authoringFrameRate, candidate.authoringFrameRate) {
        case let (referenceRate?, candidateRate?): frameRateMatches = referenceRate == candidateRate
        case (nil, nil): frameRateMatches = nil
        default: frameRateMatches = false
        }
        return DTSBitrateParityReport(
            requestedMaximumAccessUnitCount: maximumAccessUnitCount,
            reference: reference,
            candidate: candidate,
            accessUnitCountMatches: reference.accessUnitCount == candidate.accessUnitCount,
            pcmSampleCountMatches: reference.pcmSampleCount == candidate.pcmSampleCount,
            authoringFrameRateMatches: frameRateMatches,
            elementaryStreamByteRatio: byteRatio(
                candidate.elementaryStreamByteCount,
                reference.elementaryStreamByteCount
            ),
            coreByteRatio: byteRatio(candidate.coreByteCount, reference.coreByteCount),
            publicXLLByteRatio: byteRatio(
                candidate.publicXLLByteCount,
                reference.publicXLLByteCount
            ),
            privateXLLXByteRatio: byteRatio(
                candidate.privateXLLXByteCount,
                reference.privateXLLXByteCount
            ),
            averageBitrateDeltaKbps: candidate.averageBitrateKbps
                - reference.averageBitrateKbps,
            peakAccessUnitBitrateDeltaKbps: candidate.peakAccessUnitBitrateKbps
                - reference.peakAccessUnitBitrateKbps,
            peakOneSecondBitrateDeltaKbps: candidate.peakOneSecondBitrateKbps
                - reference.peakOneSecondBitrateKbps,
            perSecondByteRatios: perSecondRatios,
            perSecondCoreByteRatios: ratios(
                candidate.perSecondCoreByteCounts,
                reference.perSecondCoreByteCounts
            ),
            perSecondPublicXLLByteRatios: ratios(
                candidate.perSecondPublicXLLByteCounts,
                reference.perSecondPublicXLLByteCounts
            ),
            perSecondPrivateXLLXByteRatios: ratios(
                candidate.perSecondPrivateXLLXByteCounts,
                reference.perSecondPrivateXLLXByteCounts
            ),
            maximumPerSecondByteRatio: maximumRatio,
            maximumPerSecondByteRatioIndex: maximumRatioIndex,
            minimumPerSecondByteRatio: minimumRatio,
            minimumPerSecondByteRatioIndex: minimumRatioIndex
        )
    }

    private static func metrics(
        inputURL: URL,
        maximumAccessUnitCount: Int?
    ) throws -> DTSBitrateStreamMetrics {
        let input = inputURL.standardizedFileURL
        let infos = try DTSStreamInspector().inspect(
            url: input,
            maximumAccessUnits: maximumAccessUnitCount ?? Int.max
        )
        guard !infos.isEmpty else {
            throw DTSError.malformed("DTS bitrate comparison requires at least one access unit")
        }
        let xllStream = try XLLPBRStreamReader.read(inputURL: input)
        let selectedXLLFrames = xllStream.frames.filter {
            $0.endAccessUnit < infos.count
        }
        let xllASTs = try selectedXLLFrames.map {
            try XLLFrameASTParser.parse($0.frame)
        }
        let elementaryBytes = infos.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
        let pcmSamples = infos.reduce(Int64(0)) { $0 + Int64($1.pcmSampleCount) }
        let coreBytes = infos.reduce(Int64(0)) { $0 + Int64($1.coreByteCount ?? 0) }
        let exssBytes = infos.reduce(Int64(0)) { $0 + Int64($1.exssByteCount ?? 0) }
        let xllBytes = xllASTs.reduce(Int64(0)) { $0 + Int64($1.frameByteCount) }
        let publicXLLBytes = xllASTs.reduce(Int64(0)) {
            $0 + Int64($1.privateDataByteRange.lowerBound)
        }
        let privateXLLXBytes = xllASTs.reduce(Int64(0)) {
            $0 + Int64($1.privateDataByteRange.count)
        }
        let duration = Double(pcmSamples) / 48_000.0
        let averageBitrate = duration > 0
            ? Double(elementaryBytes) * 8.0 / duration / 1_000.0
            : 0
        let peakAccessUnitBitrate = infos.map {
            Double($0.byteCount) * 8.0 * 48_000.0
                / Double($0.pcmSampleCount) / 1_000.0
        }.max() ?? 0
        let perSecondBytes = perSecondByteCounts(infos) { $0.byteCount }
        let perSecondCoreBytes = perSecondByteCounts(infos) { $0.coreByteCount ?? 0 }
        let perSecondExSSBytes = perSecondByteCounts(infos) { $0.exssByteCount ?? 0 }
        let xllPerSecond = perSecondXLLByteCounts(
            frames: selectedXLLFrames,
            asts: xllASTs,
            infos: infos,
            outputCount: perSecondBytes.count
        )
        let perSecondFramingBytes = perSecondBytes.indices.map {
            perSecondBytes[$0]
                - perSecondCoreBytes[$0]
                - xllPerSecond.publicBytes[$0]
                - xllPerSecond.privateBytes[$0]
        }
        let peakOneSecondBitrate = Double(perSecondBytes.max() ?? 0) * 8.0 / 1_000.0
        return DTSBitrateStreamMetrics(
            inputPath: input.path,
            authoringFrameRate: try DTSHDFileContainer.authoringFrameRate(at: input),
            fileByteCount: try fileByteCount(input),
            elementaryStreamByteCount: elementaryBytes,
            accessUnitCount: infos.count,
            pcmSampleCount: pcmSamples,
            durationSeconds: duration,
            coreByteCount: coreBytes,
            exssByteCount: exssBytes,
            xllFrameByteCount: xllBytes,
            publicXLLByteCount: publicXLLBytes,
            privateXLLXByteCount: privateXLLXBytes,
            framingOverheadByteCount: elementaryBytes - coreBytes - xllBytes,
            averageBitrateKbps: averageBitrate,
            peakAccessUnitBitrateKbps: peakAccessUnitBitrate,
            peakOneSecondBitrateKbps: peakOneSecondBitrate,
            perSecondByteCounts: perSecondBytes,
            perSecondCoreByteCounts: perSecondCoreBytes,
            perSecondExSSByteCounts: perSecondExSSBytes,
            perSecondPublicXLLByteCounts: xllPerSecond.publicBytes,
            perSecondPrivateXLLXByteCounts: xllPerSecond.privateBytes,
            perSecondFramingOverheadByteCounts: perSecondFramingBytes,
            measurementIsWholeStream: infos.count == xllStream.accessUnitCount
        )
    }

    private static func perSecondByteCounts(
        _ infos: [DTSAccessUnitInfo],
        bytes: (DTSAccessUnitInfo) -> Int
    ) -> [Int64] {
        var output: [Int64] = []
        var sampleOffset: Int64 = 0
        for info in infos {
            let second = Int(sampleOffset / 48_000)
            if output.count <= second {
                output.append(contentsOf: repeatElement(0, count: second + 1 - output.count))
            }
            output[second] += Int64(bytes(info))
            sampleOffset += Int64(info.pcmSampleCount)
        }
        return output
    }

    private static func perSecondXLLByteCounts(
        frames: [XLLPBRFrame],
        asts: [XLLFrameAST],
        infos: [DTSAccessUnitInfo],
        outputCount: Int
    ) -> (publicBytes: [Int64], privateBytes: [Int64]) {
        var sampleOffsets = Array(repeating: Int64(0), count: infos.count)
        var sampleOffset: Int64 = 0
        for index in infos.indices {
            sampleOffsets[index] = sampleOffset
            sampleOffset += Int64(infos[index].pcmSampleCount)
        }
        var publicBytes = Array(repeating: Int64(0), count: outputCount)
        var privateBytes = Array(repeating: Int64(0), count: outputCount)
        for (frame, ast) in zip(frames, asts)
        where sampleOffsets.indices.contains(frame.startAccessUnit) {
            let second = Int(sampleOffsets[frame.startAccessUnit] / 48_000)
            guard publicBytes.indices.contains(second) else { continue }
            publicBytes[second] += Int64(ast.privateDataByteRange.lowerBound)
            privateBytes[second] += Int64(ast.privateDataByteRange.count)
        }
        return (publicBytes, privateBytes)
    }

    private static func fileByteCount(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw DTSError.io("cannot determine stream size: \(url.path)")
        }
        return size.uint64Value
    }

    private static func byteRatio(_ candidate: Int64, _ reference: Int64) -> Double? {
        guard reference > 0 else { return candidate == 0 ? 1 : nil }
        return Double(candidate) / Double(reference)
    }

    private static func ratios(_ candidate: [Int64], _ reference: [Int64]) -> [Double?] {
        let count = max(candidate.count, reference.count)
        return (0..<count).map { index in
            byteRatio(
                candidate.indices.contains(index) ? candidate[index] : 0,
                reference.indices.contains(index) ? reference[index] : 0
            )
        }
    }
}
