import Foundation

/// Native fixed-point DTS Coherent Acoustics Core decoder for the 48 kHz,
/// AMODE 9 profile used by the supplied HDMA and DTS:X reference streams.
/// It preserves QMF, ADPCM, and LFE history across frames and returns the
/// internal 24-bit reconstruction used by XLL residual assembly.
public struct DTSCoreDecoder: Sendable {
    private struct SynthesisState: Sendable {
        var history = Array(repeating: Int32(0), count: 512)
        var delayed = Array(repeating: Int32(0), count: 32)
        var offset = 0
    }

    private var synthesis = Array(repeating: SynthesisState(), count: 5)
    private var adpcmHistory = Array(
        repeating: Array(repeating: Array(repeating: Int32(0), count: 4), count: 32),
        count: 5
    )
    private var lfeHistory = Array(repeating: Int32(0), count: 8)

    public init() {}

    public mutating func decode(frame data: Data) throws -> PCMBuffer {
        let syntax = try DTSCoreSyntaxParser.parse(frame: data)
        let header = syntax.bitstreamHeader
        guard header.audioMode == 9,
              header.primaryChannelCount == 5,
              header.sampleRate == 48_000,
              header.lfeCode == 2,
              !header.sumDifferenceFront,
              !header.sumDifferenceSurround else {
            throw DTSError.unsupported("native Core decoder requires the 48 kHz AMODE 9 / 64x LFE profile")
        }

        let blockCount = header.pcmBlockCount
        var subbands = Array(
            repeating: Array(
                repeating: Array(repeating: Int32(0), count: blockCount),
                count: 32
            ),
            count: 5
        )
        var lfeDecimated: [Int32] = []
        lfeDecimated.reserveCapacity(blockCount / 2)
        var blockOffset = 0

        for subframe in syntax.subframes {
            let sampleCount = subframe.subSubframeCount * 8
            for channel in 0..<5 {
                for band in 0..<syntax.primaryAudioHeader.subbandActivityCounts[channel] {
                    if band >= syntax.primaryAudioHeader.highFrequencyVQStartSubbands[channel] {
                        let vector = subframe.highFrequencyVQIndices[channel][
                            band - syntax.primaryAudioHeader.highFrequencyVQStartSubbands[channel]
                        ]
                        let scaleIndex = try scaleIndex(
                            subframe.scaleFactorIndices[channel][band],
                            at: 0
                        )
                        let scale = try scaleFactor(scaleIndex)
                        for sample in 0..<sampleCount {
                            let coefficient = DTSCoreDecodeTables.highFrequencyCoefficient(
                                vector: vector,
                                sample: sample
                            )
                            subbands[channel][band][blockOffset + sample] = clip23(
                                (Int64(coefficient) * Int64(scale) + 8) >> 4
                            )
                        }
                        continue
                    }

                    let allocation = subframe.bitAllocations[channel][band]
                    let quantized = subframe.quantizedSubbandSamples[channel][band]
                    guard quantized.count == sampleCount else {
                        throw DTSError.malformed("DTS Core quantized subband sample count disagrees with subframe")
                    }
                    for subSubframe in 0..<subframe.subSubframeCount {
                        let transition = subframe.transitionModes[channel][band]
                        let scaleSlot = transition == 0 || subSubframe < transition ? 0 : 1
                        let scaleIndex = allocation == 0
                            ? 0
                            : try scaleIndex(subframe.scaleFactorIndices[channel][band], at: scaleSlot)
                        var scale = allocation == 0 ? Int32(0) : try scaleFactor(scaleIndex)
                        if allocation > 0, allocation <= 10,
                           syntax.primaryAudioHeader.quantizationIndexSelectors[channel][allocation - 1]
                            < Self.quantizationSelectorGroupSizes[allocation - 1] {
                            guard let adjustment = syntax.primaryAudioHeader
                                .scaleFactorAdjustmentCodes[channel][allocation - 1] else {
                                throw DTSError.malformed("DTS Core Huffman scale adjustment is missing")
                            }
                            scale = clip23(
                                (Int64(DTSCoreDecodeTables.scaleFactorAdjust[adjustment])
                                    * Int64(scale)) >> 22
                            )
                        }
                        for sample in 0..<8 {
                            let destination = blockOffset + subSubframe * 8 + sample
                            subbands[channel][band][destination] = dequantize(
                                quantized[subSubframe * 8 + sample],
                                allocation: allocation,
                                scale: scale,
                                lossless: header.bitrate == 3
                            )
                        }
                    }
                }
            }

            if header.lfeCode != 0 {
                guard let lfeScaleIndex = subframe.lfeScaleFactorIndex else {
                    throw DTSError.malformed("DTS Core LFE scale factor is missing")
                }
                let scale = multiplyQ23(4_697_620, try scaleFactor(lfeScaleIndex))
                lfeDecimated.append(contentsOf: subframe.lfeSamples.map {
                    clip23((Int64($0) * Int64(scale)) >> 4)
                })
            }

            for channel in 0..<5 {
                for band in 0..<syntax.primaryAudioHeader.subbandActivityCounts[channel] {
                    var history = adpcmHistory[channel][band]
                    if subframe.predictionModes[channel][band] {
                        guard let vector = subframe.predictionVQIndices[channel][band] else {
                            throw DTSError.malformed("DTS Core predictor vector is missing")
                        }
                        for sample in 0..<sampleCount {
                            let index = blockOffset + sample
                            var prediction: Int64 = 0
                            for tap in 0..<4 {
                                prediction += Int64(history[3 - tap])
                                    * Int64(DTSCoreDecodeTables.adpcmCoefficient(vector: vector, tap: tap))
                            }
                            let reconstructed = clip23(
                                Int64(subbands[channel][band][index])
                                    + Int64(normalize(prediction, bits: 13))
                            )
                            subbands[channel][band][index] = reconstructed
                            history.removeFirst()
                            history.append(reconstructed)
                        }
                    } else {
                        let start = blockOffset + max(0, sampleCount - 4)
                        history = Array(subbands[channel][band][start..<(blockOffset + sampleCount)])
                        if history.count < 4 {
                            history = Array(repeating: 0, count: 4 - history.count) + history
                        }
                    }
                    adpcmHistory[channel][band] = history
                }
            }
            blockOffset += sampleCount
        }
        guard blockOffset == blockCount, lfeDecimated.count == blockCount / 2 else {
            throw DTSError.malformed("DTS Core decoded timeline does not close")
        }

        var primary = Array(repeating: [Int32](), count: 5)
        for channel in 0..<5 {
            primary[channel].reserveCapacity(blockCount * 32)
            var state = synthesis[channel]
            for block in 0..<blockCount {
                let input = (0..<32).map { subbands[channel][$0][block] }
                primary[channel].append(contentsOf: synthesize(input, state: &state))
            }
            synthesis[channel] = state
        }
        let lfe = interpolateLFE(lfeDecimated)
        return try PCMBuffer(
            format: PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .fiveOneSide),
            planes: [primary[1], primary[2], primary[0], lfe, primary[3], primary[4]]
        )
    }

    private mutating func synthesize(_ input: [Int32], state: inout SynthesisState) -> [Int32] {
        let transformed = imdctHalf(input)
        for index in 0..<32 {
            state.history[state.offset + index] = transformed[index]
        }
        let window = DTSCoreDecodeTables.nonPerfectSynthesisFIR
        var output = Array(repeating: Int32(0), count: 32)
        var nextDelayed = Array(repeating: Int32(0), count: 32)
        for index in 0..<16 {
            var a = Int64(state.delayed[index]) << 21
            var b = Int64(state.delayed[index + 16]) << 21
            var c: Int64 = 0
            var d: Int64 = 0
            var position = 0
            while position < 512 {
                let historyBase = state.offset + position
                let wrapped = historyBase < 512 ? historyBase : historyBase - 512
                a += Int64(window[index + position]) * Int64(state.history[wrapped + index])
                b += Int64(window[index + position + 16]) * Int64(state.history[wrapped + 15 - index])
                c += Int64(window[index + position + 32]) * Int64(state.history[wrapped + 16 + index])
                d += Int64(window[index + position + 48]) * Int64(state.history[wrapped + 31 - index])
                position += 64
            }
            output[index] = clip23(Int64(normalize(a, bits: 21)))
            output[index + 16] = clip23(Int64(normalize(b, bits: 21)))
            nextDelayed[index] = normalize(c, bits: 21)
            nextDelayed[index + 16] = normalize(d, bits: 21)
        }
        state.delayed = nextDelayed
        state.offset = (state.offset - 32) & 511
        return output
    }

    private mutating func interpolateLFE(_ samples: [Int32]) -> [Int32] {
        let source = lfeHistory + samples
        var output = Array(repeating: Int32(0), count: samples.count * 64)
        for sample in samples.indices {
            let center = lfeHistory.count + sample
            for phase in 0..<32 {
                var first: Int64 = 0
                var second: Int64 = 0
                for tap in 0..<8 {
                    first += Int64(DTSCoreDecodeTables.lfeFIR64[phase * 8 + tap])
                        * Int64(source[center - tap])
                    second += Int64(DTSCoreDecodeTables.lfeFIR64[255 - phase * 8 - tap])
                        * Int64(source[center - tap])
                }
                output[sample * 64 + phase] = clip23(Int64(normalize(first, bits: 23)))
                output[sample * 64 + 32 + phase] = clip23(Int64(normalize(second, bits: 23)))
            }
        }
        lfeHistory = Array(source.suffix(8))
        return output
    }

    private func imdctHalf(_ input: [Int32]) -> [Int32] {
        var first = Array(repeating: Int32(0), count: 32)
        var second = Array(repeating: Int32(0), count: 32)
        let magnitude = input.reduce(0) { $0 + abs(Int64($1)) }
        let shift = magnitude > 0x40_0000 ? 2 : 0
        let rounding = shift > 0 ? Int64(1 << (shift - 1)) : 0
        for index in 0..<32 {
            first[index] = Int32((Int64(input[index]) + rounding) >> shift)
        }
        sumA(first, inputOffset: 0, output: &second, outputOffset: 0, length: 16)
        sumB(first, inputOffset: 0, output: &second, outputOffset: 16, length: 16)
        clipAll(&second)
        sumA(second, inputOffset: 0, output: &first, outputOffset: 0, length: 8)
        sumB(second, inputOffset: 0, output: &first, outputOffset: 8, length: 8)
        sumC(second, inputOffset: 16, output: &first, outputOffset: 16, length: 8)
        sumD(second, inputOffset: 16, output: &first, outputOffset: 24, length: 8)
        clipAll(&first)
        dctA(first, inputOffset: 0, output: &second, outputOffset: 0)
        dctB(first, inputOffset: 8, output: &second, outputOffset: 8)
        dctB(first, inputOffset: 16, output: &second, outputOffset: 16)
        dctB(first, inputOffset: 24, output: &second, outputOffset: 24)
        clipAll(&second)
        modA(second, inputOffset: 0, output: &first, outputOffset: 0)
        modB(&second, inputOffset: 16, output: &first, outputOffset: 16)
        clipAll(&first)
        modC(first, output: &second)
        for index in 0..<32 {
            second[index] = clip23(Int64(second[index]) << shift)
        }
        var output = Array(repeating: Int32(0), count: 32)
        for index in 0..<16 {
            let reverse = 31 - index
            output[index] = clip23(Int64(second[index]) - Int64(second[reverse]))
            output[16 + index] = clip23(Int64(second[index]) + Int64(second[reverse]))
        }
        return output
    }

    private func dequantize(_ value: Int32, allocation: Int, scale: Int32, lossless: Bool) -> Int32 {
        if allocation == 0 { return 0 }
        let table = lossless ? DTSCoreDecodeTables.losslessQuant : DTSCoreDecodeTables.lossyQuant
        var product = Int64(table[allocation]) * Int64(scale)
        var shift = 0
        if product > (1 << 23) {
            shift = 64 - product.leadingZeroBitCount - 23
            product >>= shift
        }
        return clip23(Int64(normalize(Int64(value) * product, bits: 22 - shift)))
    }

    private func scaleIndex(_ indices: [Int], at index: Int) throws -> Int {
        guard indices.indices.contains(index) else {
            throw DTSError.malformed("DTS Core scale factor index is missing")
        }
        return indices[index]
    }

    private func scaleFactor(_ index: Int) throws -> Int32 {
        guard DTSCoreDecodeTables.scaleFactorQuant7.indices.contains(index),
              DTSCoreDecodeTables.scaleFactorQuant7[index] != 0 else {
            throw DTSError.malformed("DTS Core scale factor index exceeds the 7-bit table")
        }
        return DTSCoreDecodeTables.scaleFactorQuant7[index]
    }

    private func multiplyQ23(_ first: Int32, _ second: Int32) -> Int32 {
        normalize(Int64(first) * Int64(second), bits: 23)
    }

    @inline(__always)
    private func normalize(_ value: Int64, bits: Int) -> Int32 {
        if bits <= 0 { return Int32(truncatingIfNeeded: value) }
        return Int32(truncatingIfNeeded: (value + (Int64(1) << (bits - 1))) >> bits)
    }

    @inline(__always)
    private func clip23(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }

    private func clipAll(_ values: inout [Int32]) {
        for index in values.indices { values[index] = clip23(Int64(values[index])) }
    }

    private func sumA(_ input: [Int32], inputOffset: Int, output: inout [Int32], outputOffset: Int, length: Int) {
        for index in 0..<length {
            output[outputOffset + index] = input[inputOffset + 2 * index]
                &+ input[inputOffset + 2 * index + 1]
        }
    }

    private func sumB(_ input: [Int32], inputOffset: Int, output: inout [Int32], outputOffset: Int, length: Int) {
        output[outputOffset] = input[inputOffset]
        for index in 1..<length {
            output[outputOffset + index] = input[inputOffset + 2 * index]
                &+ input[inputOffset + 2 * index - 1]
        }
    }

    private func sumC(_ input: [Int32], inputOffset: Int, output: inout [Int32], outputOffset: Int, length: Int) {
        for index in 0..<length { output[outputOffset + index] = input[inputOffset + 2 * index] }
    }

    private func sumD(_ input: [Int32], inputOffset: Int, output: inout [Int32], outputOffset: Int, length: Int) {
        output[outputOffset] = input[inputOffset + 1]
        for index in 1..<length {
            output[outputOffset + index] = input[inputOffset + 2 * index - 1]
                &+ input[inputOffset + 2 * index + 1]
        }
    }

    private func dctA(_ input: [Int32], inputOffset: Int, output: inout [Int32], outputOffset: Int) {
        for row in 0..<8 {
            var sum: Int64 = 0
            for column in 0..<8 {
                sum += Int64(Self.dctACoefficients[row * 8 + column])
                    * Int64(input[inputOffset + column])
            }
            output[outputOffset + row] = normalize(sum, bits: 23)
        }
    }

    private func dctB(_ input: [Int32], inputOffset: Int, output: inout [Int32], outputOffset: Int) {
        for row in 0..<8 {
            var sum = Int64(input[inputOffset]) << 23
            for column in 0..<7 {
                sum += Int64(Self.dctBCoefficients[row * 7 + column])
                    * Int64(input[inputOffset + 1 + column])
            }
            output[outputOffset + row] = normalize(sum, bits: 23)
        }
    }

    private func modA(_ input: [Int32], inputOffset: Int, output: inout [Int32], outputOffset: Int) {
        for index in 0..<8 {
            output[outputOffset + index] = multiplyQ23(
                Self.modACoefficients[index],
                input[inputOffset + index] &+ input[inputOffset + 8 + index]
            )
        }
        for index in 8..<16 {
            let reverse = 15 - index
            output[outputOffset + index] = multiplyQ23(
                Self.modACoefficients[index],
                input[inputOffset + reverse] &- input[inputOffset + 8 + reverse]
            )
        }
    }

    private func modB(_ input: inout [Int32], inputOffset: Int, output: inout [Int32], outputOffset: Int) {
        for index in 0..<8 {
            input[inputOffset + 8 + index] = multiplyQ23(
                Self.modBCoefficients[index],
                input[inputOffset + 8 + index]
            )
        }
        for index in 0..<8 {
            output[outputOffset + index] = input[inputOffset + index] &+ input[inputOffset + 8 + index]
            output[outputOffset + 8 + index] = input[inputOffset + 7 - index]
                &- input[inputOffset + 15 - index]
        }
    }

    private func modC(_ input: [Int32], output: inout [Int32]) {
        for index in 0..<16 {
            output[index] = multiplyQ23(
                Self.modCCoefficients[index], input[index] &+ input[16 + index]
            )
        }
        for index in 16..<32 {
            let reverse = 31 - index
            output[index] = multiplyQ23(
                Self.modCCoefficients[index], input[reverse] &- input[16 + reverse]
            )
        }
    }

    private static let quantizationSelectorGroupSizes = [1, 3, 3, 3, 3, 7, 7, 7, 7, 7]
    private static let dctACoefficients: [Int32] = [
        8_348_215, 8_027_397, 7_398_092, 6_484_482, 5_321_677, 3_954_362, 2_435_084, 822_227,
        8_027_397, 5_321_677, 822_227, -3_954_362, -7_398_092, -8_348_215, -6_484_482, -2_435_084,
        7_398_092, 822_227, -6_484_482, -8_027_397, -2_435_084, 5_321_677, 8_348_215, 3_954_362,
        6_484_482, -3_954_362, -8_027_397, 822_227, 8_348_215, 2_435_084, -7_398_092, -5_321_677,
        5_321_677, -7_398_092, -2_435_084, 8_348_215, -822_227, -8_027_397, 3_954_362, 6_484_482,
        3_954_362, -8_348_215, 5_321_677, 2_435_084, -8_027_397, 6_484_482, 822_227, -7_398_092,
        2_435_084, -6_484_482, 8_348_215, -7_398_092, 3_954_362, 822_227, -5_321_677, 8_027_397,
        822_227, -2_435_084, 3_954_362, -5_321_677, 6_484_482, -7_398_092, 8_027_397, -8_348_215,
    ]
    private static let dctBCoefficients: [Int32] = [
        8_227_423, 7_750_063, 6_974_873, 5_931_642, 4_660_461, 3_210_181, 1_636_536,
        6_974_873, 3_210_181, -1_636_536, -5_931_642, -8_227_423, -7_750_063, -4_660_461,
        4_660_461, -3_210_181, -8_227_423, -5_931_642, 1_636_536, 7_750_063, 6_974_873,
        1_636_536, -7_750_063, -4_660_461, 5_931_642, 6_974_873, -3_210_181, -8_227_423,
        -1_636_536, -7_750_063, 4_660_461, 5_931_642, -6_974_873, -3_210_181, 8_227_423,
        -4_660_461, -3_210_181, 8_227_423, -5_931_642, -1_636_536, 7_750_063, -6_974_873,
        -6_974_873, 3_210_181, 1_636_536, -5_931_642, 8_227_423, -7_750_063, 4_660_461,
        -8_227_423, 7_750_063, -6_974_873, 5_931_642, -4_660_461, 3_210_181, -1_636_536,
    ]
    private static let modACoefficients: [Int32] = [
        4_199_362, 4_240_198, 4_323_885, 4_454_708, 4_639_772, 4_890_013, 5_221_943, 5_660_703,
        -6_245_623, -7_040_975, -8_158_494, -9_809_974, -12_450_076, -17_261_920, -28_585_092, -85_479_984,
    ]
    private static let modBCoefficients: [Int32] = [
        4_214_598, 4_383_036, 4_755_871, 5_425_934, 6_611_520, 8_897_610, 14_448_934, 42_791_536,
    ]
    private static let modCCoefficients: [Int32] = [
        1_048_892, 1_051_425, 1_056_522, 1_064_244, 1_074_689, 1_087_987, 1_104_313, 1_123_884,
        1_146_975, 1_173_922, 1_205_139, 1_241_133, 1_282_529, 1_330_095, 1_384_791, 1_447_815,
        -1_520_688, -1_605_358, -1_704_360, -1_821_051, -1_959_964, -2_127_368, -2_332_183, -2_587_535,
        -2_913_561, -3_342_802, -3_931_480, -4_785_806, -6_133_390, -8_566_050, -14_253_820, -42_727_120,
    ]
}
