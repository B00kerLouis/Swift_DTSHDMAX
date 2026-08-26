import Foundation

/// Object-onset continuity conditioning for the four rendered height planes.
///
/// Louis's hardware pattern is time-asymmetric: pops cluster where master
/// Object data first becomes active, the closer an object onset sits to the
/// programme head the more likely the pop, and playback stabilizes later. The
/// two carriers of that asymmetry in the delivered stream are both height
/// (private XLL-X) events:
///
/// 1. **Programme head.** The stream starts with two silent Core-priming
///    access units, so the terminal's XLL/XLL-X pipeline converges on silence
///    (Nature's Fury, which plays, additionally keeps the first *source*
///    access units silent). A hot-start title instead slams full-scale height
///    content into the first source access unit - the exact window where the
///    reference decoder is still in first-frame recovery and every navigation
///    and entropy structure changes state for the first time.
/// 2. **Every later silence-to-active height transition.** The private
///    grammar legitimately switches from the compact silence forms to
///    navigated Rice coding on the onset access unit; an onset whose first
///    delivered sample is already beyond anything the reference renderer's
///    own slew (1/480 full scale per sample) could produce lands a hard step
///    on the terminal at exactly the reconfiguration boundary.
///
/// This conditioner bounds both onset classes on the height planes only. The
/// floor bed - the Core/XLL path certified OK on hardware - is never touched,
/// and any height plane that is silent through a window passes through
/// bit-exact, so silent-start programmes (the Nature's Fury class) are
/// unaffected by construction.
public struct DTS714HeightOnsetConditioningReport: Sendable, Equatable, Codable {
    public let sampleCount: Int
    /// Length of the programme-head ramp window in samples.
    public let headRampSampleCount: Int
    /// Head-window height samples whose value the head ramp actually changed.
    public let headRampScaledSampleCount: Int
    /// Length of one silence-to-active onset ramp in samples.
    public let onsetRampSampleCount: Int
    /// Silence-to-active height onsets that violated the reference-slew
    /// envelope and were ramped.
    public let hardOnsetCount: Int
    /// Silence-to-active height onsets already inside the reference-slew
    /// envelope; these pass through bit-exact.
    public let softOnsetCount: Int
    /// Samples changed by onset ramps (outside the head window).
    public let onsetScaledSampleCount: Int
    /// Largest first-active-sample magnitude across detected onsets before
    /// conditioning.
    public let maximumOnsetFirstSampleMagnitudeBefore: Int64
    /// Largest first-active-sample magnitude across detected onsets after
    /// conditioning.
    public let maximumOnsetFirstSampleMagnitudeAfter: Int64

    public var scaledSampleCount: Int {
        headRampScaledSampleCount + onsetScaledSampleCount
    }
    /// True when conditioning did not change a single sample.
    public var isTransparent: Bool { scaledSampleCount == 0 }
}

public enum DTS714HeightOnsetConditioner {
    public static let unityQ30: Int64 = 1 << 30
    /// The four height plane indices in `DTS714Channel.allCases` order
    /// (Lfh, Rfh, Lrh, Rrh).
    public static let heightPlaneIndices = [8, 9, 10, 11]
    /// Programme-head ramp: 72 access units (0.768 s at 48 kHz), inside
    /// Louis's suspected 0.5-1 s official onset envelope and AU-aligned so
    /// the ramp completes exactly on an access-unit boundary.
    public static let headRampSampleCount = 36_864
    /// Silence-to-active onset ramp: the reference renderer's own maximum
    /// slew window (480 samples, 10 ms for a full-scale move at 48 kHz).
    public static let onsetRampSampleCount = 480
    /// A height plane must be silent for at least one full access unit
    /// before a new nonzero sample counts as a fresh onset.
    public static let onsetSilenceSampleCount = 512
    private static let fullScaleMagnitude: Int64 = 1 << 23

    /// Conditions the twelve mixed planes in place; only the four height
    /// planes are ever modified. Planes must be in `DTS714Channel.allCases`
    /// order.
    public static func condition(
        planes: inout [[Int32]]
    ) -> DTS714HeightOnsetConditioningReport {
        precondition(planes.count == 12, "DTS:X onset conditioner requires 12 planes")
        let sampleCount = planes.first?.count ?? 0
        precondition(
            planes.allSatisfy { $0.count == sampleCount },
            "DTS:X onset conditioner requires equal-length planes"
        )

        var headRampScaledSampleCount = 0
        for plane in heightPlaneIndices {
            let window = min(headRampSampleCount, sampleCount)
            for sample in 0..<window {
                let value = planes[plane][sample]
                guard value != 0 else { continue }
                let gainQ30 = (Int64(sample) << 30) / Int64(headRampSampleCount)
                let scaled = scaleQ30(Int64(value), by: gainQ30)
                if scaled != Int64(value) {
                    headRampScaledSampleCount += 1
                    planes[plane][sample] = Int32(scaled)
                }
            }
        }

        var hardOnsetCount = 0
        var softOnsetCount = 0
        var onsetScaledSampleCount = 0
        var maximumFirstBefore: Int64 = 0
        var maximumFirstAfter: Int64 = 0
        for plane in heightPlaneIndices {
            // Head-window onsets are already governed by the head ramp above;
            // fresh onset detection starts once the head ramp has fully
            // released. Content that is still active across the head-window
            // boundary is not an onset, so the silence run is seeded from the
            // actual samples immediately before the scan start.
            let scanStart = min(headRampSampleCount, sampleCount)
            var zeroRunLength = 0
            var seed = scanStart - 1
            while seed >= 0,
                  zeroRunLength < onsetSilenceSampleCount,
                  planes[plane][seed] == 0 {
                zeroRunLength += 1
                seed -= 1
            }
            if scanStart == 0 { zeroRunLength = onsetSilenceSampleCount }
            var sample = scanStart
            while sample < sampleCount {
                let value = planes[plane][sample]
                if value == 0 {
                    zeroRunLength += 1
                    sample += 1
                    continue
                }
                guard zeroRunLength >= onsetSilenceSampleCount else {
                    zeroRunLength = 0
                    sample += 1
                    continue
                }
                // Fresh onset at `sample`: hard when any sample of the onset
                // window escapes the reference-slew envelope
                // `E[k] = (k + 1) x fullScale / 480`.
                let window = min(onsetRampSampleCount, sampleCount - sample)
                var violatesEnvelope = false
                for offset in 0..<window {
                    let magnitude = Int64(abs(Int64(planes[plane][sample + offset])))
                    if magnitude * Int64(onsetRampSampleCount)
                        > Int64(offset + 1) * fullScaleMagnitude {
                        violatesEnvelope = true
                        break
                    }
                }
                let firstBefore = Int64(abs(Int64(value)))
                maximumFirstBefore = max(maximumFirstBefore, firstBefore)
                if violatesEnvelope {
                    hardOnsetCount += 1
                    for offset in 0..<window {
                        let raw = Int64(planes[plane][sample + offset])
                        guard raw != 0 else { continue }
                        let gainQ30 = (Int64(offset + 1) << 30)
                            / Int64(onsetRampSampleCount)
                        let scaled = scaleQ30(raw, by: gainQ30)
                        if scaled != raw {
                            onsetScaledSampleCount += 1
                            planes[plane][sample + offset] = Int32(scaled)
                        }
                    }
                } else {
                    softOnsetCount += 1
                }
                maximumFirstAfter = max(
                    maximumFirstAfter,
                    Int64(abs(Int64(planes[plane][sample])))
                )
                // Trailing zeros of the processed window count toward
                // re-arming the next onset detection.
                var trailingZeroCount = 0
                var trailing = sample + window - 1
                while trailing >= sample, planes[plane][trailing] == 0 {
                    trailingZeroCount += 1
                    trailing -= 1
                }
                zeroRunLength = trailingZeroCount
                sample += window
            }
        }

        return DTS714HeightOnsetConditioningReport(
            sampleCount: sampleCount,
            headRampSampleCount: headRampSampleCount,
            headRampScaledSampleCount: headRampScaledSampleCount,
            onsetRampSampleCount: onsetRampSampleCount,
            hardOnsetCount: hardOnsetCount,
            softOnsetCount: softOnsetCount,
            onsetScaledSampleCount: onsetScaledSampleCount,
            maximumOnsetFirstSampleMagnitudeBefore: maximumFirstBefore,
            maximumOnsetFirstSampleMagnitudeAfter: maximumFirstAfter
        )
    }

    @inline(__always)
    private static func scaleQ30(_ value: Int64, by gainQ30: Int64) -> Int64 {
        value >= 0
            ? (value * gainQ30 + (unityQ30 >> 1)) >> 30
            : -(((-value) * gainQ30 + (unityQ30 >> 1)) >> 30)
    }
}

/// The complete delivery-boundary source conditioning pipeline, shared by the
/// DTS:X encoder and every closed-loop verifier that compares a delivery
/// stream back to its 7.1.4 source. Order matters and must never drift
/// between the two sides: height-onset continuity first, then the
/// downstream-headroom composite guard over the conditioned planes.
public enum DTS714DeliverySourceConditioner {
    public struct Reports: Sendable, Equatable {
        public let onset: DTS714HeightOnsetConditioningReport
        public let renderGuard: DTS714RenderGuardReport
    }

    @discardableResult
    public static func condition(planes: inout [[Int32]]) -> Reports {
        let onset = DTS714HeightOnsetConditioner.condition(planes: &planes)
        let renderGuard = DTS714RenderGuard.apply(to: &planes)
        return Reports(onset: onset, renderGuard: renderGuard)
    }
}
