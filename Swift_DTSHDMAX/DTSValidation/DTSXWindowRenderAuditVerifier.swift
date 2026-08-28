import Foundation

/// Render-side audit of the TBH-class pop windows over a real IMF IAB master.
/// Maps the hardware-flagged SMPTE ranges, renders through the production
/// ``DTS714Renderer`` path, and reports PCM continuity and render-guard
/// engagement inside each window. This does not claim bit-exact grammar parity;
/// it isolates whether the **rendered** 7.1.4 source handed to the encoder
/// carries discontinuities or headroom overloads in the flagged ranges.
public struct DTSXWindowRenderAuditReport: Sendable, Equatable, Codable {
    public struct WindowMetrics: Sendable, Equatable, Codable {
        public let mapping: DTSXPopWindowMapping
        /// Largest adjacent-sample magnitude jump on any plane inside the window.
        public let maximumAdjacentSampleDelta: Int64
        /// Plane index (``DTS714Channel`` order) carrying the largest jump.
        public let maximumAdjacentSampleDeltaPlaneIndex: Int
        /// Sample index (programme-relative) of that jump.
        public let maximumAdjacentSampleDeltaSampleIndex: Int
        /// Count of adjacent pairs whose delta exceeds one 1/480 full-scale step.
        public let largeStepCount: Int
        /// Samples whose magnitude reaches the signed-24-bit ceiling inside the window.
        public let fullScaleSampleCount: Int
        /// Height planes with any nonzero sample inside the window.
        public let heightActiveSampleCount: Int
    }

    public let inputPath: String
    public let frameRate: String
    public let renderedSampleCount: Int
    public let wholeProgrammeRenderGuardReport: DTS714RenderGuardReport
    public let windows: [WindowMetrics]
    /// True when every window stayed inside headroom and no large render steps fired.
    public let isRenderSafeInWindows: Bool
}

public enum DTSXWindowRenderAuditVerifier {
    /// TBH hardware pop windows at 24 fps non-drop (contract from PR #24).
    public static let tbhWindowArguments = [
        "00:00:21:06-00:00:24:00",
        "00:02:51:00-00:02:56:00"
    ]

    public static func verify(
        iabURL: URL,
        windowArguments: [String] = tbhWindowArguments,
        frameRate: DTSFrameRate = .fps24,
        primingAccessUnitCount: Int = DTSXPopWindowMapper.defaultPrimingAccessUnitCount
    ) throws -> DTSXWindowRenderAuditReport {
        let iab = try IMFIABReader.read(url: iabURL)
        let master = iab.master
        guard abs((master.framesPerSecond ?? 24) - Double(frameRate.nominalFramesPerSecond)) < 0.01 else {
            throw DTSError.invalidArgument(
                "IAB frame rate \(master.framesPerSecond ?? 0) does not match requested \(frameRate)"
            )
        }

        var guardReport = DTS714RenderGuardReport(
            sampleCount: 0,
            planeOverloadSampleCount: 0,
            foldOverloadSampleCount: 0,
            recoveryOverloadSampleCount: 0,
            overloadSampleCount: 0,
            gainReducedSampleCount: 0,
            minimumGainQ30: 1 << 30,
            maximumCompositeMagnitude: 0,
            maximumGainStepQ30: 0,
            residualClippedSampleCount: 0
        )
        let rendered = try DTS714Renderer.render(iab: iab) { report in
            guardReport = report
        }

        let mappings = try windowArguments.map { argument in
            try DTSXPopWindowMapper.mapping(
                window: DTSTimecodeWindow(
                    argument: argument,
                    nominalFramesPerSecond: frameRate.nominalFramesPerSecond
                ),
                frameRate: frameRate,
                primingAccessUnitCount: primingAccessUnitCount
            )
        }

        let heightPlaneIndices = [
            DTS714Channel.allCases.firstIndex(of: .leftFrontHeight)!,
            DTS714Channel.allCases.firstIndex(of: .rightFrontHeight)!,
            DTS714Channel.allCases.firstIndex(of: .leftRearHeight)!,
            DTS714Channel.allCases.firstIndex(of: .rightRearHeight)!
        ]
        let largeStepThreshold = Int64((1 << 30) / 480)

        let windows = try mappings.map { mapping in
            try metrics(
                rendered: rendered,
                mapping: mapping,
                heightPlaneIndices: heightPlaneIndices,
                largeStepThreshold: largeStepThreshold
            )
        }

        let renderSafe = guardReport.isHeadroomSafe
            && windows.allSatisfy { $0.largeStepCount == 0 && $0.fullScaleSampleCount == 0 }

        return DTSXWindowRenderAuditReport(
            inputPath: iabURL.standardizedFileURL.path,
            frameRate: frameRate.description,
            renderedSampleCount: rendered.sampleCount,
            wholeProgrammeRenderGuardReport: guardReport,
            windows: windows,
            isRenderSafeInWindows: renderSafe
        )
    }

    private static func metrics(
        rendered: DTS714PCMBuffer,
        mapping: DTSXPopWindowMapping,
        heightPlaneIndices: [Int],
        largeStepThreshold: Int64
    ) throws -> DTSXWindowRenderAuditReport.WindowMetrics {
        let start = max(0, min(mapping.startSampleIndex, rendered.sampleCount))
        let end = max(start, min(mapping.endSampleIndex, rendered.sampleCount))
        guard start < end else {
            throw DTSError.malformed(
                "render window \(mapping.startTimecode)-\(mapping.endTimecode) "
                + "does not overlap rendered PCM (\(rendered.sampleCount) samples)"
            )
        }

        var maximumDelta: Int64 = 0
        var maximumDeltaPlane = 0
        var maximumDeltaSample = start
        var largeStepCount = 0
        var fullScaleSampleCount = 0
        var heightActiveSampleCount = 0
        let fullScale = Int64(Int32.max)

        for planeIndex in rendered.planes.indices {
            let plane = rendered.planes[planeIndex]
            for sample in start..<end {
                let magnitude = abs(Int64(plane[sample]))
                if magnitude >= fullScale { fullScaleSampleCount += 1 }
                if heightPlaneIndices.contains(planeIndex), plane[sample] != 0 {
                    heightActiveSampleCount += 1
                }
                guard sample > start else { continue }
                let delta = abs(Int64(plane[sample]) - Int64(plane[sample - 1]))
                if delta > maximumDelta {
                    maximumDelta = delta
                    maximumDeltaPlane = planeIndex
                    maximumDeltaSample = sample
                }
                if delta > largeStepThreshold { largeStepCount += 1 }
            }
        }

        return DTSXWindowRenderAuditReport.WindowMetrics(
            mapping: mapping,
            maximumAdjacentSampleDelta: maximumDelta,
            maximumAdjacentSampleDeltaPlaneIndex: maximumDeltaPlane,
            maximumAdjacentSampleDeltaSampleIndex: maximumDeltaSample,
            largeStepCount: largeStepCount,
            fullScaleSampleCount: fullScaleSampleCount,
            heightActiveSampleCount: heightActiveSampleCount
        )
    }
}
