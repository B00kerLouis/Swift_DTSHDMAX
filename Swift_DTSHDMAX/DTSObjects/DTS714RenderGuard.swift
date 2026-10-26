import Foundation

/// Downstream-headroom audit and protection for the rendered DTS:X 7.1.4
/// planes.
///
/// The twelve rendered planes are not the last linear stage before delivery:
/// the encoder folds every height feed into its floor feed at the official
/// Q15 -3.0103 dB coefficient for the public 7.1 compatibility bed, and the
/// Core-residual hierarchy additionally promises that the side + rear-with-
/// height sum is representable (the reference decoder plays
/// `clip23(Core x sqrt(2))` on first-frame recovery and computes the same
/// intermediate in steady state, and the hierarchy target
/// `Lss + coeff x LsrMix` must fit signed 24-bit for the official constant
/// matrix code 473 to stay in use).
///
/// A mix that keeps every individual plane inside signed 24-bit can still
/// overload those composites: a hot object mid-crossing between a floor and a
/// height loudspeaker peaks the fold at ~1.207x the object level, and a hot
/// object between the side and rear floor rows peaks the recovery sum at
/// ~1.414x. Left unguarded, the fold stage hard-clips sample by sample,
/// which the lossless XLL/XLL-X layers then deliver faithfully - audible as
/// clicks exactly on loud, fast-moving objects - and hot frames force the
/// hierarchy coefficient search away from the official constant matrix,
/// a per-frame grammar the reference corpus never exercises.
///
/// The Core-recovery constraint carries one additional reserve. What the
/// terminal actually plays during forced recovery is
/// `clip23(decodedCore x sqrt(2))`, and the *decoded* Core is the ideal
/// -3.0103 dB fold plus Core codec error, which peaks at loud transients -
/// exactly the hot starts and object onsets under investigation. An ideal
/// composite held at exact full scale therefore still hard-clips on
/// playback by the codec error (measured: a full-scale sine overshoots
/// ~136k LSBs, +0.14 dB, through the sqrt(2) recovery scale). Every
/// Core-mapped recovery value (C and LFE planes, the front L/R height
/// folds, and the side+rear recovery sums) is bounded at full scale minus
/// ``coreCodecErrorRecoveryReserve`` so recovery playback stays inside
/// signed 24-bit through the codec error at every stream start and seek
/// re-entry.
///
/// This guard measures every constraint and, only where a composite actually
/// exceeds its bound, applies one shared anticipatory gain envelope to all
/// twelve planes. The envelope approaches each overload no faster than the
/// reference renderer's slew (1/480 full scale per sample), holds its
/// deepest reduction for 10 ms after the last reduced sample (so sustained
/// periodic overloads scale by one flat plateau instead of a per-cycle
/// ripple the Core codec re-encodes as modulation error), and then releases
/// at 1/4800 per sample, so protection itself cannot introduce zipper
/// steps. Content that never overloads any constraint passes through
/// bit-exact.
public struct DTS714RenderGuardReport: Sendable, Equatable, Codable {
    public let sampleCount: Int
    /// Samples where at least one individual plane exceeded signed 24-bit
    /// before guarding (the renderer's former silent `saturate24` site).
    public let planeOverloadSampleCount: Int
    /// Samples where a legacy Q15 height fold (`floor + q15(23170) x height`)
    /// exceeded signed 24-bit before guarding.
    public let foldOverloadSampleCount: Int
    /// Samples where a Core-mapped recovery value (C or LFE plane, front
    /// L/R height fold, or `side + foldedRear` sum) exceeded the reserved
    /// recovery range (signed 24-bit minus the Core-codec-error reserve)
    /// before guarding. These are the intermediates the reference decoder
    /// plays as `clip23(decodedCore x sqrt(2))` on first-frame recovery;
    /// the side+rear sum also bounds the hierarchy coefficient target that
    /// keeps the official constant matrix code 473 selected.
    public let recoveryOverloadSampleCount: Int
    /// Samples where any constraint exceeded signed 24-bit before guarding.
    public let overloadSampleCount: Int
    /// Samples whose planes were actually rescaled (envelope below unity).
    public let gainReducedSampleCount: Int
    public let minimumGainQ30: Int64
    /// Largest pre-guard constraint magnitude observed anywhere.
    public let maximumCompositeMagnitude: Int64
    /// Largest per-sample envelope change that was applied. Bounded by the
    /// attack slew, this is the guard's own zipper metric.
    public let maximumGainStepQ30: Int64
    /// Post-guard hard-clip backstop engagements. Zero by construction; any
    /// nonzero value is a defect in the guard itself.
    public let residualClippedSampleCount: Int

    /// True when the guard did not change a single sample.
    public var isTransparent: Bool { gainReducedSampleCount == 0 }
    /// True when the guarded planes satisfy every downstream headroom
    /// constraint without any residual hard clipping.
    public var isHeadroomSafe: Bool { residualClippedSampleCount == 0 }
}

public enum DTS714RenderGuard {
    public static let unityQ30: Int64 = 1 << 30
    /// Matches the reference renderer's maximum gain slew of 1/480 full
    /// scale per sample (10 ms for a full-scale move at 48 kHz).
    public static let attackStepQ30: Int64 = (unityQ30 + 479) / 480
    /// Gentle 100 ms full-scale release keeps the envelope free of pumping.
    public static let releaseStepQ30: Int64 = unityQ30 / 4_800
    /// Samples the envelope stays at its deepest reduction after the last
    /// reduced sample before releasing (10 ms). A steady hot sine overloads
    /// once per half cycle; without the hold, the release recovered ~0.7%
    /// of full scale between consecutive peaks and the envelope turned into
    /// a per-cycle amplitude ripple. The fixed-allocation Core codec encodes
    /// that modulation poorly: the ripple measurably doubled the decoded
    /// Core error of a guarded full-scale sine (~282k vs ~136k LSBs through
    /// the sqrt(2) recovery scale), consuming exactly the reserve the
    /// recovery constraint exists to protect. With the hold, a periodic
    /// overload produces one flat gain plateau - a clean constant scale.
    public static let holdSampleCount = 480
    static let positiveCeiling: Int64 = 8_388_607
    static let negativeFloor: Int64 = -8_388_608
    /// Rescale targets below the exact bounds absorb the +/-1 LSB rounding
    /// drift of re-quantizing each plane and re-evaluating the Q15 fold on
    /// the rescaled samples.
    static let positiveRescaleTarget: Int64 = 8_388_605
    static let negativeRescaleMagnitude: Int64 = 8_388_606

    /// Headroom reserved on every Core-mapped recovery value for Core codec
    /// error. The terminal's forced recovery plays
    /// `clip23(decodedCore x sqrt(2))`, and the decoded Core carries codec
    /// error on top of the ideal fold, so an ideal composite at exact full
    /// scale still clips on playback. The worst measured overshoot is the
    /// FULLSCALE_C controllable vector - a full-scale Nyquist square wave,
    /// the digital worst case for the fixed-allocation Core - at ~282k LSBs
    /// (~3.4% of level) through the sqrt(2) recovery scale, and the error is
    /// quantizer-alignment sensitive rather than level-proportional.
    /// 458,752 LSBs (-0.49 dB, ~5.5% of full scale) covers the measured
    /// worst case with ~1.6x margin. Only content within the reserve of
    /// full scale on a Core-mapped constraint is touched; everything else
    /// passes bit-exact.
    public static let coreCodecErrorRecoveryReserve: Int64 = 458_752
    static let recoveryPositiveCeiling = positiveCeiling - coreCodecErrorRecoveryReserve
    static let recoveryNegativeFloor = negativeFloor + coreCodecErrorRecoveryReserve
    static let recoveryPositiveRescaleTarget =
        positiveRescaleTarget - coreCodecErrorRecoveryReserve
    static let recoveryNegativeRescaleMagnitude =
        negativeRescaleMagnitude - coreCodecErrorRecoveryReserve

    static let q15HeightGain: Int64 = 23_170
    static let q15Half: Int64 = 1 << 14

    /// (floor, height) plane index pairs of the legacy Q15 compatibility
    /// fold, in `DTS714Channel.allCases` order. The front pairs are the
    /// recovery playback values for Core L and R and therefore also enter
    /// the reserved recovery constraint.
    static let foldPairs: [(floor: Int, height: Int, feedsCoreFront: Bool)] = [
        (0, 8, true),    // L   + Lfh -> Core L
        (1, 9, true),    // R   + Rfh -> Core R
        (6, 10, false),  // Lsr + Lrh (enters Core Ls via the recovery sum)
        (7, 11, false)   // Rsr + Rrh (enters Core Rs via the recovery sum)
    ]
    /// Core-mapped pass-through planes (C, LFE) whose recovery playback is
    /// the plane value itself.
    static let recoveryPassThroughPlanes: [Int] = [2, 3]
    /// (side, foldedRear) construction of the Core-residual recovery sum.
    static let recoveryPairs: [(side: Int, rearFloor: Int, rearHeight: Int)] = [
        (4, 6, 10), // Lss + fold(Lsr, Lrh)
        (5, 7, 11)  // Rss + fold(Rsr, Rrh)
    ]

    @inline(__always)
    static func q15Fold(_ floor: Int64, _ height: Int64) -> Int64 {
        floor + ((height * q15HeightGain + q15Half) >> 15)
    }

    struct ConstraintExtremes {
        var planeMinimum: Int64 = 0
        var planeMaximum: Int64 = 0
        var foldMinimum: Int64 = 0
        var foldMaximum: Int64 = 0
        var recoveryMinimum: Int64 = 0
        var recoveryMaximum: Int64 = 0

        var planeOverloads: Bool {
            planeMaximum > positiveCeiling || planeMinimum < negativeFloor
        }
        var foldOverloads: Bool {
            foldMaximum > positiveCeiling || foldMinimum < negativeFloor
        }
        var recoveryOverloads: Bool {
            recoveryMaximum > recoveryPositiveCeiling
                || recoveryMinimum < recoveryNegativeFloor
        }
        var overloads: Bool { planeOverloads || foldOverloads || recoveryOverloads }
        var maximumMagnitude: Int64 {
            max(
                planeMaximum, -planeMinimum,
                foldMaximum, -foldMinimum,
                recoveryMaximum, -recoveryMinimum
            )
        }

        /// Q30 gain that brings every constraint back inside its bound with
        /// rounding margin (signed 24-bit for planes and folds, the reserved
        /// recovery range for Core-mapped recovery values); unity when
        /// nothing overloads.
        var requiredGainQ30: Int64 {
            var gain = unityQ30
            let positive = max(planeMaximum, foldMaximum)
            if positive > positiveCeiling {
                gain = min(gain, (positiveRescaleTarget << 30) / positive)
            }
            let negative = min(planeMinimum, foldMinimum)
            if negative < negativeFloor {
                gain = min(gain, (negativeRescaleMagnitude << 30) / -negative)
            }
            if recoveryMaximum > recoveryPositiveCeiling {
                gain = min(gain, (recoveryPositiveRescaleTarget << 30) / recoveryMaximum)
            }
            if recoveryMinimum < recoveryNegativeFloor {
                gain = min(gain, (recoveryNegativeRescaleMagnitude << 30) / -recoveryMinimum)
            }
            return gain
        }
    }

    /// Downstream-constraint extremes for one sample of the twelve
    /// (pre-guard, unsaturated) mixed planes.
    @inline(__always)
    static func constraintExtremes(
        _ planes: [[Int32]],
        _ sample: Int
    ) -> ConstraintExtremes {
        var extremes = ConstraintExtremes()
        for channel in 0..<12 {
            let value = Int64(planes[channel][sample])
            extremes.planeMinimum = min(extremes.planeMinimum, value)
            extremes.planeMaximum = max(extremes.planeMaximum, value)
        }
        for pair in foldPairs {
            let fold = q15Fold(
                Int64(planes[pair.floor][sample]),
                Int64(planes[pair.height][sample])
            )
            extremes.foldMinimum = min(extremes.foldMinimum, fold)
            extremes.foldMaximum = max(extremes.foldMaximum, fold)
            if pair.feedsCoreFront {
                extremes.recoveryMinimum = min(extremes.recoveryMinimum, fold)
                extremes.recoveryMaximum = max(extremes.recoveryMaximum, fold)
            }
        }
        for plane in recoveryPassThroughPlanes {
            let value = Int64(planes[plane][sample])
            extremes.recoveryMinimum = min(extremes.recoveryMinimum, value)
            extremes.recoveryMaximum = max(extremes.recoveryMaximum, value)
        }
        for pair in recoveryPairs {
            let foldedRear = q15Fold(
                Int64(planes[pair.rearFloor][sample]),
                Int64(planes[pair.rearHeight][sample])
            )
            let recovery = Int64(planes[pair.side][sample]) + foldedRear
            extremes.recoveryMinimum = min(extremes.recoveryMinimum, recovery)
            extremes.recoveryMaximum = max(extremes.recoveryMaximum, recovery)
        }
        return extremes
    }

    /// Guards the twelve mixed planes in place. Planes must be in
    /// `DTS714Channel.allCases` order and may carry pre-saturation values in
    /// the full `Int32` range.
    public static func apply(to planes: inout [[Int32]]) -> DTS714RenderGuardReport {
        apply(to: &planes, imax: false)
    }

    /// Reuses the qualified attack/hold/release envelope with the IMAX fold
    /// constraints. The standard twelve-plane arithmetic stays unchanged.
    static func apply(to planes: inout [[Int32]], imax: Bool) -> DTS714RenderGuardReport {
        precondition(planes.count == (imax ? 13 : 12), "DTS:X render guard plane count is invalid")
        return apply(to: &planes) { values,sample in
            imax ? DTSIMAXCompatibilityBedRenderer.constraintExtremes(values,sample) : constraintExtremes(values,sample)
        }
    }

    static func apply(to planes: inout [[Int32]], channelFormat: DTSXChannelFormat) -> DTS714RenderGuardReport {
        precondition(planes.count == channelFormat.channelNames.count)
        return apply(to: &planes) { values,sample in
            var result = ConstraintExtremes()
            for plane in values {
                let value = Int64(plane[sample])
                result.planeMinimum = min(result.planeMinimum,value)
                result.planeMaximum = max(result.planeMaximum,value)
            }
            let bed = channelFormat.compatibilityValues(values,at: sample)
            for value in bed {
                result.foldMinimum = min(result.foldMinimum,value)
                result.foldMaximum = max(result.foldMaximum,value)
                result.recoveryMinimum = min(result.recoveryMinimum,value)
                result.recoveryMaximum = max(result.recoveryMaximum,value)
            }
            if channelFormat.bedChannelCount == 8 {
                for value in [bed[4]+bed[6],bed[5]+bed[7]] {
                    result.recoveryMinimum = min(result.recoveryMinimum,value)
                    result.recoveryMaximum = max(result.recoveryMaximum,value)
                }
            }
            return result
        }
    }

    private static func apply(to planes: inout [[Int32]],
                              constraints: ([[Int32]],Int) -> ConstraintExtremes) -> DTS714RenderGuardReport {
        let sampleCount = planes.first?.count ?? 0
        precondition(
            planes.allSatisfy { $0.count == sampleCount },
            "DTS:X render guard requires equal-length planes"
        )

        var planeOverloads = 0
        var foldOverloads = 0
        var recoveryOverloads = 0
        var overloads = 0
        var maximumComposite: Int64 = 0
        // Q30 gains fit Int32 (unity = 2^30 < 2^31 - 1).
        var gains = [Int32](repeating: Int32(unityQ30), count: sampleCount)
        var anyOverload = false
        for sample in 0..<sampleCount {
            let extremes = constraints(planes,sample)
            maximumComposite = max(maximumComposite, extremes.maximumMagnitude)
            guard extremes.overloads else { continue }
            if extremes.planeOverloads { planeOverloads += 1 }
            if extremes.foldOverloads { foldOverloads += 1 }
            if extremes.recoveryOverloads { recoveryOverloads += 1 }
            overloads += 1
            anyOverload = true
            gains[sample] = Int32(extremes.requiredGainQ30)
        }

        guard anyOverload else {
            return DTS714RenderGuardReport(
                sampleCount: sampleCount,
                planeOverloadSampleCount: 0,
                foldOverloadSampleCount: 0,
                recoveryOverloadSampleCount: 0,
                overloadSampleCount: 0,
                gainReducedSampleCount: 0,
                minimumGainQ30: unityQ30,
                maximumCompositeMagnitude: maximumComposite,
                maximumGainStepQ30: 0,
                residualClippedSampleCount: 0
            )
        }

        // Anticipatory attack: approaching any overload no faster than the
        // reference slew, reaching the exact required gain on the overloaded
        // sample itself.
        var sample = sampleCount - 2
        while sample >= 0 {
            let ramped = Int64(gains[sample + 1]) + attackStepQ30
            if ramped < Int64(gains[sample]) { gains[sample] = Int32(min(ramped, unityQ30)) }
            sample -= 1
        }
        // Forward hold-and-release: any reduced sample re-arms the hold at
        // the deepest reduction seen, so periodic overloads (a steady hot
        // sine peaking every half cycle) hold one flat plateau instead of
        // rippling with the release between peaks; see ``holdSampleCount``.
        // Gains only ever move down here, so every per-sample requirement
        // stays satisfied, and the plateau/release shape keeps the final
        // per-sample step inside the attack bound.
        var heldGain = unityQ30
        var holdRemaining = 0
        for sample in 0..<sampleCount {
            let gain = Int64(gains[sample])
            if gain < unityQ30 {
                heldGain = min(heldGain, gain)
                holdRemaining = holdSampleCount
            } else if holdRemaining > 0 {
                holdRemaining -= 1
            } else if heldGain < unityQ30 {
                heldGain = min(unityQ30, heldGain + releaseStepQ30)
            }
            if heldGain < Int64(gains[sample]) { gains[sample] = Int32(heldGain) }
        }

        var gainReduced = 0
        var minimumGain = unityQ30
        var maximumGainStep: Int64 = 0
        var residualClipped = 0
        var previousGain = unityQ30
        for sample in 0..<sampleCount {
            let gain = Int64(gains[sample])
            maximumGainStep = max(maximumGainStep, Swift.abs(gain - previousGain))
            previousGain = gain
            guard gain < unityQ30 else { continue }
            gainReduced += 1
            minimumGain = min(minimumGain, gain)
            var planeEscapedBounds = false
            for channel in planes.indices {
                let value = Int64(planes[channel][sample])
                let scaled = value >= 0
                    ? (value * gain + (unityQ30 >> 1)) >> 30
                    : -(((-value) * gain + (unityQ30 >> 1)) >> 30)
                if scaled > positiveCeiling || scaled < negativeFloor {
                    planeEscapedBounds = true
                }
                planes[channel][sample] = Int32(clamping: min(
                    positiveCeiling,
                    max(negativeFloor, scaled)
                ))
            }
            // Every constraint must close after rescaling; the targets leave
            // margin for the per-plane and in-fold rounding, so a violation
            // here is a guard defect rather than expected behavior.
            let remaining = constraints(planes,sample)
            if planeEscapedBounds || remaining.overloads {
                residualClipped += 1
            }
        }

        return DTS714RenderGuardReport(
            sampleCount: sampleCount,
            planeOverloadSampleCount: planeOverloads,
            foldOverloadSampleCount: foldOverloads,
            recoveryOverloadSampleCount: recoveryOverloads,
            overloadSampleCount: overloads,
            gainReducedSampleCount: gainReduced,
            minimumGainQ30: minimumGain,
            maximumCompositeMagnitude: maximumComposite,
            maximumGainStepQ30: maximumGainStep,
            residualClippedSampleCount: residualClipped
        )
    }
}

/// The complete delivery-boundary source conditioning pipeline, shared by the
/// DTS:X encoder and every closed-loop verifier that compares a delivery
/// stream back to its 7.1.4 source.
///
/// The pipeline conditions sources only against *proven downstream
/// contracts* (plane range, legacy Q15 height fold, Core-residual recovery
/// composite - ``DTS714RenderGuard``), and is therefore bit-exact
/// passthrough for every in-headroom source: delivery and differential
/// bypass encodes of such sources are byte-identical. Onset shaping does
/// not belong here: the previous delivery-boundary height-onset conditioner
/// (programme-head ramp plus plane-level silence-to-active slew) measurably
/// *increased* hardware pops - it could not reach the floor contributions
/// of hot objects that feed the Core first-frame-recovery burst, and its
/// 72-AU head ramp manufactured exactly the quiet-content small-parameter
/// entropy regime that terminals already misparsed once. Object-onset
/// continuity is owned by ``DTS714Renderer``/``DTS714ObjectGainSmoother``,
/// the stage that knows the Atmos object structure.
public enum DTS714DeliverySourceConditioner {
    @discardableResult
    public static func condition(planes: inout [[Int32]]) -> DTS714RenderGuardReport {
        DTS714RenderGuard.apply(to: &planes)
    }
}
