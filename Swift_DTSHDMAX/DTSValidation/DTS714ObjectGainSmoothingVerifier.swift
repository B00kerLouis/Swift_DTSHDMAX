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

        let verified = largeMoveTransitionSampleCount
                == DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount
            && smallMoveTransitionSampleCount == nominalPeriod
            && maximumObservedStep <= maximumAllowedStep
            && changedHeightChannels.count == 4
            && firstTargetReachedExactly
            && retargetInstallIsContinuous
            && retargetTargetReachedExactly
            && fadeOutReachedDigitalSilence
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
            isVerified: verified
        )
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
