import Foundation

/// Reference-decoder first-frame recovery report for one DTS:X stream.
///
/// The DTS reference decoder does not trust the XLL layer on the first
/// access unit it filters (or on any seek re-entry): when residual channel
/// sets are present it forces lossy recovery output, zeroing every XLL band
/// and playing `clip23(Core x InvDmixScale)` alone on each Core-mapped
/// channel. A stream is therefore only startup-safe when the embedded Core
/// actually carries the declared DownmixScale fold, so that the recovery
/// intermediate never leaves the signed 24-bit range and stays close to the
/// true frame content.
public struct XLLRecoveryStartupReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let streamSHA256: String
    public let accessUnitCount: Int
    public let measuredAccessUnitCount: Int
    public let measuredSampleCount: Int
    /// Unique declared DownmixScale codes across the measured window.
    public let declaredScaleCodes: [Int]
    /// Unique declared downmix coefficient codes across the measured window.
    public let declaredCoefficientCodes: [Int]
    /// Every measured frame embeds the official constant scale (473,
    /// -3.0103 dB) for all six reconstructed channels.
    public let scaleCodesMatchOfficialConstant: Bool
    /// Samples whose recovery intermediate `Core x sqrt(2)` exceeded the
    /// signed 24-bit range. Official streams never exercise this clamp;
    /// terminal behavior on it is unverified, so delivery requires zero.
    public let recoveryClipSampleCount: Int
    public let maximumAbsoluteScaledCore: Int64
    /// Largest coded residual. During recovery the terminal plays the scaled
    /// Core alone, so the residual is exactly the first-frame divergence
    /// from the true content. Sample peaks legitimately reach content size
    /// inside the Core filterbank's onset/tail transients, so the pass gate
    /// uses the aggregate magnitudes below instead of this peak.
    public let maximumAbsoluteResidual: Int64
    public let maximumAbsolutePrimary: Int64
    public let totalAbsoluteResidual: Int64
    public let totalAbsolutePrimary: Int64
    /// The aggregate recovery divergence is at least 12 dB below the
    /// aggregate content level (sum|residual| * 4 <= sum|primary|). A Core
    /// that does not carry the declared fold diverges by `(1 - 1/sqrt(2))`
    /// of every sample (-7.66 dB, ratio 0.414) and fails on any content.
    /// Legitimate Core codec error stays well under the gate: even a
    /// worst-case dense uniform-noise vector measures a 0.18 mean ratio,
    /// and tonal content is far lower.
    public let residualWithinRecoveryTolerance: Bool
    /// Recovery-to-lossless handoff audit. While the terminal recovers on an
    /// access unit it plays the scaled Core alone; on the next access unit it
    /// switches to exact lossless output, so the coded residual at the *last
    /// sample* of each access unit is exactly the step the handoff delivers
    /// on top of the content. This is the pop amplitude of a first-frame or
    /// seek-re-entry recovery exit at that boundary. Report-only: the
    /// official calibration for these magnitudes needs the official `.dtshd`
    /// binaries (see PARENT_UPLOAD_REQUEST).
    public let maximumHandoffBoundaryResidual: Int64
    /// Access unit whose exit boundary carries ``maximumHandoffBoundaryResidual``.
    public let maximumHandoffBoundaryResidualFrameIndex: Int?
    /// Largest coded residual inside the first non-priming access unit - the
    /// divergence the terminal plays if it is still recovering when programme
    /// content starts (the hot-start/object-onset-at-head window).
    public let firstSourceAccessUnitMaximumResidual: Int64
    public let isRecoverySafe: Bool
}

/// Simulates the reference decoder's forced first-frame recovery against the
/// natively decoded Core and fails when the stream's startup window diverges
/// from the official DTS:X grammar (constant scale 473, in-range recovery
/// intermediates, Core-codec-sized residuals).
public enum XLLRecoveryStartupVerifier {
    public static let officialScaleCode = 473
    private static let coreWaveToPrimaryOrder = [2, 0, 1, 3, 4, 5]

    public static func verify(
        inputURL: URL,
        maximumAccessUnitCount: Int? = nil
    ) throws -> XLLRecoveryStartupReport {
        if let maximumAccessUnitCount, maximumAccessUnitCount <= 0 {
            throw DTSError.invalidArgument("maximum access-unit count must be positive")
        }
        let input = inputURL.standardizedFileURL
        let core = try DTSCoreStreamDecoder.decode(inputURL: input)
        guard core.format.layout == .fiveOneSide, core.planes.count == 6 else {
            throw DTSError.unsupported("recovery verification requires an embedded 5.1 Core")
        }
        let stream = try XLLPBRStreamReader.read(inputURL: input)
        let measuredFrameCount = min(
            stream.frames.count,
            maximumAccessUnitCount ?? stream.frames.count
        )
        let primingFrameCount = stream.hasBackwardCompatibleCore
            ? XLLSyntax.coreCompatiblePrimingSampleCount / XLLSyntax.frameSampleCount
            : 0

        var declaredScaleCodes: Set<Int> = []
        var declaredCoefficientCodes: Set<Int> = []
        var scaleCodesMatchOfficialConstant = true
        var recoveryClipSampleCount = 0
        var maximumAbsoluteScaledCore: Int64 = 0
        var maximumAbsoluteResidual: Int64 = 0
        var maximumAbsolutePrimary: Int64 = 0
        var totalAbsoluteResidual: Int64 = 0
        var totalAbsolutePrimary: Int64 = 0
        var maximumHandoffBoundaryResidual: Int64 = 0
        var maximumHandoffBoundaryResidualFrameIndex: Int?
        var firstSourceAccessUnitMaximumResidual: Int64 = 0
        var globalSample = 0

        for (frameIndex, frame) in stream.frames.prefix(measuredFrameCount).enumerated() {
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            guard decoded.channelSets.count == 2,
                  decoded.channelSets[0].planes.count == 6,
                  decoded.channelSets[1].planes.count == 2 else {
                throw DTSError.unsupported("recovery verification requires the official 6+2 XLL hierarchy")
            }
            let primary = decoded.channelSets[0]
            let secondary = decoded.channelSets[1]
            let scaleCodes = secondary.downmixEmbedded ? secondary.downmixScaleCodes : []
            let coefficientCodes = secondary.downmixEmbedded ? secondary.downmixCoefficientCodes : []
            guard scaleCodes.isEmpty || scaleCodes.count >= 6 else {
                throw DTSError.malformed("XLL hierarchical downmix scale matrix is incomplete")
            }
            declaredScaleCodes.formUnion(scaleCodes)
            declaredCoefficientCodes.formUnion(coefficientCodes)
            if scaleCodes.count < 6 || !scaleCodes.prefix(6).allSatisfy({ $0 == officialScaleCode }) {
                scaleCodesMatchOfficialConstant = false
            }
            let inverseScales = try scaleCodes.map(XLLSyntax.inverseDownmixScaleQ16)
            guard globalSample + decoded.sampleCount <= core.sampleCount else {
                throw DTSError.truncated(
                    field: "recovery Core PCM",
                    bitOffset: core.sampleCount * 24
                )
            }

            for sample in 0..<decoded.sampleCount {
                for channel in 0..<6 {
                    // Channels with the residual mask bit set are pure XLL and
                    // never combine with the Core; recovery replaces them with
                    // the scaled Core as well, but their divergence is content
                    // dependent by design, so only combined channels gate.
                    guard primary.residualChannelMask & (UInt64(1) << UInt64(channel)) == 0 else {
                        continue
                    }
                    let coreValue = core.planes[Self.coreWaveToPrimaryOrder[channel]][globalSample + sample]
                    let scaledCore: Int64
                    if inverseScales.isEmpty {
                        scaledCore = Int64(coreValue)
                    } else {
                        scaledCore = (Int64(coreValue) * Int64(inverseScales[channel]) + 32_768) >> 16
                    }
                    maximumAbsoluteScaledCore = max(maximumAbsoluteScaledCore, Swift.abs(scaledCore))
                    if scaledCore > 8_388_607 || scaledCore < -8_388_608 {
                        recoveryClipSampleCount += 1
                    }
                    let assemblyShift = try effectiveLSBWidth(
                        channelSet: primary,
                        channel: channel,
                        fixedLSBWidth: decoded.fixedLSBWidth
                    )
                    let coreShift = primary.storageBitDepth - primary.pcmBitDepth + assemblyShift
                    guard coreShift >= 0, coreShift <= primary.storageBitDepth else {
                        throw DTSError.malformed("XLL Core residual shift is outside storage precision")
                    }
                    let rounding = coreShift > 0 ? Int64(1) << Int64(coreShift - 1) : 0
                    let reducedCore = clip24((scaledCore + rounding) >> coreShift)
                    let assembledCore = Int64(reducedCore) << Int64(assemblyShift)
                    let residual = Int64(primary.planes[channel][sample])
                    maximumAbsoluteResidual = max(maximumAbsoluteResidual, Swift.abs(residual))
                    maximumAbsolutePrimary = max(
                        maximumAbsolutePrimary,
                        Swift.abs(residual + assembledCore)
                    )
                    totalAbsoluteResidual += Swift.abs(residual)
                    totalAbsolutePrimary += Swift.abs(residual + assembledCore)
                    if sample == decoded.sampleCount - 1,
                       Swift.abs(residual) > maximumHandoffBoundaryResidual {
                        maximumHandoffBoundaryResidual = Swift.abs(residual)
                        maximumHandoffBoundaryResidualFrameIndex = frameIndex
                    }
                    if frameIndex == primingFrameCount {
                        firstSourceAccessUnitMaximumResidual = max(
                            firstSourceAccessUnitMaximumResidual,
                            Swift.abs(residual)
                        )
                    }
                }
            }
            globalSample += decoded.sampleCount
        }

        let residualWithinRecoveryTolerance = totalAbsolutePrimary == 0
            ? totalAbsoluteResidual == 0
            : totalAbsoluteResidual * 4 <= totalAbsolutePrimary
        return XLLRecoveryStartupReport(
            inputPath: input.path,
            streamSHA256: try SHA256Hasher.hash(fileAt: input),
            accessUnitCount: stream.frames.count,
            measuredAccessUnitCount: measuredFrameCount,
            measuredSampleCount: globalSample,
            declaredScaleCodes: declaredScaleCodes.sorted(),
            declaredCoefficientCodes: declaredCoefficientCodes.sorted(),
            scaleCodesMatchOfficialConstant: scaleCodesMatchOfficialConstant,
            recoveryClipSampleCount: recoveryClipSampleCount,
            maximumAbsoluteScaledCore: maximumAbsoluteScaledCore,
            maximumAbsoluteResidual: maximumAbsoluteResidual,
            maximumAbsolutePrimary: maximumAbsolutePrimary,
            totalAbsoluteResidual: totalAbsoluteResidual,
            totalAbsolutePrimary: totalAbsolutePrimary,
            residualWithinRecoveryTolerance: residualWithinRecoveryTolerance,
            maximumHandoffBoundaryResidual: maximumHandoffBoundaryResidual,
            maximumHandoffBoundaryResidualFrameIndex:
                maximumHandoffBoundaryResidualFrameIndex,
            firstSourceAccessUnitMaximumResidual: firstSourceAccessUnitMaximumResidual,
            isRecoverySafe: scaleCodesMatchOfficialConstant
                && recoveryClipSampleCount == 0
                && residualWithinRecoveryTolerance
        )
    }

    private static func effectiveLSBWidth(
        channelSet: XLLDecodedChannelSet,
        channel: Int,
        fixedLSBWidth: Int
    ) throws -> Int {
        guard channelSet.scalableLSBWidths.indices.contains(channel),
              channelSet.bitWidthAdjustments.indices.contains(channel) else {
            throw DTSError.malformed("XLL scalable-LSB channel metadata is incomplete")
        }
        if fixedLSBWidth > 0 { return fixedLSBWidth }
        let scalable = channelSet.scalableLSBWidths[channel]
        let adjustment = channelSet.bitWidthAdjustments[channel]
        return scalable > 0 && adjustment > 0
            ? scalable + adjustment - 1
            : scalable + adjustment
    }

    private static func clip24(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }
}
