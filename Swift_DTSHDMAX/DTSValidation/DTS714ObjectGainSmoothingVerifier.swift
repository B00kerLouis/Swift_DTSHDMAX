import Foundation

public struct DTS714ObjectGainSmoothingVerificationReport:
    Sendable, Equatable, Codable {
    public let nominalPanSubBlockSampleCount: Int
    public let largeMoveTransitionSampleCount: Int
    public let smallMoveTransitionSampleCount: Int
    public let heightLargeMoveTransitionSampleCount: Int
    public let heightSmallMoveTransitionSampleCount: Int
    public let unsmoothedMaximumGainStepQ30: Int64
    public let maximumObservedGainStepQ30: Int64
    public let maximumAllowedGainStepQ30: Int64
    public let gainStepReductionFactor: Double
    public let changedHeightChannelCount: Int
    public let firstTargetReachedExactly: Bool
    public let retargetInstallIsContinuous: Bool
    public let retargetTargetReachedExactly: Bool
    public let fadeOutReachedDigitalSilence: Bool
    /// Fast Top Surround crossing: an object driven across the height layer
    /// at one pan sub-block per update, which is the automation density that
    /// made height motion sound stepped.
    public let topSurroundCrossing: DTS714HeightCrossingVerificationReport
    /// The same trajectory taken at floor level, proving the tighter height
    /// contract did not disturb bed panning.
    public let floorCrossing: DTS714HeightCrossingVerificationReport
    public let isVerified: Bool
}

/// Per-vector result for a continuously retargeted object trajectory.
public struct DTS714HeightCrossingVerificationReport:
    Sendable, Equatable, Codable {
    public let name: String
    public let updateCount: Int
    public let sampleCount: Int
    public let maximumHeightStepQ30: Int64
    public let maximumFloorStepQ30: Int64
    public let maximumAllowedHeightStepQ30: Int64
    public let maximumAllowedFloorStepQ30: Int64
    /// Largest gain change caused by installing a target rather than by a
    /// bounded ramp sample. Any non-zero value is an audible discontinuity.
    public let maximumRetargetInstallStepQ30: Int64
    /// Largest change in per-sample slope across the whole trajectory. The
    /// stepped-motion complaint is a first-order discontinuity, so this is
    /// bounded independently of the gain step itself.
    public let maximumHeightSlopeChangeQ30: Int64
    public let maximumAllowedHeightSlopeChangeQ30: Int64
    public let touchedHeightChannelCount: Int
    public let settledExactlyOnFinalTarget: Bool
    public let isVerified: Bool
}

/// Regression for the renderer-side failure that made fast Atmos objects
/// zipper between 7.1.4 speakers.  It uses only the native panner and Q30
/// smoother; no media decoder participates in the result.
public enum DTS714ObjectGainSmoothingVerifier {
    private static let q30: Int64 = 1 << 30

    private static var maximumAllowedFloorStep: Int64 {
        ceilingDivide(q30, DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount)
    }

    private static var maximumAllowedHeightStep: Int64 {
        ceilingDivide(
            q30,
            DTS714ObjectGainSmoother.maximumHeightSlewTransitionSampleCount
        )
    }

    public static func verify() -> DTS714ObjectGainSmoothingVerificationReport {
        let nominalPeriod = DTS714ObjectGainSmoother.defaultPanSubBlockSampleCount
        let maximumAllowedStep = maximumAllowedFloorStep

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
        let heightLargeMoveTransitionSampleCount = smoother.maximumRemainingSampleCount

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

        // A small floor move should still use the ordinary 250-sample pan
        // sub-block ramp rather than the maximum-slew path.
        var smallMove = DTS714ObjectGainSmoother()
        smallMove.setImmediately(gains(x: -0.1, y: 0, z: 0))
        smallMove.retarget(gains(x: 0.1, y: 0, z: 0), over: nominalPeriod)
        let smallMoveTransitionSampleCount = smallMove.maximumRemainingSampleCount

        // A large floor-only move keeps the 480-sample reference ceiling.
        var floorLargeMove = DTS714ObjectGainSmoother()
        floorLargeMove.setImmediately(gains(x: -1, y: 1, z: 0))
        floorLargeMove.retarget(gains(x: 1, y: -1, z: 0), over: nominalPeriod)
        let largeMoveTransitionSampleCount = floorLargeMove.maximumRemainingSampleCount

        // Even a small height move is spread over the height minimum so that
        // consecutive pan sub-blocks overlap instead of restarting.
        var heightSmallMove = DTS714ObjectGainSmoother()
        heightSmallMove.setImmediately(gains(x: -0.05, y: 0, z: 1))
        heightSmallMove.retarget(gains(x: 0.05, y: 0, z: 1), over: nominalPeriod)
        let heightSmallMoveTransitionSampleCount =
            heightSmallMove.maximumRemainingSampleCount

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

        // Two full traversals of the room in one second at ceiling height.
        // Every pan sub-block installs a new target, which is the density the
        // authoring profile allows and the case that sounded stepped.
        let topSurround = verifyCrossing(
            name: "top-surround-fast-crossing",
            elevation: 1,
            updateCount: 384,
            periodSampleCount: nominalPeriod
        )
        let floor = verifyCrossing(
            name: "floor-fast-crossing",
            elevation: 0,
            updateCount: 384,
            periodSampleCount: nominalPeriod
        )

        let verified = largeMoveTransitionSampleCount
                == DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount
            && heightLargeMoveTransitionSampleCount
                == DTS714ObjectGainSmoother.maximumHeightSlewTransitionSampleCount
            && smallMoveTransitionSampleCount == nominalPeriod
            && heightSmallMoveTransitionSampleCount
                == DTS714ObjectGainSmoother.minimumHeightTransitionSampleCount
            && maximumObservedStep <= maximumAllowedStep
            && changedHeightChannels.count == 4
            && firstTargetReachedExactly
            && retargetInstallIsContinuous
            && retargetTargetReachedExactly
            && fadeOutReachedDigitalSilence
            && topSurround.isVerified
            && floor.isVerified
        return DTS714ObjectGainSmoothingVerificationReport(
            nominalPanSubBlockSampleCount: nominalPeriod,
            largeMoveTransitionSampleCount: largeMoveTransitionSampleCount,
            smallMoveTransitionSampleCount: smallMoveTransitionSampleCount,
            heightLargeMoveTransitionSampleCount: heightLargeMoveTransitionSampleCount,
            heightSmallMoveTransitionSampleCount: heightSmallMoveTransitionSampleCount,
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
            topSurroundCrossing: topSurround,
            floorCrossing: floor,
            isVerified: verified
        )
    }

    /// Drives one object along a fast serpentine trajectory, installing a new
    /// panner target every `periodSampleCount` samples, and bounds both the
    /// per-sample gain step and the per-sample slope change of every feed.
    private static func verifyCrossing(
        name: String,
        elevation: Double,
        updateCount: Int,
        periodSampleCount: Int
    ) -> DTS714HeightCrossingVerificationReport {
        var smoother = DTS714ObjectGainSmoother()
        smoother.setImmediately(gains(x: -1, y: 1, z: elevation))

        var previous = smoother.currentGains
        var previousStep = Array(
            repeating: Int64(0),
            count: DTS714ObjectGainSmoother.channelCount
        )
        var maximumHeightStep: Int64 = 0
        var maximumFloorStep: Int64 = 0
        var maximumInstallStep: Int64 = 0
        var maximumHeightSlopeChange: Int64 = 0
        var touchedHeightChannels = Set<Int>()
        var sampleCount = 0
        var finalTarget: [(outputIndex: Int, q30: Int64)] = []

        for update in 0..<updateCount {
            // Two complete left/right traversals plus a front/back sweep in
            // one second: the object crosses every Top Surround boundary of
            // the height pan law many times.
            let progress = Double(update) / Double(updateCount)
            let x = sin(2.0 * Double.pi * 2.0 * progress)
            let y = cos(2.0 * Double.pi * progress)
            let target = gains(x: x, y: y, z: elevation)
            finalTarget = target

            let beforeInstall = smoother.currentGains
            smoother.retarget(target, over: periodSampleCount)
            for channel in beforeInstall.indices {
                maximumInstallStep = max(
                    maximumInstallStep,
                    Swift.abs(smoother.currentGains[channel] - beforeInstall[channel])
                )
            }

            for _ in 0..<periodSampleCount {
                smoother.advance()
                sampleCount += 1
                for channel in previous.indices {
                    let step = smoother.currentGains[channel] - previous[channel]
                    let magnitude = Swift.abs(step)
                    if DTS714ObjectGainSmoother.isHeightChannel(channel) {
                        maximumHeightStep = max(maximumHeightStep, magnitude)
                        maximumHeightSlopeChange = max(
                            maximumHeightSlopeChange,
                            Swift.abs(step - previousStep[channel])
                        )
                        if magnitude != 0 { touchedHeightChannels.insert(channel) }
                    } else {
                        maximumFloorStep = max(maximumFloorStep, magnitude)
                    }
                    previousStep[channel] = step
                }
                previous = smoother.currentGains
            }
        }
        // Automation stops: the trajectory must converge exactly, never park
        // short of its target.
        while smoother.isTransitioning { smoother.advance() }
        let settled = smoother.currentGains == dense(finalTarget)

        // A slope change is bounded by two consecutive bounded steps of
        // opposite sign, so the height ceiling also bounds the first-order
        // discontinuity that makes fast motion sound stepped.
        let allowedSlopeChange = 2 * maximumAllowedHeightStep
        let verified = maximumHeightStep <= maximumAllowedHeightStep
            && maximumFloorStep <= maximumAllowedFloorStep
            && maximumInstallStep == 0
            && maximumHeightSlopeChange <= allowedSlopeChange
            && settled
            && (elevation > 0 ? touchedHeightChannels.count == 4 : true)
        return DTS714HeightCrossingVerificationReport(
            name: name,
            updateCount: updateCount,
            sampleCount: sampleCount,
            maximumHeightStepQ30: maximumHeightStep,
            maximumFloorStepQ30: maximumFloorStep,
            maximumAllowedHeightStepQ30: maximumAllowedHeightStep,
            maximumAllowedFloorStepQ30: maximumAllowedFloorStep,
            maximumRetargetInstallStepQ30: maximumInstallStep,
            maximumHeightSlopeChangeQ30: maximumHeightSlopeChange,
            maximumAllowedHeightSlopeChangeQ30: allowedSlopeChange,
            touchedHeightChannelCount: touchedHeightChannels.count,
            settledExactlyOnFinalTarget: settled,
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

    private static func ceilingDivide(_ value: Int64, _ divisor: Int) -> Int64 {
        (value + Int64(divisor) - 1) / Int64(divisor)
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
            if DTS714ObjectGainSmoother.isHeightChannel(channel), delta != 0 {
                changedHeightChannels.insert(channel)
            }
        }
    }
}
