import Foundation

public struct DTS714ObjectGainSmoothingVerificationReport:
    Sendable, Equatable, Codable {
    public let nominalPanSubBlockSampleCount: Int
    public let largeMoveTransitionSampleCount: Int
    public let smallMoveTransitionSampleCount: Int
    public let unsmoothedMaximumGainStepQ30: Int64
    public let maximumObservedGainStepQ30: Int64
    public let maximumAllowedGainStepQ30: Int64
    public let gainStepReductionFactor: Double
    public let changedHeightChannelCount: Int
    public let firstTargetReachedExactly: Bool
    public let retargetInstallIsContinuous: Bool
    public let retargetTargetReachedExactly: Bool
    public let fadeOutReachedDigitalSilence: Bool
    /// An above-unity gain delta (positive object gain trim) must still obey
    /// the per-sample slew bound instead of stepping faster than 1/480; the
    /// window stretches beyond 480 samples only in that case.
    public let aboveUnityDeltaTransitionSampleCount: Int
    public let aboveUnityDeltaStepWithinBound: Bool
    public let isVerified: Bool
}

/// Regression for the renderer-side failure that made fast Atmos objects
/// zipper between 7.1.4 speakers.  It uses only the native panner and Q30
/// smoother; no media decoder participates in the result.
public enum DTS714ObjectGainSmoothingVerifier {
    private static let q30: Int64 = 1 << 30

    public static func verify() -> DTS714ObjectGainSmoothingVerificationReport {
        let nominalPeriod = DTS714ObjectGainSmoother.defaultPanSubBlockSampleCount
        let maximumAllowedStep = (q30
            + Int64(DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount - 1))
            / Int64(DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount)

        let first = gains(x: -1, y: 1, z: 1)
        let second = gains(x: 1, y: -1, z: 1)
        let third = gains(x: -1, y: -1, z: 1)
        let firstDense = dense(first)
        let secondDense = dense(second)
        let unsmoothedMaximumStep = zip(firstDense, secondDense).reduce(Int64(0)) {
            max($0, Swift.abs($1.1 - $1.0))
        }
        var smoother = DTS714ObjectGainSmoother()
        smoother.setImmediately(first)
        smoother.retarget(second, over: nominalPeriod)
        let largeMoveTransitionSampleCount = smoother.maximumRemainingSampleCount

        var previous = smoother.currentGains
        var maximumObservedStep: Int64 = 0
        var changedHeightChannels = Set<Int>()
        while smoother.isTransitioning {
            smoother.advance()
            observeStep(
                from: previous,
                to: smoother.currentGains,
                maximum: &maximumObservedStep,
                changedHeightChannels: &changedHeightChannels
            )
            previous = smoother.currentGains
        }
        let firstTargetReachedExactly = smoother.currentGains == dense(second)

        // A small move should use the ordinary 250-sample pan-sub-block ramp,
        // rather than the 480-sample maximum-slew path.
        var smallMove = DTS714ObjectGainSmoother()
        smallMove.setImmediately(gains(x: -0.1, y: 0, z: 1))
        smallMove.retarget(gains(x: 0.1, y: 0, z: 1), over: nominalPeriod)
        let smallMoveTransitionSampleCount = smallMove.maximumRemainingSampleCount

        // Retarget while moving and prove that installing the new target does
        // not itself alter a gain. Only the following bounded ramp sample may
        // move it.
        smoother.setImmediately(first)
        smoother.retarget(second, over: nominalPeriod)
        for _ in 0..<125 { smoother.advance() }
        let beforeRetarget = smoother.currentGains
        smoother.retarget(third, over: nominalPeriod)
        let retargetInstallIsContinuous = smoother.currentGains == beforeRetarget
        previous = smoother.currentGains
        while smoother.isTransitioning {
            smoother.advance()
            observeStep(
                from: previous,
                to: smoother.currentGains,
                maximum: &maximumObservedStep,
                changedHeightChannels: &changedHeightChannels
            )
            previous = smoother.currentGains
        }
        let retargetTargetReachedExactly = smoother.currentGains == dense(third)

        smoother.retarget([], over: nominalPeriod)
        previous = smoother.currentGains
        while smoother.isTransitioning {
            smoother.advance()
            observeStep(
                from: previous,
                to: smoother.currentGains,
                maximum: &maximumObservedStep,
                changedHeightChannels: &changedHeightChannels
            )
            previous = smoother.currentGains
        }
        let fadeOutReachedDigitalSilence = smoother.isSilent
            && smoother.currentGains.allSatisfy { $0 == 0 }

        // Above-unity delta (positive gain trim): a plain fixed-480 period
        // would step faster than the reference bound, so the window must
        // stretch to the reference-rate length there while every ordinary
        // (at-or-below-unity) slew-limited move keeps the fixed 480-sample
        // window hardware measured as least-bad.
        var aboveUnity = DTS714ObjectGainSmoother()
        let aboveUnityTarget: [(outputIndex: Int, q30: Int64)] = [(8, 2 * q30)]
        aboveUnity.retarget(aboveUnityTarget, over: nominalPeriod)
        let aboveUnityDeltaTransitionSampleCount =
            aboveUnity.maximumRemainingSampleCount
        var aboveUnityMaximumStep: Int64 = 0
        previous = aboveUnity.currentGains
        while aboveUnity.isTransitioning {
            aboveUnity.advance()
            var unusedChannels = Set<Int>()
            observeStep(
                from: previous,
                to: aboveUnity.currentGains,
                maximum: &aboveUnityMaximumStep,
                changedHeightChannels: &unusedChannels
            )
            previous = aboveUnity.currentGains
        }
        let aboveUnityReached = aboveUnity.currentGains[8] == 2 * q30

        let verified = largeMoveTransitionSampleCount
                == DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount
            && smallMoveTransitionSampleCount == nominalPeriod
            && maximumObservedStep <= maximumAllowedStep
            && changedHeightChannels.count == 4
            && firstTargetReachedExactly
            && retargetInstallIsContinuous
            && retargetTargetReachedExactly
            && fadeOutReachedDigitalSilence
            && aboveUnityDeltaTransitionSampleCount
                == expectedTransitionSampleCount(
                    from: Array(
                        repeating: Int64(0),
                        count: DTS714ObjectGainSmoother.channelCount
                    ),
                    to: dense(aboveUnityTarget),
                    requestedPeriod: nominalPeriod
                )
            && aboveUnityMaximumStep <= maximumAllowedStep
            && aboveUnityReached
        return DTS714ObjectGainSmoothingVerificationReport(
            nominalPanSubBlockSampleCount: nominalPeriod,
            largeMoveTransitionSampleCount: largeMoveTransitionSampleCount,
            smallMoveTransitionSampleCount: smallMoveTransitionSampleCount,
            unsmoothedMaximumGainStepQ30: unsmoothedMaximumStep,
            maximumObservedGainStepQ30: maximumObservedStep,
            maximumAllowedGainStepQ30: maximumAllowedStep,
            gainStepReductionFactor: Double(unsmoothedMaximumStep)
                / Double(max(1, maximumObservedStep)),
            changedHeightChannelCount: changedHeightChannels.count,
            firstTargetReachedExactly: firstTargetReachedExactly,
            retargetInstallIsContinuous: retargetInstallIsContinuous,
            retargetTargetReachedExactly: retargetTargetReachedExactly,
            fadeOutReachedDigitalSilence: fadeOutReachedDigitalSilence,
            aboveUnityDeltaTransitionSampleCount: aboveUnityDeltaTransitionSampleCount,
            aboveUnityDeltaStepWithinBound: aboveUnityMaximumStep <= maximumAllowedStep,
            isVerified: verified
        )
    }

    /// Expected transition length under the delivered smoother semantics:
    /// the requested period; or, when the requested rate exceeds 1/480 full
    /// scale per sample, the fixed 480-sample slew window, stretched to
    /// `ceil(|delta| x 480 / 2^30)` only for above-unity deltas so no step
    /// exceeds the reference bound. Maximum across channels.
    private static func expectedTransitionSampleCount(
        from start: [Int64],
        to target: [Int64],
        requestedPeriod: Int
    ) -> Int {
        let slew = Int64(DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount)
        var maximum = 0
        for channel in start.indices {
            let delta = Swift.abs(target[channel] - start[channel])
            guard delta != 0 else { continue }
            let period: Int
            if delta * slew > q30 * Int64(requestedPeriod) {
                period = max(
                    DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount,
                    Int((delta * slew + q30 - 1) / q30)
                )
            } else {
                period = requestedPeriod
            }
            maximum = max(maximum, period)
        }
        return maximum
    }

    private static func gains(
        x: Double,
        y: Double,
        z: Double
    ) -> [(outputIndex: Int, q30: Int64)] {
        var state = AtmosObjectState(elementID: 1)
        state.active = true
        state.position = AtmosPosition(x: x, y: y, z: z)
        return DTS714VBAPPanner.gains(for: state)
    }

    private static func dense(
        _ sparse: [(outputIndex: Int, q30: Int64)]
    ) -> [Int64] {
        var result = Array(
            repeating: Int64(0),
            count: DTS714ObjectGainSmoother.channelCount
        )
        for gain in sparse { result[gain.outputIndex] = gain.q30 }
        return result
    }

    private static func observeStep(
        from previous: [Int64],
        to current: [Int64],
        maximum: inout Int64,
        changedHeightChannels: inout Set<Int>
    ) {
        for channel in current.indices {
            let delta = Swift.abs(current[channel] - previous[channel])
            maximum = max(maximum, delta)
            if channel >= 8, delta != 0 { changedHeightChannels.insert(channel) }
        }
    }
}
