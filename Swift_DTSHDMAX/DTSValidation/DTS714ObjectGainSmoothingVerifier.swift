import Foundation

public struct DTS714ObjectGainSmoothingVerificationReport:
    Sendable, Equatable, Codable {
    public let nominalPanSubBlockSampleCount: Int
    public let largeMoveTransitionSampleCount: Int
    public let largeMoveReferenceRateSampleCount: Int
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
    /// Programme-start contract: gains begin at silence and approach the
    /// initial declarations at exactly the reference maximum slew.
    public let startFromSilenceTransitionSampleCount: Int
    public let startFromSilenceReferenceRateSampleCount: Int
    public let startFromSilenceStepWithinBound: Bool
    public let startFromSilenceTargetReachedExactly: Bool
    /// An above-unity gain delta (positive object gain trim) must still obey
    /// the per-sample slew bound instead of stepping faster than 1/480.
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

        // Programme start: silence to the initial declarations at exactly
        // the reference maximum slew (the renderer's `beginFromSilence`).
        var startSmoother = DTS714ObjectGainSmoother()
        startSmoother.beginFromSilence(first)
        let startFromSilenceTransitionSampleCount =
            startSmoother.maximumRemainingSampleCount
        let startFromSilenceReferenceRateSampleCount =
            referenceRateSampleCount(from: Array(
                repeating: Int64(0),
                count: DTS714ObjectGainSmoother.channelCount
            ), to: firstDense)
        var startMaximumStep: Int64 = 0
        previous = startSmoother.currentGains
        while startSmoother.isTransitioning {
            startSmoother.advance()
            var unusedChannels = Set<Int>()
            observeStep(
                from: previous,
                to: startSmoother.currentGains,
                maximum: &startMaximumStep,
                changedHeightChannels: &unusedChannels
            )
            previous = startSmoother.currentGains
        }
        let startFromSilenceTargetReachedExactly =
            startSmoother.currentGains == firstDense

        // Above-unity delta (positive gain trim): the fixed-480 period would
        // have stepped faster than the reference bound; the rate-exact
        // period must keep every step inside it.
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

        let largeMoveExpected = referenceRateSampleCount(
            from: firstDense,
            to: secondDense,
            requestedPeriod: nominalPeriod
        )
        let verified = largeMoveTransitionSampleCount == largeMoveExpected
            && smallMoveTransitionSampleCount == nominalPeriod
            && maximumObservedStep <= maximumAllowedStep
            && changedHeightChannels.count == 4
            && firstTargetReachedExactly
            && retargetInstallIsContinuous
            && retargetTargetReachedExactly
            && fadeOutReachedDigitalSilence
            && startFromSilenceTransitionSampleCount
                == startFromSilenceReferenceRateSampleCount
            && startFromSilenceTransitionSampleCount
                <= DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount
            && startMaximumStep <= maximumAllowedStep
            && startFromSilenceTargetReachedExactly
            && aboveUnityDeltaTransitionSampleCount
                == referenceRateSampleCount(
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
            largeMoveReferenceRateSampleCount: largeMoveExpected,
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
            startFromSilenceTransitionSampleCount:
                startFromSilenceTransitionSampleCount,
            startFromSilenceReferenceRateSampleCount:
                startFromSilenceReferenceRateSampleCount,
            startFromSilenceStepWithinBound: startMaximumStep <= maximumAllowedStep,
            startFromSilenceTargetReachedExactly: startFromSilenceTargetReachedExactly,
            aboveUnityDeltaTransitionSampleCount: aboveUnityDeltaTransitionSampleCount,
            aboveUnityDeltaStepWithinBound: aboveUnityMaximumStep <= maximumAllowedStep,
            isVerified: verified
        )
    }

    /// Expected transition length under the reference semantics: the
    /// requested period, stretched per channel to `ceil(|delta| x 480 /
    /// 2^30)` wherever the requested rate would exceed 1/480 full scale per
    /// sample, then the maximum across channels. For a maximum-rate start
    /// (requested period 1) this is the pure rate-exact length.
    private static func referenceRateSampleCount(
        from start: [Int64],
        to target: [Int64],
        requestedPeriod: Int = 1
    ) -> Int {
        let slew = Int64(DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount)
        var maximum = 0
        for channel in start.indices {
            let delta = Swift.abs(target[channel] - start[channel])
            guard delta != 0 else { continue }
            let period: Int
            if delta * slew > q30 * Int64(requestedPeriod) {
                period = Int((delta * slew + q30 - 1) / q30)
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
