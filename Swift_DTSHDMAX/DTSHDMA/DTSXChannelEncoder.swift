import Foundation

public struct DTSXChannelEncodingReport: Sendable, Equatable, Codable {
    public let channelFormat: DTSXChannelFormat
    public let channelNames: [String]
    public let encodeMode: DTSEncodeMode
    public let sourceSampleCount: Int
    public let encodedSampleCount: Int
    public let accessUnitCount: Int
    public let sourceGuard: DTS714RenderGuardReport
    public let privatePCMVerified: Bool
}

final class DTSXChannelStreamSession: @unchecked Sendable {
    let source: DTSXChannelPCMBuffer
    let mode: DTSEncodeMode
    let frameCount: Int
    let priming = XLLSyntax.coreCompatiblePrimingSampleCount/512
    private let lock = NSLock()
    private var widths: [Int?]
    init(source: DTSXChannelPCMBuffer,mode: DTSEncodeMode) {
        self.source = source; self.mode = mode
        frameCount = (source.sampleCount+511)/512+priming
        widths = Array(repeating: nil,count: frameCount)
    }
    func preferredPublicSegmentCount(at index: Int) -> Int? {
        if index < priming { return 2 }
        let start = (index-priming)*512, end = min(start+512,source.sampleCount)
        let silent = source.planes.allSatisfy { $0[start..<end].allSatisfy { $0 == 0 } }
        if index < priming+2, silent { return 4 }
        if source.planes.dropFirst(source.channelFormat.bedChannelCount).allSatisfy({ $0[start..<end].allSatisfy { $0 == 0 } }) { return 2 }
        return nil
    }
    func encodeFrame(at index: Int,plan: XLLSegmentationPlan) throws -> Data {
        guard widths.indices.contains(index) else { throw DTSError.invalidArgument("Fixed speaker frame index") }
        let start = (index-priming)*512
        let heights = source.planes.dropFirst(source.channelFormat.bedChannelCount).map { plane -> [Int32] in
            guard start >= 0 else { return Array(repeating: 0,count: 512) }
            var values = Array(plane[start..<min(start+512,source.sampleCount)])
            values += Array(repeating: 0,count: 512-values.count)
            return values
        }
        let frame = try DTSXFixedPrivateFrame.encode(format: source.channelFormat,planes: heights,plan: plan,mode: mode)
        lock.lock(); defer { lock.unlock() }
        guard widths[index] == nil else { throw DTSError.malformed("Fixed speaker private provider was invoked twice") }
        widths[index] = frame.navigationWidth
        return frame.data
    }
    func navigationWidth(at index: Int) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard widths.indices.contains(index), let width = widths[index] else {
            throw DTSError.malformed("Fixed speaker NAVI requested before private encoding")
        }
        return width
    }
    func verifyComplete() throws {
        lock.lock(); defer { lock.unlock() }
        guard widths.allSatisfy({ $0 != nil }) else { throw DTSError.malformed("Fixed speaker encoding left unfinished frames") }
    }
}

/// Native fixed-speaker delivery for the additional vision-1 formats.
public struct DTSXChannelHDMAEncoder: Sendable {
    public let encodeMode: DTSEncodeMode
    public init(encodeMode: DTSEncodeMode = .auto) { self.encodeMode = encodeMode }
    public func encode(source: DTSXChannelPCMBuffer,to output: URL,frameRate: DTSFrameRate,
                       progress: ((Int,Int) -> Void)? = nil) throws -> DTSXChannelEncodingReport {
        guard source.channelFormat != .sevenOneFour, output.pathExtension.lowercased() == "dtshd" else {
            throw DTSError.invalidArgument("Additional fixed speaker delivery requires a non-7.1.4 format and .dtshd output")
        }
        var planes = source.planes
        let guardReport = DTS714RenderGuard.apply(to: &planes,channelFormat: source.channelFormat)
        guard guardReport.residualClippedSampleCount == 0 else { throw DTSError.malformed("Fixed speaker headroom constraints did not close") }
        let conditioned = try DTSXChannelPCMBuffer(channelFormat: source.channelFormat,planes: planes)
        let bed = try conditioned.compatibilityBed()
        let session = DTSXChannelStreamSession(source: conditioned,mode: encodeMode)
        let writer = try DTSHDFileContainer.StreamingWriter(outputURL: output,format: bed.format,
            sourceSampleCount: conditioned.sampleCount,frameRate: frameRate)
        do {
            try DTSHDMAEncoder(configuration: .init(format: bed.format,tailPolicy: .zeroPad,
                xllCodingMode: encodeMode.publicXLLCodingMode,officialHierarchyGrammarEnforced: true))
                .encodeChannels(bed,session: session,writingAccessUnitsTo: { try writer.append(accessUnit: $0) },progress: progress)
            try session.verifyComplete()
            try writer.finish()
            return DTSXChannelEncodingReport(channelFormat: source.channelFormat,channelNames: source.channelFormat.channelNames,
                encodeMode: encodeMode,sourceSampleCount: source.sampleCount,encodedSampleCount: ((source.sampleCount+511)/512)*512,
                accessUnitCount: session.frameCount,sourceGuard: guardReport,privatePCMVerified: true)
        } catch { writer.cancel(); throw error }
    }
}
