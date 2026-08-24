import Foundation

/// Sample-continuous Q30 gain de-zipper for one rendered Atmos object.
///
/// DAMF/IAB position automation can update more often than a public XLL
/// segment.  Applying each update as a new static panner vector produces a
/// one-sample gain step on every loudspeaker, which is most audible while an
/// object crosses the four height feeds.  This state machine linearly reaches
/// each target without allocating in the sample loop.  A target arriving
/// during an unfinished ramp starts from the exact current gain, so retargets
/// are continuous too.
struct DTS714ObjectGainSmoother: Sendable, Equatable {
    static let channelCount = 12
    /// Reference renderer maximum slew: 1 / 480 full-scale gain per sample.
    /// A large move therefore takes 480 samples (10 ms at 48 kHz).
    static let maximumSlewTransitionSampleCount = 480
    /// One of eight pan sub-blocks in a 24 fps / 48 kHz authoring frame.
    static let defaultPanSubBlockSampleCount = 250
    static let maximumOrdinaryTransitionSampleCount = 4_800
    /// Lfh/Rfh/Lrh/Rrh occupy the last four 7.1.4 PCM planes.
    static let firstHeightChannelIndex = 8
    /// The height pan law reaches a Top Surround speaker at |x| = 0.5 and
    /// saturates beyond it, so the four height feeds move at roughly twice
    /// the floor rate for the same object velocity and reach the ordinary
    /// slew ceiling on almost every sub-block of a fast trajectory. Ramping
    /// at the ceiling on back-to-back sub-blocks leaves a slope break every
    /// pan period, which is what makes fast Top Surround moves sound stepped
    /// even though no single-sample gain jump is present. Height feeds
    /// therefore use a lower ceiling of 1 / 1440 full scale per sample
    /// (30 ms for a full-scale move).
    static let maximumHeightSlewTransitionSampleCount = 1_440
    /// Height retargets are additionally spread over at least 480 samples so
    /// consecutive pan sub-blocks overlap into one continuous trajectory
    /// instead of restarting a fresh ramp every 250 samples.
    static let minimumHeightTransitionSampleCount = 480

    static func isHeightChannel(_ index: Int) -> Bool {
        index >= firstHeightChannelIndex
    }

    private(set) var currentGains = Array(
        repeating: Int64(0),
        count: channelCount
    )
    private(set) var activeIndices: [Int] = []
    private var targetGains = Array(repeating: Int64(0), count: channelCount)
    private var integralSteps = Array(repeating: Int64(0), count: channelCount)
    private var remainderMagnitudes = Array(repeating: Int64(0), count: channelCount)
    private var remainderErrors = Array(repeating: Int64(0), count: channelCount)
    private var remainderDirections = Array(repeating: Int64(0), count: channelCount)
    private var transitionSampleCounts = Array(repeating: Int64(0), count: channelCount)
    private var remainingSampleCounts = Array(repeating: 0, count: channelCount)
    private var transitioningChannelCount = 0

    var isTransitioning: Bool { transitioningChannelCount > 0 }
    var isSilent: Bool { activeIndices.isEmpty }
    var maximumRemainingSampleCount: Int { remainingSampleCounts.max() ?? 0 }

    mutating func setImmediately(_ sparseGains: [(outputIndex: Int, q30: Int64)]) {
        let dense = Self.denseGains(sparseGains)
        currentGains = dense
        targetGains = dense
        activeIndices = dense.indices.filter { dense[$0] != 0 }
        integralSteps = Array(repeating: 0, count: Self.channelCount)
        remainderMagnitudes = Array(repeating: 0, count: Self.channelCount)
        remainderErrors = Array(repeating: 0, count: Self.channelCount)
        remainderDirections = Array(repeating: 0, count: Self.channelCount)
        transitionSampleCounts = Array(repeating: 0, count: Self.channelCount)
        remainingSampleCounts = Array(repeating: 0, count: Self.channelCount)
        transitioningChannelCount = 0
    }

    mutating func retarget(
        _ sparseGains: [(outputIndex: Int, q30: Int64)],
        over sampleCount: Int
    ) {
        guard sampleCount > 0 else {
            setImmediately(sparseGains)
            return
        }
        targetGains = Self.denseGains(sparseGains)
        let ordinaryPeriod = min(sampleCount, Self.maximumOrdinaryTransitionSampleCount)
        activeIndices = currentGains.indices.filter {
            currentGains[$0] != 0 || targetGains[$0] != 0
        }
        transitioningChannelCount = 0
        for channel in currentGains.indices {
            let delta = targetGains[channel] - currentGains[channel]
            guard delta != 0 else {
                transitionSampleCounts[channel] = 0
                remainingSampleCounts[channel] = 0
                integralSteps[channel] = 0
                remainderMagnitudes[channel] = 0
                remainderErrors[channel] = 0
                remainderDirections[channel] = 0
                continue
            }
            let isHeight = Self.isHeightChannel(channel)
            let slewPeriod = isHeight
                ? Self.maximumHeightSlewTransitionSampleCount
                : Self.maximumSlewTransitionSampleCount
            let basePeriod = isHeight
                ? Swift.min(
                    Self.maximumOrdinaryTransitionSampleCount,
                    Swift.max(ordinaryPeriod, Self.minimumHeightTransitionSampleCount)
                )
                : ordinaryPeriod
            // Equivalent to abs(delta / basePeriod) > 1 / slewPeriod,
            // evaluated without floating-point ambiguity.
            let requiresSlewLimit = Swift.abs(delta) * Int64(slewPeriod)
                > Int64(1 << 30) * Int64(basePeriod)
            let period = requiresSlewLimit ? slewPeriod : basePeriod
            transitionSampleCounts[channel] = Int64(period)
            remainingSampleCounts[channel] = period
            transitioningChannelCount += 1
            integralSteps[channel] = delta / Int64(period)
            let remainder = delta % Int64(period)
            remainderMagnitudes[channel] = Swift.abs(remainder)
            remainderErrors[channel] = 0
            remainderDirections[channel] = remainder == 0 ? 0 : (remainder > 0 ? 1 : -1)
        }
    }

    /// Advances to the next point on the ramp before that point is mixed.
    /// A target installed at sample T therefore changes T by one bounded step
    /// and reaches the exact target on the duration-th mixed sample.
    mutating func advance() {
        guard isTransitioning else { return }
        for channel in activeIndices {
            guard remainingSampleCounts[channel] > 0 else { continue }
            currentGains[channel] += integralSteps[channel]
            remainderErrors[channel] += remainderMagnitudes[channel]
            if remainderErrors[channel] >= transitionSampleCounts[channel] {
                currentGains[channel] += remainderDirections[channel]
                remainderErrors[channel] -= transitionSampleCounts[channel]
            }
            remainingSampleCounts[channel] -= 1
            if remainingSampleCounts[channel] == 0 {
                currentGains[channel] = targetGains[channel]
                transitioningChannelCount -= 1
            }
        }
        if !isTransitioning {
            activeIndices = currentGains.indices.filter { currentGains[$0] != 0 }
        }
    }

    private static func denseGains(
        _ sparseGains: [(outputIndex: Int, q30: Int64)]
    ) -> [Int64] {
        var dense = Array(repeating: Int64(0), count: channelCount)
        for gain in sparseGains {
            precondition(
                (0..<channelCount).contains(gain.outputIndex),
                "DTS:X object gain references an invalid 7.1.4 channel"
            )
            dense[gain.outputIndex] = gain.q30
        }
        return dense
    }
}
