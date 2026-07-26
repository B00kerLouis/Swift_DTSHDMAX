import Foundation

public struct DTSHDMADeliveryInput: Sendable, Equatable {
    public let inputURL: URL
    public let resolvedInputURL: URL
    public let detectedInput: DTSDetectedInput
    public let sourceChannelCount: Int
    public let atmosBedChannelCount: Int?
    public let atmosObjectCount: Int?
    public let renderedFromAtmos: Bool

    public init(
        inputURL: URL,
        resolvedInputURL: URL,
        detectedInput: DTSDetectedInput,
        sourceChannelCount: Int,
        atmosBedChannelCount: Int? = nil,
        atmosObjectCount: Int? = nil,
        renderedFromAtmos: Bool = false
    ) {
        self.inputURL = inputURL.standardizedFileURL
        self.resolvedInputURL = resolvedInputURL.standardizedFileURL
        self.detectedInput = detectedInput
        self.sourceChannelCount = sourceChannelCount
        self.atmosBedChannelCount = atmosBedChannelCount
        self.atmosObjectCount = atmosObjectCount
        self.renderedFromAtmos = renderedFromAtmos
    }
}

public struct DTSPBRPoint: Sendable, Equatable, Codable {
    public let timecode: String
    public let bitrateKbps: Int
}

public struct DTSHDMADeliveryArtifactReport: Sendable, Equatable, Codable {
    public let streamPath: String
    public let pbrPath: String
    public let logPath: String
    public let averageBitrateKbps: Int
    public let peakBitrateKbps: Int
    public let coreBitrateKbps: Int
    public let frameRate: DTSFrameRate
    public let accessUnitCount: Int
    public let streamMD5: String
    public let pbrPoints: [DTSPBRPoint]
}

public enum DTSHDMADeliveryArtifactWriter {
    private static let bitrateQuantumKbps = 3

    public static func write(
        stream: Data,
        pcm: PCMBuffer,
        input: DTSHDMADeliveryInput,
        outputURL: URL,
        frameRate: DTSFrameRate,
        now: Date = Date()
    ) throws -> DTSHDMADeliveryArtifactReport {
        let output = outputURL.standardizedFileURL
        guard output.pathExtension.lowercased() == "dtshd" else {
            throw DTSError.invalidArgument("delivery stream output must use the .dtshd extension")
        }
        let pbrURL = output.deletingPathExtension().appendingPathExtension("dtspbr")
        let logURL = URL(fileURLWithPath: output.path + "_log.txt")
        guard Set([output.path, pbrURL.path, logURL.path]).count == 3 else {
            throw DTSError.invalidArgument("delivery artifact paths must be distinct")
        }

        let analysis = try analyze(
            stream: stream,
            sourceSampleCount: pcm.sampleCount,
            frameRate: frameRate
        )
        let md5 = MD5Hasher.hash(stream)
        let pbr = pbrText(analysis, frameRate: frameRate)
        let log = try logText(
            analysis: analysis,
            md5: md5,
            pcm: pcm,
            input: input,
            outputURL: output,
            frameRate: frameRate,
            now: now
        )
        try validatePBR(pbr, expected: analysis, frameRate: frameRate)

        do {
            try stream.write(to: output, options: .atomic)
            try Data(pbr.utf8).write(to: pbrURL, options: .atomic)
            try Data(log.utf8).write(to: logURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: pbrURL)
            try? FileManager.default.removeItem(at: logURL)
            throw DTSError.io("cannot write delivery artifacts beside \(output.path): \(error.localizedDescription)")
        }

        return DTSHDMADeliveryArtifactReport(
            streamPath: output.path,
            pbrPath: pbrURL.path,
            logPath: logURL.path,
            averageBitrateKbps: analysis.averageBitrateKbps,
            peakBitrateKbps: analysis.peakBitrateKbps,
            coreBitrateKbps: analysis.coreBitrateKbps,
            frameRate: frameRate,
            accessUnitCount: analysis.accessUnits.count,
            streamMD5: md5,
            pbrPoints: analysis.points
        )
    }

    private struct Analysis {
        let accessUnits: [DTSAccessUnitInfo]
        let averageBitrateKbps: Int
        let peakBitrateKbps: Int
        let coreBitrateKbps: Int
        let points: [DTSPBRPoint]
        let peakRanges: [(start: String, end: String)]
    }

    private static func analyze(
        stream: Data,
        sourceSampleCount: Int,
        frameRate: DTSFrameRate
    ) throws -> Analysis {
        guard sourceSampleCount > 0 else {
            throw DTSError.invalidArgument("delivery source sample count must be positive")
        }
        let accessUnits = try DTSStreamInspector().inspect(
            data: stream,
            maximumAccessUnits: Int.max
        )
        guard !accessUnits.isEmpty,
              accessUnits.allSatisfy({ $0.coreByteCount != nil && $0.exssByteCount != nil }) else {
            throw DTSError.malformed("delivery PBR requires complete Core+ExSS access units")
        }

        let sampleRate = 48_000
        let elementaryByteCount = accessUnits.reduce(0) { $0 + $1.byteCount }
        let average = Int(
            (Double(elementaryByteCount) * 8.0 * Double(sampleRate)
                / Double(sourceSampleCount) / 1_000.0).rounded()
        )
        let first = accessUnits[0]
        let core = Int(
            (Double(first.coreByteCount!) * 8.0 * Double(sampleRate)
                / Double(first.pcmSampleCount) / 1_000.0).rounded()
        )

        let wholeSeconds = sourceSampleCount / sampleRate
        let remainderSamples = sourceSampleCount % sampleRate
        let intervalCount = wholeSeconds + (remainderSamples == 0 ? 0 : 1)
        var intervalBytes = Array(repeating: 0, count: max(1, intervalCount))
        var encodedSample = 0
        for accessUnit in accessUnits {
            let programSample = min(
                sourceSampleCount - 1,
                max(0, encodedSample - XLLSyntax.coreCompatiblePrimingSampleCount)
            )
            intervalBytes[min(programSample / sampleRate, intervalBytes.count - 1)] += accessUnit.byteCount
            encodedSample += accessUnit.pcmSampleCount
        }

        var intervalRates: [Int] = []
        intervalRates.reserveCapacity(intervalBytes.count)
        for (index, byteCount) in intervalBytes.enumerated() {
            let durationSamples = index == intervalBytes.count - 1 && remainderSamples != 0
                ? remainderSamples
                : sampleRate
            let exact = Double(byteCount) * 8.0 * Double(sampleRate)
                / Double(durationSamples) / 1_000.0
            let quantized = Int(ceil(exact / Double(bitrateQuantumKbps))) * bitrateQuantumKbps
            intervalRates.append(max(bitrateQuantumKbps, quantized))
        }

        let totalTimecodeFrames = try frameRate.frameCount(
            forSampleCount: sourceSampleCount,
            sampleRate: sampleRate,
            roundingUp: true
        )
        var points: [DTSPBRPoint] = [
            DTSPBRPoint(
                timecode: timecode(frameIndex: 0, frameRate: frameRate),
                bitrateKbps: intervalRates[0]
            )
        ]
        if wholeSeconds > 0 {
            for second in 1...wholeSeconds {
                points.append(DTSPBRPoint(
                    timecode: timecode(
                        frameIndex: second * frameRate.nominalFramesPerSecond,
                        frameRate: frameRate
                    ),
                    bitrateKbps: intervalRates[min(second - 1, intervalRates.count - 1)]
                ))
            }
        }
        if remainderSamples != 0 {
            points.append(DTSPBRPoint(
                timecode: timecode(frameIndex: totalTimecodeFrames, frameRate: frameRate),
                bitrateKbps: intervalRates.last!
            ))
        }
        let peak = points.map(\.bitrateKbps).max() ?? 0
        return Analysis(
            accessUnits: accessUnits,
            averageBitrateKbps: average,
            peakBitrateKbps: peak,
            coreBitrateKbps: core,
            points: points,
            peakRanges: peakRanges(points: points, peak: peak)
        )
    }

    private static func pbrText(_ analysis: Analysis, frameRate: DTSFrameRate) -> String {
        var lines = [
            String(analysis.averageBitrateKbps),
            String(analysis.peakBitrateKbps),
            frameRate.description
        ]
        lines.append(contentsOf: analysis.points.map { "\($0.timecode),\($0.bitrateKbps)" })
        return lines.joined(separator: "\n") + "\n"
    }

    private static func logText(
        analysis: Analysis,
        md5: String,
        pcm: PCMBuffer,
        input: DTSHDMADeliveryInput,
        outputURL: URL,
        frameRate: DTSFrameRate,
        now: Date
    ) throws -> String {
        let timestamp = timestampString(now)
        let endFrames = try frameRate.frameCount(
            forSampleCount: pcm.sampleCount,
            sampleRate: pcm.format.sampleRate,
            roundingUp: true
        )
        let endTimecode = timecode(frameIndex: endFrames, frameRate: frameRate)
        let inputLabel = input.renderedFromAtmos
            ? "Atmos Master"
            : (pcm.format.layout == .sevenOne ? "Interleaved 7.1" : "Interleaved 5.1")
        let layout = pcm.format.layout == .sevenOne
            ? "7.1 - L, R, C, LFE, Lss, Rss, Lsr, Rsr"
            : "5.1 - L, R, C, LFE, Ls, Rs"
        let streamType = input.renderedFromAtmos
            ? "DTS HD Master Audio (Atmos rendered to 7.1 bed)"
            : "DTS HD Master Audio"
        let fullScaleSamples = pcm.planes.reduce(0) { count, plane in
            count + plane.lazy.filter { $0 == -8_388_608 || $0 == 8_388_607 }.count
        }

        var lines = [
            "****************************************",
            "Swift DTS HDMA Encoder",
            field("Version", "1.0 native"),
            "",
            "",
            "INPUT FILES",
            "------------------------------------------------------",
            field("Input file", inputLabel),
            field("Filename", input.resolvedInputURL.path),
            field("Total channels in source", String(input.sourceChannelCount)),
            field("Sample rate", "\(pcm.format.sampleRate / 1_000) kHz"),
            field("Bit Depth", String(pcm.format.bitDepth))
        ]
        if input.inputURL.path != input.resolvedInputURL.path {
            lines.append(field("Requested input", input.inputURL.path))
        }
        if let beds = input.atmosBedChannelCount {
            lines.append(field("Atmos bed channels", String(beds)))
        }
        if let objects = input.atmosObjectCount {
            lines.append(field("Atmos objects", String(objects)))
        }
        lines.append(contentsOf: [
            "",
            "",
            "ENCODE TYPE",
            "------------------------------------------------------",
            field("Encode Layout", layout),
            field("Sample Rate", "\(pcm.format.sampleRate / 1_000) kHz"),
            field("Destination Format", "Digital Delivery (.dtshd)"),
            field("Stream Type", streamType),
            field("Core Bit Rate (kbps)", String(analysis.coreBitrateKbps)),
            field("Preconditioning Mode", "Off"),
            field("Auto PBR Analysis Mode", "On"),
            "",
            "",
            "TIME SETTINGS",
            "------------------------------------------------------",
            field("Frame Rate", frameRate.description),
            field("Encode Duration", "Entire File"),
            field("Start Time", timecode(frameIndex: 0, frameRate: frameRate)),
            field("End Time", endTimecode),
            field("Encode From", timecode(frameIndex: 0, frameRate: frameRate)),
            field("Encode To", endTimecode),
            "",
            "",
            "ENCODE SETTINGS",
            "------------------------------------------------------",
            field("Dialog Normalization", "-31 dBFS (No Attenuation)"),
            field("DRC Mode", "Off"),
            "",
            "",
            "SEAMLESS BRANCHING",
            "------------------------------------------------------",
            "Not used",
            "",
            "",
            "LEGACY DOWNMIX SETTINGS",
            "------------------------------------------------------"
        ])
        lines.append(contentsOf: downmixLines(layout: pcm.format.layout))
        lines.append(contentsOf: [
            "",
            "OUTPUT LOCATION",
            "------------------------------------------------------",
            field("Directory", outputURL.deletingLastPathComponent().path),
            field("Filename", outputURL.lastPathComponent),
            "",
            "",
            "JOB INFO",
            "------------------------------------------------------",
            field("Creation time", timestamp),
            field("Start time", timestamp),
            field("End time", timestamp),
            field("Result", "Completed"),
            "",
            "Additional info:",
            "",
            "Lossless PCM verification completed",
            "Rendered/input full-scale samples: \(fullScaleSamples)",
            "",
            "Avg  Bitrate CBR core + VBR Lossless ext (kbps): \(analysis.averageBitrateKbps)",
            "Peak Bitrate CBR core + VBR Lossless ext (kbps): \(analysis.peakBitrateKbps)"
        ])
        for range in analysis.peakRanges {
            lines.append("PBR max from  \(range.start)  to  \(range.end)")
        }
        lines.append(contentsOf: [
            "",
            "\(md5) *\(outputURL.path)",
            "",
            ""
        ])
        return lines.joined(separator: "\n")
    }

    private static func validatePBR(
        _ text: String,
        expected: Analysis,
        frameRate: DTSFrameRate
    ) throws {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count == expected.points.count + 3,
              Int(lines[0]) == expected.averageBitrateKbps,
              Int(lines[1]) == expected.peakBitrateKbps,
              lines[2] == Substring(frameRate.description) else {
            throw DTSError.malformed("generated PBR header or row count is invalid")
        }
        for (index, point) in expected.points.enumerated() {
            guard lines[index + 3] == Substring("\(point.timecode),\(point.bitrateKbps)") else {
                throw DTSError.malformed("generated PBR point \(index) differs from its analysis")
            }
        }
    }

    private static func peakRanges(
        points: [DTSPBRPoint],
        peak: Int
    ) -> [(start: String, end: String)] {
        guard points.count > 1 else { return [] }
        var ranges: [(String, String)] = []
        var startIndex: Int?
        for index in 1..<points.count {
            if points[index].bitrateKbps == peak {
                if startIndex == nil { startIndex = index }
            } else if let activeStart = startIndex {
                ranges.append((points[activeStart - 1].timecode, points[index - 1].timecode))
                startIndex = nil
            }
        }
        if let startIndex {
            ranges.append((points[startIndex - 1].timecode, points.last!.timecode))
        }
        return ranges
    }

    private static func timecode(frameIndex: Int, frameRate: DTSFrameRate) -> String {
        let nominal = frameRate.nominalFramesPerSecond
        let frames = frameIndex % nominal
        let totalSeconds = frameIndex / nominal
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3_600
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    private static func field(_ name: String, _ value: String) -> String {
        name.padding(toLength: 30, withPad: " ", startingAt: 0) + " = " + value
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM dd, yyyy  h:mm a"
        return formatter.string(from: date)
    }

    private static func downmixLines(layout: DTSChannelLayout) -> [String] {
        switch layout {
        case .sevenOne:
            return [
                "5.1 Downmix Settings",
                "",
                "          Scale",
                "Input     Factor    Lsr       Rsr",
                "----------------------------------------",
                "L         3.0       INF       INF",
                "R         3.0       INF       INF",
                "C         3.0       INF       INF",
                "LFE       3.0       INF       INF",
                "Ls        3.0       3.0       INF",
                "Rs        3.0       INF       3.0",
                "",
                "",
                "2.0 Downmix Settings",
                "",
                "Input     L         R         C         LFE       Ls        Rs",
                "L         0.0       INF       3.0       INF       3.0       INF",
                "R         INF       0.0       3.0       INF       INF       3.0"
            ]
        case .fiveOneSide:
            return [
                "2.0 Downmix Settings",
                "",
                "Input     L         R         C         LFE       Ls        Rs",
                "L         0.0       INF       3.0       INF       3.0       INF",
                "R         INF       0.0       3.0       INF       INF       3.0"
            ]
        case .stereo:
            return []
        }
    }
}
