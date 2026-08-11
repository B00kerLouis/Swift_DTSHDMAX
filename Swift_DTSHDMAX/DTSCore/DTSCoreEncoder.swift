import Foundation

public struct DTSCoreEncoderConfiguration: Codable, Equatable, Sendable {
    public let frameByteCount: Int

    public init(frameByteCount: Int = 2_012) {
        self.frameByteCount = frameByteCount
    }
}

/// Native, fixed-topology 48 kHz DTS Coherent Acoustics Core encoder.
///
/// This research profile writes 512-sample, 5.1 frames with five full-band
/// QMF channels plus 64x LFE. It uses linear bit allocation, block-coded
/// quantizer indices, no ADPCM, no joint intensity, and no extensions.
public struct DTSCoreEncoder: Sendable {
    public let configuration: DTSCoreEncoderConfiguration

    public init(configuration: DTSCoreEncoderConfiguration = .init()) {
        self.configuration = configuration
    }

    public func encode(_ pcm: PCMBuffer) throws -> Data {
        guard pcm.format.layout == .fiveOneSide,
              pcm.format.sampleRate == 48_000,
              pcm.format.bitDepth == 24 else {
            throw DTSError.unsupported("DTS Core encoder requires 48 kHz/24-bit 5.1(side) PCM")
        }
        guard pcm.sampleCount > 0, pcm.sampleCount.isMultiple(of: 512) else {
            throw DTSError.unsupported("DTS Core sample count must be a positive multiple of 512")
        }
        guard configuration.frameByteCount >= 1_850, configuration.frameByteCount <= 16_384 else {
            throw DTSError.valueOutOfRange(
                field: "DTS Core frame byte count",
                value: String(configuration.frameByteCount)
            )
        }
        var stream = Data()
        stream.reserveCapacity(pcm.sampleCount / 512 * configuration.frameByteCount)
        var histories = Array(repeating: Array(repeating: Int32(0), count: 512), count: 5)
        for offset in stride(from: 0, to: pcm.sampleCount, by: 512) {
            stream.append(
                try encodeFrame(
                    try pcm.frame(at: offset, count: 512),
                    histories: &histories
                )
            )
        }
        return stream
    }

    func encodeFrame(_ pcm: PCMBuffer) throws -> Data {
        var histories = Array(repeating: Array(repeating: Int32(0), count: 512), count: 5)
        return try encodeFrame(pcm, histories: &histories)
    }

    fileprivate func encodeFrame(_ pcm: PCMBuffer, histories: inout [[Int32]]) throws -> Data {
        guard pcm.format.layout == .fiveOneSide, pcm.sampleCount == 512 else {
            throw DTSError.invalidArgument("DTS Core frame must be 512 samples of 5.1 PCM")
        }
        let codedPlanes = [2, 0, 1, 4, 5].map { pcm.planes[$0] } // C, L, R, Ls, Rs
        let subbands = analyze(codedPlanes, histories: &histories)
        let quantized = quantize(subbands)
        let lfe = quantizeLFE(pcm.planes[3])

        var writer = BitWriter()
        try writeFrameHeader(to: &writer)
        try writePrimaryAudioHeader(to: &writer)
        try writeSubframe(quantized: quantized, lfe: lfe, to: &writer)
        writer.alignToByte()
        guard writer.byteCount <= configuration.frameByteCount else {
            throw DTSError.valueOutOfRange(
                field: "DTS Core coded frame",
                value: "\(writer.byteCount) > \(configuration.frameByteCount) bytes"
            )
        }
        let paddingByteCount = configuration.frameByteCount - writer.byteCount
        if paddingByteCount > 0 {
            try writer.write(
                bytes: repeatElement(UInt8(0), count: paddingByteCount),
                field: "core.padding"
            )
        }
        return writer.data()
    }

    private struct QuantizedBands {
        let samples: [[[Int]]]
        let scaleIndices: [[Int]]
    }

    private struct QuantizedLFE {
        let samples: [Int]
        let scaleIndex: Int
    }

    private func analyze(_ planes: [[Int32]], histories: inout [[Int32]]) -> [[[Double]]] {
        var output = Array(
            repeating: Array(repeating: Array(repeating: 0.0, count: 16), count: 32),
            count: 5
        )
        for channel in 0..<5 {
            var history = histories[channel]
            var historyStart = 0
            for block in 0..<16 {
                var accumulator = Array(repeating: 0.0, count: 64)
                var coefficient = 0
                for sample in historyStart..<512 {
                    accumulator[coefficient & 63] += Double(history[sample])
                        * 16.0 * DTSCoreFilterTables.nonPerfectAnalysisFIR[coefficient]
                    coefficient += 1
                }
                if historyStart > 0 {
                    for sample in 0..<historyStart {
                        accumulator[coefficient & 63] += Double(history[sample])
                            * 16.0 * DTSCoreFilterTables.nonPerfectAnalysisFIR[coefficient]
                        coefficient += 1
                    }
                }
                for index in 16..<32 {
                    accumulator[index] -= accumulator[31 - index]
                }
                for index in 32..<48 {
                    accumulator[index] += accumulator[95 - index]
                }
                for band in 0..<32 {
                    var response = 0.0
                    for index in 16..<48 {
                        let cosineIndex = ((2 * band + 1) * (2 * (index + 16) + 1) << 3) & 2_047
                        response += accumulator[index] * DTSCoreFilterTables.cosine[cosineIndex] / 16.0
                    }
                    // The reference analysis operates on left-justified S32
                    // while Core synthesis is normalized to Q23; compensate
                    // the QMF bank gain before scalar quantization.
                    response /= 133.0
                    output[channel][band][block] = ((band + 1) & 2) != 0 ? -response : response
                }
                let inputBase = block * 32
                for sample in 0..<32 {
                    history[historyStart + sample] = Int32(clamping: Int64(planes[channel][inputBase + sample]) << 8)
                }
                historyStart = (historyStart + 32) & 511
            }
            histories[channel] = planes[channel].map {
                Int32(clamping: Int64($0) << 8)
            }
        }
        return output
    }

    private func quantize(_ bands: [[[Double]]]) -> QuantizedBands {
        let step = Double(Self.lossyQuantStep)
        let normalization = Double(1 << 22)
        var samples = Array(
            repeating: Array(repeating: Array(repeating: 0, count: 16), count: 32),
            count: 5
        )
        var indices = Array(repeating: Array(repeating: 0, count: 32), count: 5)
        for channel in 0..<5 {
            for band in 0..<32 {
                let peak = bands[channel][band].lazy.map(abs).max() ?? 0
                let requiredScale = peak * normalization / (12.0 * step)
                let index = scaleIndex(atLeast: requiredScale)
                indices[channel][band] = index
                let quantum = step * Double(Self.scaleFactors[index]) / normalization
                for sample in 0..<16 {
                    samples[channel][band][sample] = min(
                        12,
                        max(-12, Int((bands[channel][band][sample] / quantum).rounded()))
                    )
                }
            }
        }
        return QuantizedBands(samples: samples, scaleIndices: indices)
    }

    private func quantizeLFE(_ plane: [Int32]) -> QuantizedLFE {
        var downsampled = Array(repeating: 0.0, count: 8)
        for block in 0..<8 {
            let range = (block * 64)..<((block + 1) * 64)
            downsampled[block] = plane[range].reduce(0.0) { $0 + Double($1) } / 64.0
        }
        let peak = downsampled.lazy.map(abs).max() ?? 0
        let requiredScale = peak / (127.0 * 0.035)
        let index = scaleIndex(atLeast: requiredScale)
        let quantum = Double(Self.scaleFactors[index]) * 0.035
        let values = downsampled.map { min(127, max(-128, Int(($0 / quantum).rounded()))) }
        return QuantizedLFE(samples: values, scaleIndex: index)
    }

    private func scaleIndex(atLeast value: Double) -> Int {
        for index in Self.scaleFactors.indices where Self.scaleFactors[index] > 0
            && Double(Self.scaleFactors[index]) >= value {
            return index
        }
        return Self.scaleFactors.lastIndex(where: { $0 > 0 }) ?? 0
    }

    private func writeFrameHeader(to writer: inout BitWriter) throws {
        try writer.write(0x7ffe_8001, bitCount: 32, field: "core.sync")
        try writer.write(1, bitCount: 1, field: "FTYPE")
        try writer.write(31, bitCount: 5, field: "SHORT")
        try writer.write(0, bitCount: 1, field: "CPF")
        try writer.write(15, bitCount: 7, field: "NBLKS") // 16 blocks * 32 = 512 PCM samples
        try writer.write(UInt64(configuration.frameByteCount - 1), bitCount: 14, field: "FSIZE")
        try writer.write(9, bitCount: 6, field: "AMODE") // C, L, R, Ls, Rs
        try writer.write(13, bitCount: 4, field: "SFREQ") // 48 kHz
        // A 2,012-byte Core frame at 48 kHz / 512 samples is the 1,509 kbps
        // CBR profile used by both supplied HDMA and DTS:X reference streams.
        // RATE=29 denotes open bitrate and contradicts the actual frame model.
        try writer.write(24, bitCount: 5, field: "RATE")
        try writer.write(0, bitCount: 1, field: "MIX")
        try writer.write(0, bitCount: 1, field: "DYNF")
        try writer.write(0, bitCount: 1, field: "TIMEF")
        try writer.write(0, bitCount: 1, field: "AUXF")
        try writer.write(0, bitCount: 1, field: "HDCD")
        try writer.write(0, bitCount: 3, field: "EXT_AUDIO_ID")
        try writer.write(0, bitCount: 1, field: "EXT_AUDIO")
        // Encoder Suite sets ASPF and emits a DSYNC word after every
        // subsubframe.  Keeping only the mandatory final DSYNC is syntactically
        // decodable, but strict terminals use the advertised synchronization
        // cadence while acquiring a stream from 00:00.
        try writer.write(1, bitCount: 1, field: "ASPF")
        try writer.write(2, bitCount: 2, field: "LFF") // 64x LFE
        try writer.write(1, bitCount: 1, field: "HFLAG")
        try writer.write(0, bitCount: 1, field: "FILTS") // non-perfect reconstruction
        try writer.write(7, bitCount: 4, field: "VERNUM")
        try writer.write(1, bitCount: 2, field: "CHIST")
        try writer.write(6, bitCount: 3, field: "PCMR") // 24-bit source PCM, non-ES
        try writer.write(0, bitCount: 1, field: "SUMF")
        try writer.write(0, bitCount: 1, field: "SUMS")
        try writer.write(0, bitCount: 4, field: "DIALNORM")
    }

    private func writePrimaryAudioHeader(to writer: inout BitWriter) throws {
        try writer.write(0, bitCount: 4, field: "SUBFRAMES")
        try writer.write(4, bitCount: 3, field: "PCHS")
        for channel in 0..<5 { try writer.write(30, bitCount: 5, field: "SUBBAND_ACTIVITY[\(channel)]") }
        for channel in 0..<5 { try writer.write(31, bitCount: 5, field: "VQ_START[\(channel)]") }
        for channel in 0..<5 { try writer.write(0, bitCount: 3, field: "JOINT_INTENSITY[\(channel)]") }
        for channel in 0..<5 { try writer.write(0, bitCount: 2, field: "TRANSIENT_SEL[\(channel)]") }
        for channel in 0..<5 { try writer.write(6, bitCount: 3, field: "SCALE_SEL[\(channel)]") }
        for channel in 0..<5 { try writer.write(6, bitCount: 3, field: "BITALLOC_SEL[\(channel)]") }
        let selectorBitCounts = [1, 2, 2, 2, 2, 3, 3, 3, 3, 3]
        let selectorValues = [1, 3, 3, 3, 3, 7, 7, 7, 7, 7]
        for codebook in 0..<10 {
            for channel in 0..<5 {
                try writer.write(
                    UInt64(selectorValues[codebook]),
                    bitCount: selectorBitCounts[codebook],
                    field: "QUANT_INDEX_SEL[\(channel)][\(codebook)]"
                )
            }
        }
    }

    private func writeSubframe(
        quantized: QuantizedBands,
        lfe: QuantizedLFE,
        to writer: inout BitWriter
    ) throws {
        try writer.write(1, bitCount: 2, field: "SUBSUBFRAMES")
        try writer.write(0, bitCount: 3, field: "PARTIAL_SAMPLES")
        for channel in 0..<5 {
            for band in 0..<32 { try writer.write(0, bitCount: 1, field: "PRED[\(channel)][\(band)]") }
        }
        for channel in 0..<5 {
            for band in 0..<32 { try writer.write(7, bitCount: 5, field: "ABITS[\(channel)][\(band)]") }
        }
        for channel in 0..<5 {
            for band in 0..<32 { try writer.write(0, bitCount: 1, field: "TRANSITION[\(channel)][\(band)]") }
        }
        for channel in 0..<5 {
            for band in 0..<32 {
                try writer.write(
                    UInt64(quantized.scaleIndices[channel][band]),
                    bitCount: 7,
                    field: "SCALE[\(channel)][\(band)]"
                )
            }
        }
        for (index, value) in lfe.samples.enumerated() {
            try writer.write(UInt64(value & 0xff), bitCount: 8, field: "LFE[\(index)]")
        }
        try writer.write(UInt64(lfe.scaleIndex), bitCount: 8, field: "LFE_SCALE")

        for subsubframe in 0..<2 {
            for channel in 0..<5 {
                for band in 0..<32 {
                    let base = subsubframe * 8
                    for group in 0..<2 {
                        var code = 0
                        let groupBase = base + group * 4
                        for sample in stride(from: 3, through: 0, by: -1) {
                            code = code * 25 + quantized.samples[channel][band][groupBase + sample] + 12
                        }
                        try writer.write(
                            UInt64(code),
                            bitCount: 19,
                            field: "AUDIO[\(subsubframe)][\(channel)][\(band)][\(group)]"
                        )
                    }
                }
            }
            try writer.write(
                0xffff,
                bitCount: 16,
                field: "DSYNC[\(subsubframe)]"
            )
        }
    }

    private static let lossyQuantStep: UInt32 = 1_426_063
    private static let scaleFactors: [UInt32] = [
        1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 5, 6, 7, 7, 8,
        10, 11, 12, 14, 16, 18, 20, 23, 26, 30, 34, 38, 44, 50, 56, 64,
        72, 82, 93, 106, 120, 136, 155, 176, 200, 226, 257, 292, 331, 376, 427, 484,
        550, 624, 708, 804, 912, 1_035, 1_175, 1_334, 1_514, 1_718, 1_950, 2_213,
        2_512, 2_851, 3_236, 3_673, 4_169, 4_732, 5_370, 6_095, 6_918, 7_852, 8_913, 10_116,
        11_482, 13_032, 14_791, 16_788, 19_055, 21_627, 24_547, 27_861,
        31_623, 35_892, 40_738, 46_238, 52_481, 59_566, 67_608, 76_736,
        87_096, 98_855, 112_202, 127_350, 144_544, 164_059, 186_209, 211_349,
        239_883, 272_270, 309_030, 350_752, 398_107, 451_856, 512_861, 582_103,
        660_693, 749_894, 851_138, 966_051, 1_096_478, 1_244_515, 1_412_538, 1_603_245,
        1_819_701, 2_065_380, 2_344_229, 2_660_725, 3_019_952, 3_427_678, 3_890_451, 4_415_704,
        5_011_872, 5_688_529, 6_456_542, 7_328_245, 8_317_638, 0, 0, 0
    ]
}

/// Stateful Core frame encoder used by the HDMA pipeline. Keeping the QMF
/// history here avoids materializing the complete Core PCM and Core stream.
struct DTSCoreEncoderSession: Sendable {
    private let encoder: DTSCoreEncoder
    private var histories = Array(
        repeating: Array(repeating: Int32(0), count: 512),
        count: 5
    )

    init(configuration: DTSCoreEncoderConfiguration = .init()) {
        encoder = DTSCoreEncoder(configuration: configuration)
    }

    mutating func encode(_ frame: PCMBuffer) throws -> Data {
        try encoder.encodeFrame(frame, histories: &histories)
    }
}
