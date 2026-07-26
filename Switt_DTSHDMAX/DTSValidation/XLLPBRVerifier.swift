import Foundation

public struct XLLPBRVerificationReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let streamSHA256: String
    public let accessUnitCount: Int
    public let xllFrameCount: Int
    public let crossAccessUnitFrameCount: Int
    public let scalableLSBFrameCount: Int
    public let channelSetCounts: [Int]
    public let commonHeaderByteCounts: [Int]
    public let frameSizeBitCounts: [Int]
    public let segmentSizeBitCounts: [Int]
    public let segmentCounts: [Int]
    public let segmentSampleCounts: [Int]
    public let fieldWidthsMatchStrictProfile: Bool
    public let channelSetSummaries: [DTSXXLLChannelSetSummary]
    public let xllFrameSHA256: [String]
    public let allFramesParsed: Bool
}

public struct XLLPBRStream: Sendable, Equatable {
    public let accessUnitCount: Int
    public let hasBackwardCompatibleCore: Bool
    public let coreCompatiblePrimingSampleCount: Int
    public let initialDecodingDelayFrames: Int
    public let frames: [XLLPBRFrame]
}

public enum XLLPBRStreamReader {
    public static func read(inputURL: URL) throws -> XLLPBRStream {
        let input = inputURL.standardizedFileURL
        let infos = try DTSStreamInspector().inspect(url: input, maximumAccessUnits: Int.max)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: input) }
        catch { throw DTSError.io("cannot open \(input.path): \(error.localizedDescription)") }
        defer { try? handle.close() }

        var assets: [(accessUnit: Int, data: Data)] = []
        assets.reserveCapacity(infos.count)
        var initialDecodingDelayFrames: Int?
        for info in infos {
            let exssOffset = info.byteOffset + UInt64((info.coreByteCount.map { ($0 + 3) & ~3 } ?? 0))
            let exss = try readExactly(
                handle: handle,
                offset: exssOffset,
                count: info.exssByteCount ?? 0
            )
            let parsed = try DTSOfficialStreamASTParser.parseExSS(exss)
            guard parsed.assets.count == 1, let asset = parsed.assets.first else {
                throw DTSError.unsupported("XLL PBR reading requires one ExSS asset")
            }
            assets.append((accessUnit: info.index, data: asset))
            if initialDecodingDelayFrames == nil {
                initialDecodingDelayFrames = try ExSSParser().parse(frame: exss).info.xllInitialDecodingDelayFrames
            }
        }
        return XLLPBRStream(
            accessUnitCount: infos.count,
            hasBackwardCompatibleCore: infos.first?.coreByteCount != nil,
            coreCompatiblePrimingSampleCount: infos.first?.coreByteCount != nil
                ? XLLSyntax.coreCompatiblePrimingSampleCount
                : 0,
            initialDecodingDelayFrames: initialDecodingDelayFrames ?? 0,
            frames: try XLLPBRAssembler.assemble(assets: assets)
        )
    }

    private static func readExactly(handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { throw DTSError.malformed("DTS component has an empty byte count") }
        do { try handle.seek(toOffset: offset) }
        catch { throw DTSError.io("cannot seek DTS component: \(error.localizedDescription)") }
        let data: Data
        do { data = try handle.read(upToCount: count) ?? Data() }
        catch { throw DTSError.io("cannot read DTS component: \(error.localizedDescription)") }
        guard data.count == count else {
            throw DTSError.truncated(field: "DTS component", bitOffset: Int(offset) * 8 + data.count * 8)
        }
        return data
    }
}

public enum XLLPBRVerifier {
    public static func verify(inputURL: URL) throws -> XLLPBRVerificationReport {
        let input = inputURL.standardizedFileURL
        let stream = try XLLPBRStreamReader.read(inputURL: input)
        let frames = stream.frames
        var observedSummaries: [[DTSXXLLChannelSetSummary]] = []
        var counts: [Int] = []
        var commonHeaderByteCounts: [Int] = []
        var frameSizeBitCounts: [Int] = []
        var segmentSizeBitCounts: [Int] = []
        var segmentCounts: [Int] = []
        var segmentSampleCounts: [Int] = []
        var scalable = 0
        for frame in frames {
            let ast = try XLLFrameASTParser.parse(frame.frame)
            counts.append(ast.channelSetCount)
            commonHeaderByteCounts.append(ast.commonHeaderByteCount)
            frameSizeBitCounts.append(ast.frameSizeBitCount)
            segmentSizeBitCounts.append(ast.segmentSizeBitCount)
            segmentCounts.append(ast.segmentCount)
            segmentSampleCounts.append(ast.segmentSampleCount)
            if ast.scalableLSBs { scalable += 1 }
            let summaries = ast.channelSets.map(Self.summary)
            if !observedSummaries.contains(summaries) { observedSummaries.append(summaries) }
        }
        return XLLPBRVerificationReport(
            inputPath: input.path,
            streamSHA256: try SHA256Hasher.hash(fileAt: input),
            accessUnitCount: stream.accessUnitCount,
            xllFrameCount: frames.count,
            crossAccessUnitFrameCount: frames.filter { $0.startAccessUnit != $0.endAccessUnit }.count,
            scalableLSBFrameCount: scalable,
            channelSetCounts: Array(Set(counts)).sorted(),
            commonHeaderByteCounts: Array(Set(commonHeaderByteCounts)).sorted(),
            frameSizeBitCounts: Array(Set(frameSizeBitCounts)).sorted(),
            segmentSizeBitCounts: Array(Set(segmentSizeBitCounts)).sorted(),
            segmentCounts: Array(Set(segmentCounts)).sorted(),
            segmentSampleCounts: Array(Set(segmentSampleCounts)).sorted(),
            fieldWidthsMatchStrictProfile: frameSizeBitCounts.allSatisfy { $0 <= 14 }
                && segmentSizeBitCounts.allSatisfy { $0 <= 13 },
            channelSetSummaries: observedSummaries.first ?? [],
            xllFrameSHA256: frames.map(\.sha256),
            allFramesParsed: frames.count > 0
        )
    }

    private static func summary(_ value: XLLChannelSetAST) -> DTSXXLLChannelSetSummary {
        DTSXXLLChannelSetSummary(
            channelCount: value.channelCount,
            residualChannelMask: value.residualChannelMask,
            bitDepth: value.bitDepth,
            storageBitDepth: value.storageBitDepth,
            sampleRateIndex: value.sampleRateIndex,
            isPrimary: value.isPrimary,
            speakerMask: value.speakerMask
        )
    }

}
