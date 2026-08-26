import Foundation

/// End-to-end audit of the Atmos-object onset contract in the render path
/// and of the encode-boundary passthrough invariant.
///
/// Louis's refined hardware pattern: pops track Atmos **master** objects
/// (essence plus automation) - the closer to an object essence onset or the
/// programme head, the higher the pop rate - and the previous
/// delivery-boundary height-onset conditioner made the pops **worse**. The
/// contract verified here is therefore render-native and object-scoped:
///
/// 1. **Hot start bounded in the renderer.** An object that is active with
///    hot essence at sample zero rises at the reference maximum slew (1/480
///    full scale per sample) and converges bit-exactly to the static-gain
///    mix within 480 samples - inside the first source access unit, in all
///    planes the object feeds (floor and height alike, unlike the removed
///    height-only conditioner).
/// 2. **Beds are never faded.** The bed mix is bit-exact from sample zero.
/// 3. **Silent starts are bit-exact.** An object whose essence is silent
///    through the head window renders untouched (the Nature's Fury class).
/// 4. **Mid-programme essence onsets are delivered unfaded.** Hot essence
///    onsets under static gains are programme material in official renders
///    too; the plane-level fade that reshaped them measurably increased
///    hardware pops (the A3 negative control).
/// 5. **The encode boundary never reshapes in-headroom sources.** Delivery
///    and differential-bypass encodes of the rendered hot start are
///    byte-identical, and the delivery encode stays closed-loop bit-exact
///    and early-programme grammar safe.
public struct DTS714RenderStartupVerificationReport: Sendable, Equatable, Codable {
    /// Samples until the hot-start object plane equals the static-gain mix.
    public let hotStartRiseSampleCount: Int
    /// First rendered sample magnitude of the hot-start object plane.
    public let hotStartFirstSampleMagnitude: Int64
    /// Magnitude the same sample would have carried with step-installed
    /// initial gains (the removed behavior).
    public let hotStartUnboundedFirstSampleMagnitude: Int64
    /// Hot-start samples that escape the reference-slew rise envelope.
    public let hotStartEnvelopeViolationCount: Int
    /// After the rise the output must equal the static-gain mix bit-exactly.
    public let hotStartConvergedToStaticMix: Bool
    /// The bed plane must be bit-exact from sample zero (no fade).
    public let hotStartBedBitExact: Bool
    /// Silent-essence head window must render as digital silence.
    public let silentStartHeadWindowSilent: Bool
    /// A mid-programme essence onset under long-static gains must be
    /// delivered at the full static-mix value on its first sample.
    public let midProgrammeEssenceOnsetUnfaded: Bool
    /// Delivery and bypass encodes of the in-headroom rendered hot start
    /// must be byte-identical (the encode boundary conditions nothing).
    public let deliveryAndBypassStreamsByteIdentical: Bool
    public let deliveryRenderGuardTransparent: Bool
    public let hotStartClosedLoopBitExact: Bool
    public let hotStartEarlyProgrammeSafe: Bool
    public let isVerified: Bool
}

public enum DTS714RenderStartupVerifier {
    private static let unityQ30: Int64 = 1 << 30
    private static let objectPlane = DTS714Channel.allCases.firstIndex(of: .leftFrontHeight)!
    private static let bedPlane = DTS714Channel.allCases.firstIndex(of: .left)!
    private static let essenceMagnitude: Int64 = 6_000_000
    private static let sampleCount = XLLSyntax.frameSampleCount * 24
    private static let silentHeadSampleCount = XLLSyntax.frameSampleCount * 12

    public static func verify() throws -> DTS714RenderStartupVerificationReport {
        let maximumStepQ30 = (unityQ30
            + Int64(DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount - 1))
            / Int64(DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount)
        var state = AtmosObjectState(elementID: 10)
        state.active = true
        state.position = AtmosPosition(x: -1, y: 1, z: 1)
        let staticGains = DTS714VBAPPanner.gains(for: state)
        let objectGainQ30 = staticGains
            .first { $0.outputIndex == objectPlane }?.q30 ?? 0
        let staticExpected = roundQ30(essenceMagnitude * objectGainQ30)

        // MARK: Hot start (the tbh class): active object, hot essence at 0.
        let hotRendered = try renderTestMaster(essenceSilentUntil: 0)
        let hotPlane = hotRendered.planes[objectPlane]
        let risePeriod = DTS714ObjectGainSmoother.maximumSlewTransitionSampleCount
        var envelopeViolations = 0
        for sample in 0..<risePeriod {
            let bound = roundQ30(
                essenceMagnitude * min(unityQ30, Int64(sample + 1) * maximumStepQ30)
            ) + 2
            if Int64(abs(Int64(hotPlane[sample]))) > bound { envelopeViolations += 1 }
        }
        var riseSampleCount = risePeriod
        while riseSampleCount > 0,
              Int64(hotPlane[riseSampleCount - 1]) == staticExpected {
            riseSampleCount -= 1
        }
        let converged = hotPlane[risePeriod...].allSatisfy { Int64($0) == staticExpected }
        let bedBitExact = hotRendered.planes[bedPlane].indices.allSatisfy { sample in
            Int64(hotRendered.planes[bedPlane][sample]) == roundQ30(
                Int64(bedSample(sample)) * DTS714ChannelMapper.renderHeadroomQ30
            )
        }

        // MARK: Silent-essence head window (the Nature's Fury class) with a
        // hot mid-programme essence onset under long-static gains.
        let silentRendered = try renderTestMaster(
            essenceSilentUntil: silentHeadSampleCount
        )
        let silentPlane = silentRendered.planes[objectPlane]
        let headWindowSilent = silentPlane[..<silentHeadSampleCount]
            .allSatisfy { $0 == 0 }
        let onsetUnfaded = Int64(silentPlane[silentHeadSampleCount]) == staticExpected
            && silentPlane[silentHeadSampleCount...].allSatisfy {
                Int64($0) == staticExpected
            }

        // MARK: Encode boundary: delivery must not reshape the in-headroom
        // rendered source, and the delivery encode must stay closed-loop
        // bit-exact and early-programme safe.
        let delivery = try DTSXNativeHDMAEncoder(
            verificationPolicy: .none,
            sourceGuardPolicy: .delivery
        ).encode(source: hotRendered, frameRate: .fps24)
        let bypass = try DTSXNativeHDMAEncoder(
            verificationPolicy: .none,
            sourceGuardPolicy: .bypassForDifferential
        ).encode(source: hotRendered, frameRate: .fps24)
        let byteIdentical = delivery.stream == bypass.stream
        let guardTransparent = delivery.report.sourceRenderGuard?.isTransparent ?? false
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-dtsx-render-startup-\(UUID().uuidString).dtshd"
        )
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            try delivery.stream.write(to: output, options: .atomic)
        } catch {
            throw DTSError.io(
                "cannot write render-startup verification stream: \(error.localizedDescription)"
            )
        }
        let heights = try DTSXPrivateHeightVerifier.verify(
            inputURL: output,
            source: hotRendered
        )
        let earlyProgramme = try DTSXEarlyProgrammeGrammarVerifier.verify(
            inputURL: output
        )

        let hotStartFirstSampleMagnitude = Int64(abs(Int64(hotPlane[0])))
        let unboundedFirstSampleMagnitude = Swift.abs(staticExpected)
        let isVerified = hotStartFirstSampleMagnitude
                <= roundQ30(essenceMagnitude * maximumStepQ30) + 2
            && hotStartFirstSampleMagnitude < unboundedFirstSampleMagnitude / 100
            && envelopeViolations == 0
            && riseSampleCount > 0
            && riseSampleCount <= risePeriod
            && converged
            && bedBitExact
            && headWindowSilent
            && onsetUnfaded
            && byteIdentical
            && guardTransparent
            && heights.isBitExact
            && earlyProgramme.isEarlyProgrammeSafe

        return DTS714RenderStartupVerificationReport(
            hotStartRiseSampleCount: riseSampleCount,
            hotStartFirstSampleMagnitude: hotStartFirstSampleMagnitude,
            hotStartUnboundedFirstSampleMagnitude: unboundedFirstSampleMagnitude,
            hotStartEnvelopeViolationCount: envelopeViolations,
            hotStartConvergedToStaticMix: converged,
            hotStartBedBitExact: bedBitExact,
            silentStartHeadWindowSilent: headWindowSilent,
            midProgrammeEssenceOnsetUnfaded: onsetUnfaded,
            deliveryAndBypassStreamsByteIdentical: byteIdentical,
            deliveryRenderGuardTransparent: guardTransparent,
            hotStartClosedLoopBitExact: heights.isBitExact,
            hotStartEarlyProgrammeSafe: earlyProgramme.isEarlyProgrammeSafe,
            isVerified: isVerified
        )
    }

    /// Renders a two-channel synthetic Atmos master: channel 0 is an L bed
    /// carrying a 997 Hz sine, channel 1 is one object declared active at
    /// (-1, 1, 1) from sample zero whose DC essence starts at the given
    /// sample. The initial declaration lands at `samplePosition <= 0`, so
    /// the render exercises exactly the programme-start gain path.
    private static func renderTestMaster(
        essenceSilentUntil: Int
    ) throws -> DTS714PCMBuffer {
        let channelCount = 2
        var pcm = Data(capacity: sampleCount * channelCount * 3)
        for sample in 0..<sampleCount {
            appendPacked24(&pcm, bedSample(sample))
            appendPacked24(
                &pcm,
                sample >= essenceSilentUntil ? Int32(essenceMagnitude) : 0
            )
        }
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-dtsx-render-startup-\(UUID().uuidString).pcm"
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            try pcm.write(to: audioURL, options: .atomic)
        } catch {
            throw DTSError.io(
                "cannot write render-startup test PCM: \(error.localizedDescription)"
            )
        }
        var initialDeclaration = AtmosMetadataEvent(elementID: 10, samplePosition: 0)
        initialDeclaration.active = true
        initialDeclaration.position = AtmosPosition(x: -1, y: 1, z: 1)
        let master = AtmosMaster(
            version: "render-startup-verifier",
            manifestURL: audioURL,
            metadataURL: audioURL,
            audioURL: audioURL,
            offset: 0,
            firstFrameOfAction: 0,
            framesPerSecond: 24,
            bedChannels: [
                AtmosBedChannel(
                    dolbyName: "L",
                    elementID: 1,
                    audioChannelIndex: 0,
                    dtsSpeaker: .left
                )
            ],
            objects: [AtmosObjectChannel(elementID: 10, audioChannelIndex: 1)],
            audioFormat: AtmosPCMDescriptor(
                container: .wave,
                sampleRate: DTS714PCMBuffer.sampleRate,
                formatID: "lpcm",
                formatFlags: 0,
                bytesPerPacket: channelCount * 3,
                framesPerPacket: 1,
                channelCount: channelCount,
                bitDepth: DTS714PCMBuffer.bitDepth,
                audioDataOffset: 0,
                audioDataByteCount: UInt64(pcm.count),
                sampleCount: UInt64(sampleCount)
            ),
            metadataSampleRate: DTS714PCMBuffer.sampleRate,
            metadataEvents: [initialDeclaration]
        )
        return try DTS714Renderer.render(master: master)
    }

    private static func bedSample(_ sample: Int) -> Int32 {
        let phase = 2.0 * Double.pi * 997.0 * Double(sample) / 48_000.0
        return Int32((sin(phase) * 2_000_000.0).rounded())
    }

    private static func appendPacked24(_ data: inout Data, _ value: Int32) {
        let raw = UInt32(bitPattern: value)
        data.append(UInt8(raw & 0xFF))
        data.append(UInt8((raw >> 8) & 0xFF))
        data.append(UInt8((raw >> 16) & 0xFF))
    }

    /// Matches `DTS714Renderer`'s Q30 rounding exactly (round to nearest,
    /// exact half toward zero).
    private static func roundQ30(_ value: Int64) -> Int64 {
        let bias = (unityQ30 >> 1) - 1
        return value >= 0 ? (value + bias) >> 30 : -((-value + bias) >> 30)
    }
}
