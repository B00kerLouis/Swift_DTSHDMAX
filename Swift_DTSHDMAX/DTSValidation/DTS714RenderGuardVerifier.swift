import Foundation

/// End-to-end audit of the rendered-7.1.4 headroom contract at object motion.
///
/// The hot vector drives one full-scale-adjacent object (a 997 Hz sine at
/// -0.4 dBFS) through the two speaker-set crossings that Louis's hardware
/// correlates with clicks - side-to-rear on the floor row and floor-to-height
/// on the left wall - with a dwell at each crossing. The dwell matters: the
/// production smoother slew-limits large gain moves to 480 samples, so a
/// fly-through only sustains the composite slightly above full scale
/// (intermittent clicks on fast pans), while any dwell or slow pass lets the
/// equal-power crossing gains fully form. Constant-power panning keeps every
/// individual rendered plane inside signed 24-bit for this vector, yet at
/// the crossings the legacy Q15 height fold peaks at ~1.207x and the
/// Core-residual recovery sum at ~1.414x the object level - so the pre-guard
/// mix overloads exactly the two composites the encoder folds, while the
/// planes the private XLL-X layer sees stay clean. That asymmetry is the
/// measurable form of the "Downmix/pass-through, not XLL-X" hypothesis.
public struct DTS714RenderGuardVerificationReport: Sendable, Equatable, Codable {
    public let hotVectorSampleCount: Int
    /// Pre-guard overloads measured by the render guard on the hot vector.
    public let hotPlaneOverloadSampleCount: Int
    public let hotFoldOverloadSampleCount: Int
    public let hotRecoveryOverloadSampleCount: Int
    public let hotMaximumCompositeMagnitude: Int64
    public let hotMinimumGainQ30: Int64
    public let hotMaximumGainStepQ30: Int64
    public let hotResidualClippedSampleCount: Int
    /// Re-scan of the guarded planes: every constraint must close.
    public let guardedConstraintViolationSampleCount: Int
    /// Fold stage on the guarded render: must not hard-clip a single sample.
    public let guardedFoldHardClipSampleCount: Int
    /// Largest per-sample first difference across all guarded planes. This is
    /// the direct zipper/click audit of the delivered PCM at object motion:
    /// it must stay at content-slope scale rather than jumping to the
    /// clip-edge discontinuities the unguarded fold produced.
    public let guardedMaximumSampleStep: Int64
    /// Encoded grammar of the guarded hot render: every access unit must keep
    /// the official constant hierarchy coefficient (code 473) and the
    /// zero primary residual mask the reference corpus always uses.
    public let guardedEncodedFrameCount: Int
    public let guardedDeviatingCoefficientFrameCount: Int
    public let guardedNonzeroPrimaryMaskFrameCount: Int
    public let guardedEncodedFoldHardClipSampleCount: Int
    /// Encoder-boundary contract: the same raw hot planes fed to the
    /// delivery encoder (stems/wave/direct-plane entry, no renderer in the
    /// path) must engage the boundary source guard and keep every official
    /// invariant - zero fold hard clips, zero coefficient escapes, zero
    /// primary-mask flips.
    public let deliveryRawHotGuardEngaged: Bool
    public let deliveryRawHotFoldHardClipSampleCount: Int
    public let deliveryRawHotDeviatingCoefficientFrameCount: Int
    public let deliveryRawHotNonzeroPrimaryMaskFrameCount: Int
    /// Negative control: the same hot content delivered as raw 7.1.4 planes
    /// through the differential guard bypass (the pre-guard mix law) must
    /// still show the defect - fold hard clips in the delivered bed and hot
    /// frames leaving the official constant matrix - so this gate cannot go
    /// green by losing sight of the failure it exists to prevent.
    public let unguardedEncodedFoldHardClipSampleCount: Int
    public let unguardedDeviatingCoefficientFrameCount: Int
    /// Quiet vector on the same trajectory: the guard must be bit-transparent.
    public let quietVectorTransparent: Bool
    public let isVerified: Bool
}

public enum DTS714RenderGuardVerifier {
    static let officialConstantCoefficientCode = 473

    public static func verify() throws -> DTS714RenderGuardVerificationReport {
        let sampleCount = XLLSyntax.frameSampleCount * 10
        // Every leg is larger than the smoother's 480-sample maximum slew
        // window, so the pan fully forms at each waypoint; the two crossings
        // then dwell for ~20 sine periods at the exact equal-power gains.
        let trajectory: [(sample: Int64, x: Double, y: Double, z: Double)] = [
            (0, -1.0, 1.0, 0.0),      // front-left floor
            (480, -1.0, 0.0, 0.0),    // pure left side surround
            (960, -1.0, -0.5, 0.0),   // side/rear crossing (recovery-sum peak)
            (2_400, -1.0, -1.0, 0.0), // left rear surround
            (2_880, -1.0, -1.0, 0.5), // floor/height crossing (fold peak)
            (4_320, -1.0, -1.0, 1.0), // left rear height
            (4_800, -0.5, -1.0, 1.0)
        ]

        var hotGuard: DTS714RenderGuardReport?
        let hotRender = try renderTrajectoryVector(
            sampleCount: sampleCount,
            amplitude: 8_000_000,
            trajectory: trajectory
        ) { hotGuard = $0 }
        guard let hotGuard else {
            throw DTSError.malformed("hot render did not produce a guard report")
        }

        var guardedViolations = 0
        for sample in 0..<hotRender.sampleCount {
            if DTS714RenderGuard.constraintExtremes(hotRender.planes, sample).overloads {
                guardedViolations += 1
            }
        }
        let guardedFold = try DTS714CompatibilityBedRenderer
            .renderWithDiagnostics(hotRender).diagnostics
        var guardedMaximumSampleStep: Int64 = 0
        for plane in hotRender.planes {
            for sample in 1..<plane.count {
                guardedMaximumSampleStep = max(
                    guardedMaximumSampleStep,
                    Swift.abs(Int64(plane[sample]) - Int64(plane[sample - 1]))
                )
            }
        }

        let guardedEncoded = try encodeAndInspect(
            source: hotRender,
            guardPolicy: .delivery
        )

        // The composite levels an unguarded render (or a hot stems/wave
        // source) hands the encoder. Two floor/height pairs and the
        // side/rear pair are driven hot simultaneously.
        let rawHotPlanes = try hotUnguardedPlanes(sampleCount: sampleCount)

        // Encoder-boundary contract: raw hot planes through the delivery
        // default must engage the boundary source guard and keep every
        // official invariant - this is the stems/wave entry point that
        // historically bypassed the renderer guard entirely.
        let deliveryRawEncoded = try encodeAndInspect(
            source: rawHotPlanes,
            guardPolicy: .delivery
        )

        // Negative control through the differential bypass: the defect must
        // remain measurable so this gate stays anchored to the real failure.
        let unguardedEncoded = try encodeAndInspect(
            source: rawHotPlanes,
            guardPolicy: .bypassForDifferential
        )

        var quietGuard: DTS714RenderGuardReport?
        _ = try renderTrajectoryVector(
            sampleCount: sampleCount,
            amplitude: 2_000_000,
            trajectory: trajectory
        ) { quietGuard = $0 }
        let quietTransparent = quietGuard?.isTransparent == true

        let verified = hotGuard.planeOverloadSampleCount == 0
            && hotGuard.foldOverloadSampleCount > 0
            && hotGuard.recoveryOverloadSampleCount > 0
            && hotGuard.maximumGainStepQ30 <= DTS714RenderGuard.attackStepQ30
            && hotGuard.residualClippedSampleCount == 0
            && guardedViolations == 0
            && guardedFold.hardClipCount == 0
            && guardedEncoded.foldHardClipSampleCount == 0
            && guardedEncoded.deviatingCoefficientFrameCount == 0
            && guardedEncoded.nonzeroPrimaryMaskFrameCount == 0
            && guardedEncoded.frameCount > 0
            && deliveryRawEncoded.sourceGuardEngaged
            && deliveryRawEncoded.foldHardClipSampleCount == 0
            && deliveryRawEncoded.deviatingCoefficientFrameCount == 0
            && deliveryRawEncoded.nonzeroPrimaryMaskFrameCount == 0
            && deliveryRawEncoded.frameCount > 0
            && unguardedEncoded.foldHardClipSampleCount > 0
            && unguardedEncoded.deviatingCoefficientFrameCount > 0
            && quietTransparent

        return DTS714RenderGuardVerificationReport(
            hotVectorSampleCount: sampleCount,
            hotPlaneOverloadSampleCount: hotGuard.planeOverloadSampleCount,
            hotFoldOverloadSampleCount: hotGuard.foldOverloadSampleCount,
            hotRecoveryOverloadSampleCount: hotGuard.recoveryOverloadSampleCount,
            hotMaximumCompositeMagnitude: hotGuard.maximumCompositeMagnitude,
            hotMinimumGainQ30: hotGuard.minimumGainQ30,
            hotMaximumGainStepQ30: hotGuard.maximumGainStepQ30,
            hotResidualClippedSampleCount: hotGuard.residualClippedSampleCount,
            guardedConstraintViolationSampleCount: guardedViolations,
            guardedFoldHardClipSampleCount: guardedFold.hardClipCount,
            guardedMaximumSampleStep: guardedMaximumSampleStep,
            guardedEncodedFrameCount: guardedEncoded.frameCount,
            guardedDeviatingCoefficientFrameCount:
                guardedEncoded.deviatingCoefficientFrameCount,
            guardedNonzeroPrimaryMaskFrameCount:
                guardedEncoded.nonzeroPrimaryMaskFrameCount,
            guardedEncodedFoldHardClipSampleCount:
                guardedEncoded.foldHardClipSampleCount,
            deliveryRawHotGuardEngaged: deliveryRawEncoded.sourceGuardEngaged,
            deliveryRawHotFoldHardClipSampleCount:
                deliveryRawEncoded.foldHardClipSampleCount,
            deliveryRawHotDeviatingCoefficientFrameCount:
                deliveryRawEncoded.deviatingCoefficientFrameCount,
            deliveryRawHotNonzeroPrimaryMaskFrameCount:
                deliveryRawEncoded.nonzeroPrimaryMaskFrameCount,
            unguardedEncodedFoldHardClipSampleCount:
                unguardedEncoded.foldHardClipSampleCount,
            unguardedDeviatingCoefficientFrameCount:
                unguardedEncoded.deviatingCoefficientFrameCount,
            quietVectorTransparent: quietTransparent,
            isVerified: verified
        )
    }

    /// Renders one moving-object scene through the production
    /// ``DTS714Renderer`` path, including its metadata event machinery, gain
    /// smoothing, and the downstream-headroom guard.
    private static func renderTrajectoryVector(
        sampleCount: Int,
        amplitude: Double,
        trajectory: [(sample: Int64, x: Double, y: Double, z: Double)],
        guardReport: @escaping (DTS714RenderGuardReport) -> Void
    ) throws -> DTS714PCMBuffer {
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-dtsx-render-guard-\(UUID().uuidString).pcm"
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }
        var pcm = Data(capacity: sampleCount * 3)
        for sample in 0..<sampleCount {
            let phase = 2.0 * Double.pi * 997.0 * Double(sample) / 48_000.0
            let value = Int32((sin(phase) * amplitude).rounded())
            let raw = UInt32(bitPattern: value) & 0x00ff_ffff
            pcm.append(UInt8(raw & 0xff))
            pcm.append(UInt8((raw >> 8) & 0xff))
            pcm.append(UInt8((raw >> 16) & 0xff))
        }
        do {
            try pcm.write(to: audioURL, options: .atomic)
        } catch {
            throw DTSError.io("cannot write render-guard vector PCM: \(error.localizedDescription)")
        }

        var events: [AtmosMetadataEvent] = []
        for (index, point) in trajectory.enumerated() {
            var event = AtmosMetadataEvent(elementID: 1, samplePosition: point.sample)
            if index == 0 {
                event.active = true
                event.gain = 0
                event.snap = false
                event.elevation = true
            }
            event.position = AtmosPosition(x: point.x, y: point.y, z: point.z)
            events.append(event)
        }

        let master = AtmosMaster(
            version: "render-guard-verifier",
            manifestURL: audioURL,
            metadataURL: audioURL,
            audioURL: audioURL,
            offset: 0,
            firstFrameOfAction: 0,
            framesPerSecond: 24,
            bedChannels: [],
            objects: [AtmosObjectChannel(elementID: 1, audioChannelIndex: 0)],
            audioFormat: AtmosPCMDescriptor(
                container: .wave,
                sampleRate: 48_000,
                formatID: "lpcm",
                formatFlags: 0,
                bytesPerPacket: 3,
                framesPerPacket: 1,
                channelCount: 1,
                bitDepth: 24,
                audioDataOffset: 0,
                audioDataByteCount: UInt64(pcm.count),
                sampleCount: UInt64(sampleCount)
            ),
            metadataSampleRate: 48_000,
            metadataEvents: events
        )
        return try DTS714Renderer.render(master: master, guardReport: guardReport)
    }

    /// The composite levels an unguarded render hands the encoder while a hot
    /// object crosses speaker sets: floor and height feeds simultaneously hot
    /// on the folded pairs, and side plus rear simultaneously hot on the
    /// recovery pair.
    private static func hotUnguardedPlanes(sampleCount: Int) throws -> DTS714PCMBuffer {
        var planes = Array(
            repeating: [Int32](repeating: 0, count: sampleCount),
            count: DTS714Channel.allCases.count
        )
        let amplitude = 6_500_000.0
        let hotChannels: [DTS714Channel] = [
            .left, .leftFrontHeight,          // fold pair
            .leftSideSurround, .leftRearSurround // recovery pair
        ]
        for channel in hotChannels {
            let index = DTS714Channel.allCases.firstIndex(of: channel)!
            for sample in 0..<sampleCount {
                let phase = 2.0 * Double.pi * 997.0 * Double(sample) / 48_000.0
                planes[index][sample] = Int32((sin(phase) * amplitude).rounded())
            }
        }
        return try DTS714PCMBuffer(planes: planes)
    }

    private static func encodeAndInspect(
        source: DTS714PCMBuffer,
        guardPolicy: DTSXSourceGuardPolicy
    ) throws -> (
        frameCount: Int,
        deviatingCoefficientFrameCount: Int,
        nonzeroPrimaryMaskFrameCount: Int,
        foldHardClipSampleCount: Int,
        sourceGuardEngaged: Bool
    ) {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-dtsx-render-guard-\(UUID().uuidString).dtshd"
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let encoded = try DTSXNativeHDMAEncoder(
            verificationPolicy: .none,
            sourceGuardPolicy: guardPolicy
        ).encode(source: source, frameRate: .fps24)
        do {
            try encoded.stream.write(to: output, options: .atomic)
        } catch {
            throw DTSError.io("cannot write render-guard stream: \(error.localizedDescription)")
        }
        let stream = try XLLPBRStreamReader.read(inputURL: output)
        var deviatingCoefficientFrameCount = 0
        var nonzeroPrimaryMaskFrameCount = 0
        for frame in stream.frames {
            let decoded = try XLLDecoder().decodeChannelSets(frame: frame.frame)
            guard decoded.channelSets.count == 2 else {
                throw DTSError.malformed("render-guard stream is not the 6+2 hierarchy")
            }
            if decoded.channelSets[0].residualChannelMask != 0 {
                nonzeroPrimaryMaskFrameCount += 1
            }
            let coefficients = decoded.channelSets[1].downmixCoefficientCodes
            guard coefficients.count == 12 else {
                throw DTSError.malformed("render-guard hierarchy matrix has no 12 coefficients")
            }
            if coefficients[8] != officialConstantCoefficientCode
                || coefficients[11] != officialConstantCoefficientCode {
                deviatingCoefficientFrameCount += 1
            }
        }
        let sourceGuardEngaged = encoded.report.sourceRenderGuard
            .map { $0.isHeadroomSafe && !$0.isTransparent } ?? false
        return (
            stream.frames.count,
            deviatingCoefficientFrameCount,
            nonzeroPrimaryMaskFrameCount,
            encoded.report.compatibilityBedFoldHardClipSampleCount,
            sourceGuardEngaged
        )
    }
}
