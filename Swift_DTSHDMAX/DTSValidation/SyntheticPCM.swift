import Foundation

enum SyntheticPCM {
    static func deterministic(layout: DTSChannelLayout, frameCount: Int) throws -> PCMBuffer {
        guard frameCount > 0 else { throw DTSError.invalidArgument("frame count must be positive") }
        let sampleCount = frameCount * XLLSyntax.frameSampleCount
        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: layout)
        var planes = Array(repeating: [Int32](), count: layout.channelCount)
        for channel in planes.indices {
            planes[channel].reserveCapacity(sampleCount)
            var state = UInt32(0x243f_6a88) &+ UInt32(channel &* 0x9e37)
            for sample in 0..<sampleCount {
                state = state &* 1_664_525 &+ 1_013_904_223
                var value = Int32(bitPattern: state & 0x00ff_ffff)
                if (value & 0x0080_0000) != 0 { value -= 0x0100_0000 }
                switch sample {
                case 0: value = -8_388_608 + Int32(channel)
                case 1: value = 8_388_607 - Int32(channel)
                case 2: value = 0
                case 3: value = Int32(1 << (channel % 20))
                default: break
                }
                planes[channel].append(value)
            }
        }
        return try PCMBuffer(format: format, planes: planes)
    }

    /// Creates direct 7.1.4 PCM test material for terminal diagnosis. These
    /// vectors bypass Atmos parsing, object rendering, and compatibility-bed
    /// folding so a playback fault can be assigned to the coded-stream path.
    static func controlledDTS714(
        pattern: String,
        frameCount: Int
    ) throws -> DTS714PCMBuffer {
        guard frameCount > 0 else {
            throw DTSError.invalidArgument("DTS:X control frame count must be positive")
        }
        let (sampleCount, overflow) = frameCount.multipliedReportingOverflow(
            by: XLLSyntax.frameSampleCount
        )
        guard !overflow else {
            throw DTSError.valueOutOfRange(
                field: "DTS:X control frame count",
                value: String(frameCount)
            )
        }
        var planes = Array(
            repeating: Array(repeating: Int32(0), count: sampleCount),
            count: DTS714Channel.allCases.count
        )
        let parts = pattern.split(separator: ":", omittingEmptySubsequences: false)
        guard let kind = parts.first, !kind.isEmpty else {
            throw DTSError.invalidArgument("DTS:X control pattern is empty")
        }

        switch kind {
        case "silence":
            guard parts.count == 1 else {
                throw DTSError.invalidArgument("silence does not take a channel selector")
            }

        case "impulse", "frame-edge", "sine", "fullscale":
            guard parts.count == 2 else {
                throw DTSError.invalidArgument(
                    "\(kind) requires one DTS:X channel, for example \(kind):Lfh"
                )
            }
            let channel = try controlledDTS714Channel(String(parts[1]))
            switch kind {
            case "impulse":
                for frame in 0..<frameCount {
                    let offset = frame * XLLSyntax.frameSampleCount
                    planes[channel][offset] = frame.isMultiple(of: 2) ? 4_000_000 : -4_000_000
                }
            case "frame-edge":
                guard frameCount >= 2 else {
                    throw DTSError.invalidArgument("frame-edge requires at least two PCM frames")
                }
                for frame in 1..<frameCount {
                    let boundary = frame * XLLSyntax.frameSampleCount
                    planes[channel][boundary - 1] = 4_000_000
                    planes[channel][boundary] = -4_000_000
                }
            case "sine":
                let frequency = 997.0
                for sample in 0..<sampleCount {
                    let phase = 2.0 * Double.pi * frequency * Double(sample) / 48_000.0
                    planes[channel][sample] = Int32((sin(phase) * 2_000_000.0).rounded())
                }
            case "fullscale":
                for sample in 0..<sampleCount {
                    planes[channel][sample] = sample.isMultiple(of: 2)
                        ? 8_388_607
                        : -8_388_608
                }
            default:
                preconditionFailure("handled above")
            }

        case "all-sine":
            guard parts.count == 1 else {
                throw DTSError.invalidArgument("all-sine does not take a channel selector")
            }
            for channel in planes.indices {
                let frequency = 521.0 + Double(channel) * 137.0
                for sample in 0..<sampleCount {
                    let phase = 2.0 * Double.pi * frequency * Double(sample) / 48_000.0
                    planes[channel][sample] = Int32((sin(phase) * 700_000.0).rounded())
                }
            }

        case "channel-walk":
            guard parts.count == 1 else {
                throw DTSError.invalidArgument("channel-walk does not take a channel selector")
            }
            // Put the four private XLL-X height feeds first so a terminal's
            // private routing can be audited before the public compatibility
            // bed.  Every slot has a 100 ms raised-cosine edge, preventing the
            // diagnostic itself from introducing a step click.
            let order: [DTS714Channel] = [
                .leftFrontHeight, .rightFrontHeight,
                .leftRearHeight, .rightRearHeight,
                .left, .right, .center, .lfe,
                .leftSideSurround, .rightSideSurround,
                .leftRearSurround, .rightRearSurround
            ]
            let frequencies = [
                503.0, 617.0, 733.0, 857.0,
                971.0, 1_091.0, 1_213.0, 80.0,
                1_333.0, 1_459.0, 1_579.0, 1_699.0
            ]
            let slotSampleCount = sampleCount / order.count
            guard slotSampleCount > 0 else {
                throw DTSError.invalidArgument("channel-walk source is too short")
            }
            let fadeSampleCount = min(4_800, max(1, slotSampleCount / 10))
            for slot in order.indices {
                let channel = DTS714Channel.allCases.firstIndex(of: order[slot])!
                let start = slot * slotSampleCount
                let end = slot == order.count - 1
                    ? sampleCount
                    : (slot + 1) * slotSampleCount
                for sample in start..<end {
                    let offset = sample - start
                    let remaining = end - sample - 1
                    let edge = min(offset, remaining)
                    let envelope: Double
                    if edge < fadeSampleCount {
                        let phase = Double(edge) / Double(fadeSampleCount) * Double.pi * 0.5
                        let sine = sin(phase)
                        envelope = sine * sine
                    } else {
                        envelope = 1
                    }
                    let phase = 2.0 * Double.pi * frequencies[slot]
                        * Double(offset) / 48_000.0
                    planes[channel][sample] = Int32(
                        (sin(phase) * envelope * 700_000.0).rounded()
                    )
                }
            }

        default:
            throw DTSError.invalidArgument(
                "unknown DTS:X control pattern \(pattern); use silence, impulse:CHANNEL, "
                    + "frame-edge:CHANNEL, sine:CHANNEL, fullscale:CHANNEL, all-sine, "
                    + "or channel-walk"
            )
        }
        return try DTS714PCMBuffer(planes: planes)
    }

    private static func controlledDTS714Channel(_ selector: String) throws -> Int {
        if let numeric = Int(selector), DTS714Channel.allCases.indices.contains(numeric) {
            return numeric
        }
        if let channel = DTS714Channel(rawValue: selector),
           let index = DTS714Channel.allCases.firstIndex(of: channel) {
            return index
        }
        throw DTSError.invalidArgument(
            "DTS:X control channel must be 0...11 or one of "
                + DTS714Channel.allCases.map(\.rawValue).joined(separator: ", ")
        )
    }
}
