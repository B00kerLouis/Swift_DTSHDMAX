import Foundation

public struct DTSIMAXEncodingReport: Sendable, Codable {
    public let dtsxVision: DTSXVision
    public let encodeMode: DTSEncodeMode
    public let sourceSampleCount: Int
    public let encodedSampleCount: Int
    public let accessUnitCount: Int
    public let segmentCounts: [String: Int]
    public let privatePCMVerified: Bool
    public let sourceGuard: DTS714RenderGuardReport
}

/// Prepared immutable PCM, with only counters protected by the lock. Public
/// workers request one private frame after choosing its 2/4/8 partition.
final class DTSIMAXStreamEncodingSession: @unchecked Sendable {
    let source: DTSIMAXPCMBuffer
    let encodeMode: DTSEncodeMode
    let primingFrameCount = XLLSyntax.coreCompatiblePrimingSampleCount / 512
    let frameCount: Int
    private let lock = NSLock()
    private var encoded: [Bool]
    private var partitions: [String: Int] = [:]
    private let silentStartup: Bool

    init(source: DTSIMAXPCMBuffer, encodeMode: DTSEncodeMode) {
        self.source = source
        self.encodeMode = encodeMode
        frameCount = (source.sampleCount + 511) / 512 + primingFrameCount
        encoded = Array(repeating: false, count: frameCount)
        silentStartup = source.planes.allSatisfy { $0.prefix(min(1024, source.sampleCount)).allSatisfy { $0 == 0 } }
    }

    func preferredPublicSegmentCount(at index: Int) -> Int? {
        if index < primingFrameCount { return 2 }
        if index < primingFrameCount + 2, silentStartup { return 4 }
        let start = (index - primingFrameCount) * 512
        let end = min(start + 512, source.sampleCount)
        if [12,8,9,10,11].allSatisfy({ source.planes[$0][start..<end].allSatisfy { $0 == 0 } }) { return 2 }
        return nil
    }

    func encodeFrame(at index: Int, plan: XLLSegmentationPlan) throws -> Data {
        guard encoded.indices.contains(index) else { throw DTSError.invalidArgument("IMAX frame index exceeds input") }
        let start = (index - primingFrameCount) * 512
        let planes = [12,8,9,10,11].map { channel -> [Int32] in
            guard start >= 0 else { return Array(repeating: 0, count: 512) }
            let end = min(source.sampleCount, start + 512)
            var values = Array(source.planes[channel][start..<end])
            values += Array(repeating: 0, count: 512 - values.count)
            return values
        }
        let frame = try DTSIMAXPrivateFrame.encode(planes: planes, plan: plan, encodeMode: encodeMode)
        lock.lock()
        defer { lock.unlock() }
        guard !encoded[index] else { throw DTSError.malformed("IMAX private provider encoded a frame twice") }
        encoded[index] = true
        partitions[String(plan.segmentCount), default: 0] += 1
        return frame.data
    }

    func finalizedPartitions() throws -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        guard encoded.allSatisfy({ $0 }) else { throw DTSError.malformed("IMAX private encoding left an unfinished frame") }
        return partitions
    }
}

/// Fixed-channel 12.1 encoder. Every private frame closes its native PCM loop;
/// public output keeps the existing serial Core / bounded XLL batch pipeline.
public struct DTSIMAXNativeHDMAEncoder: Sendable {
    public let encodeMode: DTSEncodeMode
    public init(encodeMode: DTSEncodeMode = .auto) { self.encodeMode = encodeMode }

    public func encode(
        source: DTSIMAXPCMBuffer, to outputURL: URL, frameRate: DTSFrameRate,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> DTSIMAXEncodingReport {
        guard source.sampleCount > 0, outputURL.pathExtension.lowercased() == "dtshd" else {
            throw DTSError.invalidArgument("IMAX encoding requires nonempty PCM and .dtshd output")
        }
        var planes = source.planes
        let guardReport = DTS714RenderGuard.apply(to: &planes, imax: true)
        guard guardReport.residualClippedSampleCount == 0 else {
            throw DTSError.malformed("IMAX source guard did not close its compatibility constraints")
        }
        let conditioned = try DTSIMAXPCMBuffer(planes: planes)
        let bed = try DTSIMAXCompatibilityBedRenderer.render(conditioned)
        let session = DTSIMAXStreamEncodingSession(source: conditioned, encodeMode: encodeMode)
        let writer = try DTSHDFileContainer.StreamingWriter(
            outputURL: outputURL, format: bed.format, sourceSampleCount: source.sampleCount, frameRate: frameRate
        )
        do {
            try DTSHDMAEncoder(configuration: DTSHDMAEncoderConfiguration(
                format: bed.format, profile: .dtsHDMA, tailPolicy: .zeroPad,
                xllCodingMode: encodeMode.publicXLLCodingMode,
                officialHierarchyGrammarEnforced: true
            )).encodeIMAX(bed, session: session, writingAccessUnitsTo: { try writer.append(accessUnit: $0) }, progress: progress)
            try writer.finish()
            let partitions = try session.finalizedPartitions()
            return DTSIMAXEncodingReport(
                dtsxVision: .imax, encodeMode: encodeMode, sourceSampleCount: source.sampleCount,
                encodedSampleCount: ((source.sampleCount + 511) / 512) * 512,
                accessUnitCount: session.frameCount, segmentCounts: partitions,
                privatePCMVerified: true, sourceGuard: guardReport
            )
        } catch {
            writer.cancel()
            throw error
        }
    }
}
