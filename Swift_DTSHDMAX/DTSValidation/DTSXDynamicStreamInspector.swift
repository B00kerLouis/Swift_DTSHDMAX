// Copyright (c) B00kerLouis.
import Foundation

public struct DTSXDynamicChannelMetrics: Sendable, Codable {
    public let role: String
    public let sampleCount: Int
    public let nonzeroSamples: Int
    public let peakAbsolute: Int64
    public let rms: Double
    public let maximumSampleJump: Int64
    public let fullScaleSamples: Int
}

public struct DTSXDynamicInspectionReport: Sendable, Codable {
    public let layout: DTSXDynamicLayout
    public let dynamicObjectCount: Int
    public let reservedIMAXObjectCount: Int
    public let accessUnitCount: Int
    public let positionChangeCounts: [Int]
    public let dynamicFoldChangeCounts: [Int]
    public let dynamicFoldCodes: [[Int]]
    public let navigationWidths: [String: Int]
    public let channels: [DTSXDynamicChannelMetrics]
    public let allMetadataAndAudioCRCsValid: Bool
    public let fileNavigationValid: Bool
    public let officialPlaybackQualified: Bool
}

public enum DTSXDynamicStreamInspector {
    /// Walks complete AUs and decodes only bounded 512-sample private groups.
    /// No waveform or compressed programme is loaded wholesale.
    public static func inspect(input: URL) throws -> DTSXDynamicInspectionReport {
        let infos = try DTSStreamInspector().inspect(url: input, maximumAccessUnits: Int.max)
        guard !infos.isEmpty else { throw DTSError.malformed("Empty object stream") }
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        var layout: DTSXDynamicLayout?, previousPositions: [DTSXObjectPosition] = []
        var changes: [Int] = [], widths: [String: Int] = [:]
        var firstFolds: [[Int]] = [], previousFolds: [[Int]] = [], foldChanges: [Int] = []
        var peaks: [Int64] = [], jumps: [Int64] = [], last: [Int32] = []
        var powers: [Double] = [], nonzero: [Int] = [], clips: [Int] = []
        var sampleCount = 0
        for info in infos {
            guard info.byteCount <= 1_048_576 else { throw DTSError.malformed("Object AU exceeds bounded input window") }
            try handle.seek(toOffset: UInt64(info.byteOffset))
            guard let bytes = try handle.read(upToCount: info.byteCount), bytes.count == info.byteCount else {
                throw DTSError.truncated(field: "Object inspection AU", bitOffset: Int(info.byteOffset)*8)
            }
            let au = try DTSOfficialStreamASTParser.parseAccessUnit(bytes)
            let exss = try ExSSParser().parse(frame: au.exss.serialize())
            let xll = try XLLFrameASTParser.parse(exss.xllData)
            let objects = try DTSXDynamicPrivateFrame.parse(xll.privateData)
            let plan = try XLLSegmentationPlan(segmentCount: xll.segmentCount,
                segmentSampleCount: xll.segmentSampleCount, segmentSizeBitCount: xll.segmentSizeBitCount,
                navigationByteCount: xll.naviByteRange.count,
                segmentEntropyByteCounts: (0..<xll.segmentCount).map { segment in
                    let start = segment * xll.channelSets.count
                    return Array(xll.naviSegmentByteCounts[start..<start+xll.channelSets.count])
                })
            try objects.validate(plan: plan)
            let found: DTSXDynamicLayout = objects.metadata.reservedTFC ? .sevenOneFive : .sevenOneFour
            if let layout, layout != found { throw DTSError.malformed("Object roles changed within a programme") }
            let planes = try objects.decode()
            let positions = Array(objects.metadata.positions.suffix(found.dynamicObjectCount))
            let folds = Array(objects.metadata.foldCodes.suffix(found.dynamicObjectCount))
            if layout == nil {
                layout = found; changes = Array(repeating: 0, count: positions.count)
                firstFolds = folds; foldChanges = Array(repeating: 0,count: folds.count)
                peaks = Array(repeating: 0, count: planes.count); jumps = peaks
                powers = Array(repeating: 0, count: planes.count); nonzero = Array(repeating: 0, count: planes.count)
                clips = nonzero; last = Array(repeating: 0, count: planes.count)
            } else {
                for index in positions.indices where positions[index] != previousPositions[index] { changes[index] += 1 }
                for index in folds.indices where folds[index] != previousFolds[index] { foldChanges[index] += 1 }
            }
            previousPositions = positions
            previousFolds = folds
            widths[String(objects.navigationWidth), default: 0] += 1
            for channel in planes.indices {
                for value in planes[channel] {
                    let v = Int64(value)
                    peaks[channel] = max(peaks[channel], abs(v)); powers[channel] += Double(v)*Double(v)
                    jumps[channel] = max(jumps[channel], abs(v-Int64(last[channel]))); last[channel] = value
                    if value != 0 { nonzero[channel] += 1 }
                    if value == -8_388_608 || value == 8_388_607 { clips[channel] += 1 }
                }
            }
            sampleCount += 512
        }
        let selected = layout!
        let names = (selected.reservedIMAXObjectCount == 1 ? ["Reserved IMAX TFC"] : [])
            + (0..<selected.dynamicObjectCount).map { "Dynamic Object \($0)" }
            + ["Fixed TFL","Fixed TFR","Fixed TBL","Fixed TBR"]
        let navigation = try DTSHDFileContainer.navigationOffsetsMatchAccessUnits(at: input, accessUnits: infos)
        guard navigation else { throw DTSError.malformed("Object file NAVI does not match AU boundaries") }
        return DTSXDynamicInspectionReport(layout: selected, dynamicObjectCount: selected.dynamicObjectCount,
            reservedIMAXObjectCount: selected.reservedIMAXObjectCount, accessUnitCount: infos.count,
            positionChangeCounts: changes, dynamicFoldChangeCounts: foldChanges, dynamicFoldCodes: firstFolds,
            navigationWidths: widths,
            channels: names.indices.map {
                DTSXDynamicChannelMetrics(role: names[$0], sampleCount: sampleCount, nonzeroSamples: nonzero[$0],
                    peakAbsolute: peaks[$0], rms: sqrt(powers[$0]/Double(sampleCount)),
                    maximumSampleJump: jumps[$0], fullScaleSamples: clips[$0])
            }, allMetadataAndAudioCRCsValid: true, fileNavigationValid: true, officialPlaybackQualified: false)
    }
}
