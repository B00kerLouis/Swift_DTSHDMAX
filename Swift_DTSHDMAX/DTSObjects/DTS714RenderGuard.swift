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
/// This guard measures every constraint and, only where a composite actually
/// exceeds the signed 24-bit range, applies one shared anticipatory gain
/// envelope to all twelve planes. The envelope approaches each overload no
/// faster than the reference renderer's slew (1/480 full scale per sample)
/// and releases at 1/4800 per sample, so protection itself cannot introduce
/// zipper steps. Content that never overloads any constraint passes through
/// bit-exact.
public struct DTS714RenderGuardReport: Sendable, Equatable, Codable {
    public let sampleCount: Int
    /// Samples where at least one individual plane exceeded signed 24-bit
    /// before guarding (the renderer's former silent `saturate24` site).
    public let planeOverloadSampleCount: Int
    /// Samples where a legacy Q15 height fold (`floor + q15(23170) x height`)
    /// exceeded signed 24-bit before guarding.
    public let foldOverloadSampleCount: Int
    /// Samples where a Core-residual recovery sum (`side + foldedRear`)
    /// exceeded signed 24-bit before guarding. This is the intermediate the
    /// reference decoder plays on first-frame recovery; it also bounds the
    /// hierarchy coefficient target that keeps the official constant matrix
    /// code 473 selected.
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
    static let positiveCeiling: Int64 = 8_388_607
    static let negativeFloor: Int64 = -8_388_608
    /// Rescale targets below the exact bounds absorb the +/-1 LSB rounding
    /// drift of re-quantizing each plane and re-evaluating the Q15 fold on
    /// the rescaled samples.
    static let positiveRescaleTarget: Int64 = 8_388_605
    static let negativeRescaleMagnitude: Int64 = 8_388_606

    static let q15HeightGain: Int64 = 23_170
    static let q15Half: Int64 = 1 << 14

    /// (floor, height) plane index pairs of the legacy Q15 compatibility
    /// fold, in `DTS714Channel.allCases` order.
    static let foldPairs: [(floor: Int, height: Int)] = [
        (0, 8),   // L   + Lfh
        (1, 9),   // R   + Rfh
        (6, 10),  // Lsr + Lrh
        (7, 11)   // Rsr + Rrh
    ]
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
            recoveryMaximum > positiveCeiling || recoveryMinimum < negativeFloor
        }
        var overloads: Bool { planeOverloads || foldOverloads || recoveryOverloads }
        var maximumMagnitude: Int64 {
            max(
                planeMaximum, -planeMinimum,
                foldMaximum, -foldMinimum,
                recoveryMaximum, -recoveryMinimum
            )
        }

        /// Q30 gain that brings every constraint back inside the signed
        /// 24-bit bounds with rounding margin; unity when nothing overloads.
        var requiredGainQ30: Int64 {
            var gain = unityQ30
            let positive = max(planeMaximum, foldMaximum, recoveryMaximum)
            if positive > positiveCeiling {
                gain = min(gain, (positiveRescaleTarget << 30) / positive)
            }
            let negative = min(planeMinimum, foldMinimum, recoveryMinimum)
            if negative < negativeFloor {
                gain = min(gain, (negativeRescaleMagnitude << 30) / -negative)
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
        precondition(planes.count == 12, "DTS:X render guard requires 12 planes")
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
            let extremes = constraintExtremes(planes, sample)
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
        // Forward release.
        for sample in 1..<sampleCount {
            let ramped = Int64(gains[sample - 1]) + releaseStepQ30
            if ramped < Int64(gains[sample]) { gains[sample] = Int32(min(ramped, unityQ30)) }
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
            for channel in 0..<12 {
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
            if planeEscapedBounds || constraintExtremes(planes, sample).overloads {
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
