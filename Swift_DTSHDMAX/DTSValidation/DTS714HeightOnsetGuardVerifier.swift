import Foundation

/// End-to-end audit of the height-onset continuity conditioning at the
/// DTS:X delivery boundary.
///
/// Louis's hardware pattern: pops correlate with master Object onsets, the
/// closer an onset sits to the programme head the higher the pop
/// probability, and a hot-start title (tbh) leaves the first ~10 seconds
/// unplayable while a silent-start title (Nature's Fury) plays. The two
/// delivered carriers of that asymmetry are hot height content inside the
/// terminal's startup-convergence window and hard silence-to-active height
/// steps at exactly the access units where the private XLL-X grammar
/// reconfigures. This verifier proves the conditioner bounds both carriers,
/// stays bit-transparent for every compliant source (the Nature's Fury
/// class), keeps the encoded grammar early-programme safe, and that the
/// differential bypass still delivers the raw defect (the negative control
/// stays honest).
public struct DTS714HeightOnsetGuardVerificationReport: Sendable, Equatable, Codable {
    /// Silent-height start: conditioning must be bit-transparent and the
    /// delivery stream byte-identical to the differential bypass stream.
    public let silentStartTransparent: Bool
    public let silentStartStreamsByteIdentical: Bool
    /// Hot height content from sample zero (the tbh class).
    public let hotStartHeadRampScaledSampleCount: Int
    public let hotStartHardOnsetCount: Int
    /// Every conditioned head-window sample obeys the head ramp envelope
    /// `|x'[n]| <= n x fullScale / headRampSampleCount` (+1 LSB rounding).
    public let hotStartHeadEnvelopeViolationCount: Int
    /// No artificial discontinuity at the head-window exit: the conditioned
    /// plane's first difference across the boundary stays at content scale.
    public let hotStartBoundaryStep: Int64
    public let hotStartClosedLoopBitExact: Bool
    public let hotStartEarlyProgrammeSafe: Bool
    /// Mid-stream hard onset after sustained silence.
    public let midStreamHardOnsetCount: Int
    public let midStreamSoftOnsetCount: Int
    /// Every conditioned onset-window sample obeys the reference-slew
    /// envelope `|x'[k]| <= (k + 1) x fullScale / 480` (+1 LSB rounding).
    public let midStreamOnsetEnvelopeViolationCount: Int
    public let midStreamOnsetFirstSampleMagnitudeBefore: Int64
    public let midStreamOnsetFirstSampleMagnitudeAfter: Int64
    /// The naturally slewed onset plane must pass through bit-exact.
    public let midStreamSoftOnsetPlaneUntouched: Bool
    public let midStreamClosedLoopBitExact: Bool
    public let midStreamEarlyProgrammeSafe: Bool
    /// Negative control: the differential bypass must deliver the raw hard
    /// step bit-exactly (the defect stays measurable) and differ from the
    /// delivery stream.
    public let bypassClosedLoopBitExactAgainstRawSource: Bool
    public let bypassStreamDiffersFromDelivery: Bool
    public let isVerified: Bool
}

public enum DTS714HeightOnsetGuardVerifier {
    private static let fullScale: Int64 = 1 << 23

    public static func verify() throws -> DTS714HeightOnsetGuardVerificationReport {
        // MARK: Silent-height start (Nature's Fury class)
        let silentStartSampleCount = XLLSyntax.frameSampleCount * 8
        var silentPlanes = zeroPlanes(sampleCount: silentStartSampleCount)
        fillSine(&silentPlanes, channel: .left, amplitude: 2_000_000, frequency: 997)
        fillSine(&silentPlanes, channel: .right, amplitude: 2_000_000, frequency: 757)
        let silentSource = try DTS714PCMBuffer(planes: silentPlanes)
        var silentConditioned = silentPlanes
        let silentReports = DTS714DeliverySourceConditioner.condition(
            planes: &silentConditioned
        )
        let silentStartTransparent = silentReports.onset.isTransparent
            && silentReports.renderGuard.isTransparent
            && silentConditioned == silentPlanes
        let silentDelivery = try DTSXNativeHDMAEncoder(
            verificationPolicy: .none,
            sourceGuardPolicy: .delivery
        ).encode(source: silentSource, frameRate: .fps24)
        let silentBypass = try DTSXNativeHDMAEncoder(
            verificationPolicy: .none,
            sourceGuardPolicy: .bypassForDifferential
        ).encode(source: silentSource, frameRate: .fps24)
        let silentStartStreamsByteIdentical = silentDelivery.stream == silentBypass.stream

        // MARK: Hot height start (tbh class)
        let headRamp = DTS714HeightOnsetConditioner.headRampSampleCount
        let hotStartSampleCount = headRamp + XLLSyntax.frameSampleCount * 8
        var hotPlanes = zeroPlanes(sampleCount: hotStartSampleCount)
        fillSine(&hotPlanes, channel: .left, amplitude: 3_000_000, frequency: 409)
        fillSine(&hotPlanes, channel: .right, amplitude: 3_000_000, frequency: 523)
        fillSine(&hotPlanes, channel: .leftFrontHeight, amplitude: 6_000_000, frequency: 1_213)
        fillSine(&hotPlanes, channel: .rightFrontHeight, amplitude: 6_000_000, frequency: 1_327)
        fillSine(&hotPlanes, channel: .leftRearHeight, amplitude: 6_000_000, frequency: 1_439)
        fillSine(&hotPlanes, channel: .rightRearHeight, amplitude: 6_000_000, frequency: 1_553)
        let hotSource = try DTS714PCMBuffer(planes: hotPlanes)
        var hotConditioned = hotPlanes
        let hotReports = DTS714DeliverySourceConditioner.condition(planes: &hotConditioned)
        var hotHeadEnvelopeViolations = 0
        var hotBoundaryStep: Int64 = 0
        for plane in DTS714HeightOnsetConditioner.heightPlaneIndices {
            for sample in 0..<headRamp {
                let magnitude = Int64(abs(Int64(hotConditioned[plane][sample])))
                let envelope = (Int64(sample) * fullScale) / Int64(headRamp) + 1
                if magnitude > envelope { hotHeadEnvelopeViolations += 1 }
            }
            hotBoundaryStep = max(
                hotBoundaryStep,
                Swift.abs(
                    Int64(hotConditioned[plane][headRamp])
                        - Int64(hotConditioned[plane][headRamp - 1])
                )
            )
        }
        let (hotClosedLoopBitExact, hotEarlyProgrammeSafe) = try encodeAndAudit(
            source: hotSource,
            guardPolicy: .delivery,
            deliveryConditionedComparison: true
        ).destructured

        // MARK: Mid-stream hard onset after sustained silence
        let onsetSample = headRamp + XLLSyntax.frameSampleCount * 4
        let midStreamSampleCount = onsetSample + XLLSyntax.frameSampleCount * 8
        var midPlanes = zeroPlanes(sampleCount: midStreamSampleCount)
        fillSine(&midPlanes, channel: .center, amplitude: 2_500_000, frequency: 641)
        let lfh = DTS714Channel.allCases.firstIndex(of: .leftFrontHeight)!
        let rfh = DTS714Channel.allCases.firstIndex(of: .rightFrontHeight)!
        // Hard step: alternating full-amplitude square-ish content from the
        // onset sample, far beyond the reference-slew envelope.
        for sample in onsetSample..<midStreamSampleCount {
            midPlanes[lfh][sample] = (sample - onsetSample).isMultiple(of: 2)
                ? 5_000_000 : -5_000_000
        }
        // Naturally slewed onset: rises well inside the reference-slew
        // envelope, so it must pass through bit-exact.
        let onsetRamp = DTS714HeightOnsetConditioner.onsetRampSampleCount
        for sample in onsetSample..<midStreamSampleCount {
            let offset = sample - onsetSample
            let rising = min(2_000_000, (offset + 1) * 4_100)
            let phase = 2.0 * Double.pi * 881.0 * Double(offset) / 48_000.0
            midPlanes[rfh][sample] = Int32((sin(phase) * Double(rising)).rounded())
        }
        let midSource = try DTS714PCMBuffer(planes: midPlanes)
        var midConditioned = midPlanes
        let midReports = DTS714DeliverySourceConditioner.condition(planes: &midConditioned)
        var midOnsetEnvelopeViolations = 0
        for offset in 0..<onsetRamp {
            let magnitude = Int64(abs(Int64(midConditioned[lfh][onsetSample + offset])))
            let envelope = (Int64(offset + 1) * fullScale) / Int64(onsetRamp) + 1
            if magnitude > envelope { midOnsetEnvelopeViolations += 1 }
        }
        let midStreamSoftOnsetPlaneUntouched =
            midConditioned[rfh] == midPlanes[rfh]
        let midDeliveryAudit = try encodeAndAudit(
            source: midSource,
            guardPolicy: .delivery,
            deliveryConditionedComparison: true
        )
        let (midClosedLoopBitExact, midEarlyProgrammeSafe) =
            midDeliveryAudit.destructured

        // MARK: Negative control - the bypass must deliver the raw defect
        let bypassAudit = try encodeAndAudit(
            source: midSource,
            guardPolicy: .bypassForDifferential,
            deliveryConditionedComparison: false
        )
        let bypassStreamDiffersFromDelivery =
            bypassAudit.streamSHA256 != midDeliveryAudit.streamSHA256

        let isVerified = silentStartTransparent
            && silentStartStreamsByteIdentical
            && hotReports.onset.headRampScaledSampleCount > 0
            && hotReports.onset.hardOnsetCount == 0
            && hotHeadEnvelopeViolations == 0
            && hotBoundaryStep <= contentStepCeiling(
                amplitude: 6_000_000,
                frequency: 1_553
            )
            && hotClosedLoopBitExact
            && hotEarlyProgrammeSafe
            && midReports.onset.hardOnsetCount == 1
            && midReports.onset.softOnsetCount == 1
            && midOnsetEnvelopeViolations == 0
            && midReports.onset.maximumOnsetFirstSampleMagnitudeBefore == 5_000_000
            && midReports.onset.maximumOnsetFirstSampleMagnitudeAfter
                <= fullScale / Int64(onsetRamp) + 1
            && midStreamSoftOnsetPlaneUntouched
            && midClosedLoopBitExact
            && midEarlyProgrammeSafe
            && bypassAudit.closedLoopBitExact
            && bypassStreamDiffersFromDelivery

        return DTS714HeightOnsetGuardVerificationReport(
            silentStartTransparent: silentStartTransparent,
            silentStartStreamsByteIdentical: silentStartStreamsByteIdentical,
            hotStartHeadRampScaledSampleCount:
                hotReports.onset.headRampScaledSampleCount,
            hotStartHardOnsetCount: hotReports.onset.hardOnsetCount,
            hotStartHeadEnvelopeViolationCount: hotHeadEnvelopeViolations,
            hotStartBoundaryStep: hotBoundaryStep,
            hotStartClosedLoopBitExact: hotClosedLoopBitExact,
            hotStartEarlyProgrammeSafe: hotEarlyProgrammeSafe,
            midStreamHardOnsetCount: midReports.onset.hardOnsetCount,
            midStreamSoftOnsetCount: midReports.onset.softOnsetCount,
            midStreamOnsetEnvelopeViolationCount: midOnsetEnvelopeViolations,
            midStreamOnsetFirstSampleMagnitudeBefore:
                midReports.onset.maximumOnsetFirstSampleMagnitudeBefore,
            midStreamOnsetFirstSampleMagnitudeAfter:
                midReports.onset.maximumOnsetFirstSampleMagnitudeAfter,
            midStreamSoftOnsetPlaneUntouched: midStreamSoftOnsetPlaneUntouched,
            midStreamClosedLoopBitExact: midClosedLoopBitExact,
            midStreamEarlyProgrammeSafe: midEarlyProgrammeSafe,
            bypassClosedLoopBitExactAgainstRawSource: bypassAudit.closedLoopBitExact,
            bypassStreamDiffersFromDelivery: bypassStreamDiffersFromDelivery,
            isVerified: isVerified
        )
    }

    private struct EncodeAudit {
        let closedLoopBitExact: Bool
        let earlyProgrammeSafe: Bool
        let streamSHA256: String

        var destructured: (Bool, Bool) { (closedLoopBitExact, earlyProgrammeSafe) }
    }

    private static func encodeAndAudit(
        source: DTS714PCMBuffer,
        guardPolicy: DTSXSourceGuardPolicy,
        deliveryConditionedComparison: Bool
    ) throws -> EncodeAudit {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-dtsx-onset-guard-\(UUID().uuidString).dtshd"
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let encoded = try DTSXNativeHDMAEncoder(
            verificationPolicy: .none,
            sourceGuardPolicy: guardPolicy
        ).encode(source: source, frameRate: .fps24)
        do {
            try encoded.stream.write(to: output, options: .atomic)
        } catch {
            throw DTSError.io(
                "cannot write onset-guard verification stream: \(error.localizedDescription)"
            )
        }
        let heights = try DTSXPrivateHeightVerifier.verify(
            inputURL: output,
            source: source,
            deliveryConditioned: deliveryConditionedComparison
        )
        let earlyProgramme = try DTSXEarlyProgrammeGrammarVerifier.verify(
            inputURL: output
        )
        return EncodeAudit(
            closedLoopBitExact: heights.isBitExact,
            earlyProgrammeSafe: earlyProgramme.isEarlyProgrammeSafe,
            streamSHA256: encoded.report.streamSHA256
        )
    }

    /// Largest per-sample first difference a sine of the given amplitude and
    /// frequency can produce at 48 kHz, with rounding margin.
    private static func contentStepCeiling(amplitude: Double, frequency: Double) -> Int64 {
        Int64((amplitude * 2.0 * Double.pi * frequency / 48_000.0).rounded(.up)) + 2
    }

    private static func zeroPlanes(sampleCount: Int) -> [[Int32]] {
        Array(
            repeating: [Int32](repeating: 0, count: sampleCount),
            count: DTS714Channel.allCases.count
        )
    }

    private static func fillSine(
        _ planes: inout [[Int32]],
        channel: DTS714Channel,
        amplitude: Double,
        frequency: Double
    ) {
        let index = DTS714Channel.allCases.firstIndex(of: channel)!
        for sample in planes[index].indices {
            let phase = 2.0 * Double.pi * frequency * Double(sample) / 48_000.0
            planes[index][sample] = Int32((sin(phase) * amplitude).rounded())
        }
    }
}
