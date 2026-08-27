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

        case "pop-window-motion":
            // Deterministic surrogate for the TBH pop windows: long full
            // silence, then object-motion-density windows at caller-chosen
            // content access units. Inside each window a moderate stereo bed
            // stays audible while exactly one height feed carries a gated
            // burst per access unit, rotating Lfh→Rfh→Lrh→Rrh, with a
            // floor-surround rotation interleaved on odd access units and a
            // bed-audible zero-height access unit every eighth slot. Each
            // burst attacks and releases inside its access unit, so the
            // height-activity mask changes at every access-unit boundary -
            // the maximal onset/switch seam density the master's object
            // automation approaches in the flagged windows - while every
            // boundary itself carries raised-cosine edges so the vector
            // cannot inject a step click of its own.
            guard parts.count >= 2 else {
                throw DTSError.invalidArgument(
                    "pop-window-motion requires at least one access-unit window, "
                        + "for example pop-window-motion:1992-2250:16031-16500"
                )
            }
            var windows: [(start: Int, end: Int)] = []
            for part in parts.dropFirst() {
                let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2,
                      let start = Int(bounds[0]),
                      let end = Int(bounds[1]),
                      start >= 0, start < end else {
                    throw DTSError.invalidArgument(
                        "pop-window-motion window must be STARTAU-ENDAU with STARTAU < ENDAU, got \(part)"
                    )
                }
                guard end <= frameCount else {
                    throw DTSError.invalidArgument(
                        "pop-window-motion window \(part) exceeds \(frameCount) source access units"
                    )
                }
                if let last = windows.last, start < last.end {
                    throw DTSError.invalidArgument(
                        "pop-window-motion windows must be ascending and non-overlapping"
                    )
                }
                windows.append((start, end))
            }
            let heightOrder = [8, 9, 10, 11]
            let heightFrequencies = [503.0, 617.0, 733.0, 857.0]
            let floorOrder = [4, 5, 6, 7]
            let floorFrequencies = [1_091.0, 1_213.0, 1_333.0, 1_459.0]
            let bedFrequencies = (left: 401.0, right: 449.0)
            let burstEdgeSampleCount = 96
            for window in windows {
                let windowStartSample = window.start * XLLSyntax.frameSampleCount
                let windowEndSample = window.end * XLLSyntax.frameSampleCount
                let windowSampleCount = windowEndSample - windowStartSample
                let bedEdgeSampleCount = min(2_048, max(1, windowSampleCount / 4))
                for sample in windowStartSample..<windowEndSample {
                    let offset = sample - windowStartSample
                    let remaining = windowEndSample - sample - 1
                    let edge = min(offset, remaining)
                    let envelope: Double
                    if edge < bedEdgeSampleCount {
                        let sine = sin(Double(edge) / Double(bedEdgeSampleCount) * Double.pi * 0.5)
                        envelope = sine * sine
                    } else {
                        envelope = 1
                    }
                    let leftPhase = 2.0 * Double.pi * bedFrequencies.left
                        * Double(offset) / 48_000.0
                    let rightPhase = 2.0 * Double.pi * bedFrequencies.right
                        * Double(offset) / 48_000.0
                    planes[0][sample] = Int32((sin(leftPhase) * envelope * 700_000.0).rounded())
                    planes[1][sample] = Int32((sin(rightPhase) * envelope * 700_000.0).rounded())
                }
                for accessUnit in window.start..<window.end {
                    let slot = accessUnit - window.start
                    // Every eighth slot keeps the bed audible under silent
                    // heights: the bed-active zero-height seam class.
                    guard slot % 8 != 7 else { continue }
                    let start = accessUnit * XLLSyntax.frameSampleCount
                    func writeBurst(channel: Int, frequency: Double, amplitude: Double) {
                        for offset in 0..<XLLSyntax.frameSampleCount {
                            let remaining = XLLSyntax.frameSampleCount - offset - 1
                            let edge = min(offset, remaining)
                            let envelope: Double
                            if edge < burstEdgeSampleCount {
                                let sine = sin(
                                    Double(edge) / Double(burstEdgeSampleCount) * Double.pi * 0.5
                                )
                                envelope = sine * sine
                            } else {
                                envelope = 1
                            }
                            let phase = 2.0 * Double.pi * frequency
                                * Double(offset) / 48_000.0
                            planes[channel][start + offset] = Int32(
                                (sin(phase) * envelope * amplitude).rounded()
                            )
                        }
                    }
                    let heightIndex = slot % heightOrder.count
                    writeBurst(
                        channel: heightOrder[heightIndex],
                        frequency: heightFrequencies[heightIndex],
                        amplitude: 700_000.0
                    )
                    if slot % 2 == 1 {
                        let floorIndex = (slot / 2) % floorOrder.count
                        writeBurst(
                            channel: floorOrder[floorIndex],
                            frequency: floorFrequencies[floorIndex],
                            amplitude: 300_000.0
                        )
                    }
                }
            }

        default:
            throw DTSError.invalidArgument(
                "unknown DTS:X control pattern \(pattern); use silence, impulse:CHANNEL, "
                    + "frame-edge:CHANNEL, sine:CHANNEL, fullscale:CHANNEL, all-sine, "
                    + "channel-walk, or pop-window-motion:STARTAU-ENDAU[:STARTAU-ENDAU...]"
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
