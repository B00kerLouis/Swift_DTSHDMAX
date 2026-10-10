import Foundation

public struct DTSIMAXEncoderVerificationReport: Sendable, Codable {
    public let frameCount: Int
    public let comparedSampleCount: Int
    public let rejectedCorruptFrameCount: Int
    public let predictiveFrameCount: Int
    public let tfcSlewBounded: Bool
    public let tfcCompositeGuardPassed: Bool
    public let isBitExact: Bool
}

/// In-memory qualification covers legal PCM extremes, mono/quartet seeds,
/// all delivery partitions, and the width shared with the enclosing frame.
public enum DTSIMAXEncoderVerifier {
    public static func verify() throws -> DTSIMAXEncoderVerificationReport {
        var cases = 0
        var samples = 0
        var rejected = 0
        var predicted = 0
        for mode in DTSEncodeMode.allCases {
            for segments in [2,4,8] {
                for width in [7,8,10,12,14] {
                    for vector in 0..<4 {
                        let planes = (0..<5).map { channel in
                            (0..<512).map { sample -> Int32 in
                                switch vector {
                                case 0: return 0
                                case 1: return Int32((sample - 256) * (channel + 1) * 100)
                                case 2: return sample == channel * 73 ? 8_388_607 : (sample == 511 ? -8_388_608 : 0)
                                default: return Int32((sample * 7919 + channel * 137) % 8388607 - 4194303)
                                }
                            }
                        }
                        let plan = try XLLSegmentationPlan(segmentCount: segments, segmentSampleCount: 512 / segments,
                            segmentSizeBitCount: width, navigationByteCount: 2 + (segments * width + 7) / 8,
                            segmentEntropyByteCounts: Array(repeating: [1], count: segments))
                        let frame = try DTSIMAXPrivateFrame.encode(planes: planes, plan: plan, encodeMode: mode)
                        guard try frame.decode() == planes else { throw DTSError.malformed("IMAX verifier PCM mismatch") }
                        let group = try XLLEncoder(codingMode: mode == .auto ? .terminalOfficialPredictive : .terminalOfficialRice,
                            maximumPredictionOrder: 10).encodeIMAXChannelSet(planes: [planes[0]], segmentCount: segments)
                        if group.predictionOrders.contains(where: { $0 > 0 }) || group.fixedPredictionOrders.contains(where: { $0 > 0 }) {
                            predicted += 1
                        }
                        if mode == .standard, group.predictionOrders.contains(where: { $0 > 0 }) || group.fixedPredictionOrders.contains(where: { $0 > 0 }) {
                            throw DTSError.malformed("IMAX standard mode enabled prediction")
                        }
                        var corrupt = frame.data
                        corrupt[44] ^= 1
                        do { _ = try DTSIMAXPrivateFrame.parse(corrupt); throw DTSError.malformed("IMAX accepted corrupt metadata") }
                        catch DTSError.malformed(let detail) where detail == "IMAX accepted corrupt metadata" { throw DTSError.malformed(detail) }
                        catch { rejected += 1 }
                        cases += 1
                        samples += 5 * 512
                    }
                }
            }
        }
        guard predicted > 0 else { throw DTSError.malformed("IMAX auto never selected a predictor") }
        var state = AtmosObjectState(elementID: 0)
        state.active = true
        state.position = AtmosPosition(x: 0, y: 1, z: 1)
        state.elevation = true
        let target = DTSIMAXPanner.gains(for: state)
        guard target.contains(where: { $0.outputIndex == 12 && $0.q30 > 0 }) else {
            throw DTSError.malformed("IMAX upper front center did not reach TFC")
        }
        var smoother = DTSIMAXObjectGainSmoother()
        smoother.setImmediately([(8, 1 << 30)])
        smoother.retarget(target, over: 250)
        var previous = smoother.currentGains
        for _ in 0..<1000 {
            smoother.advance()
            for index in 0..<13 {
                guard abs(smoother.currentGains[index] - previous[index]) <= ((1 << 30) + 479) / 480 else {
                    throw DTSError.malformed("IMAX panner exceeded the sample-continuous gain slew")
                }
            }
            previous = smoother.currentGains
        }
        var hot = Array(repeating: Array(repeating: Int32(0), count: 2048), count: 13)
        for sample in 512..<1536 { hot[2][sample] = 6_000_000; hot[12][sample] = 6_000_000 }
        let guardReport = DTS714RenderGuard.apply(to: &hot, imax: true)
        guard guardReport.gainReducedSampleCount > 0, guardReport.residualClippedSampleCount == 0 else {
            throw DTSError.malformed("IMAX TFC/C composite guard failed")
        }
        _ = try DTSIMAXCompatibilityBedRenderer.render(DTSIMAXPCMBuffer(planes: hot))
        return DTSIMAXEncoderVerificationReport(frameCount: cases, comparedSampleCount: samples,
            rejectedCorruptFrameCount: rejected, predictiveFrameCount: predicted,
            tfcSlewBounded: true, tfcCompositeGuardPassed: true, isBitExact: true)
    }
}
