import Foundation

/// SMPTE ST 2098-2 Annex B decoder for AudioDataDLC elements (48 kHz layer).
///
/// The 96 kHz extension layer is rejected at the IAFrame level because this
/// pipeline requires SampleRate code 0; a compliant AudioDataDLC element must
/// carry the same DLCSampleRate as its IAFrame (section 10.2.2), which the decoder
/// enforces. All arithmetic follows the normative INT32/INT64 pseudocode in
/// B.6-B.10, including truncating overflow semantics.
enum IABDLCDecoder {
    /// Decodes one AudioDataDLC payload (starting at the DLCSize field) into
    /// 24-bit samples. `sampleCount` and `frameRateCode` come from the
    /// enclosing IAFrame.
    static func decode(
        bytes: [UInt8],
        byteOffset: Int,
        byteLimit: Int,
        sampleCount: Int,
        frameRateCode: Int
    ) throws -> [Int32] {
        let (subBlockCount, subBlockSize) = try dlcSubBlocks(frameRateCode: frameRateCode)
        guard subBlockCount * subBlockSize == sampleCount else {
            throw DTSError.malformed("DLC sub-block layout does not cover the IAFrame sample count")
        }
        var reader = try BitReader(
            bytes: bytes,
            bitOffset: byteOffset * 8,
            bitLimit: byteLimit * 8
        )
        _ = try reader.read(16, field: "DLCSize")
        let dlcSampleRate = try reader.read(2, field: "DLCSampleRate")
        guard dlcSampleRate == 0 else {
            throw DTSError.unsupported("AudioDataDLC sample rate code \(dlcSampleRate) inside a 48 kHz IAFrame")
        }
        let shiftBits = Int(try reader.read(5, field: "ShiftBits"))

        // Predictor information (B.7 inputs).
        let regionCount = Int(try reader.read(2, field: "NumPredRegions48"))
        var regionLengths = [Int](repeating: 0, count: regionCount)
        var orders = [Int](repeating: 0, count: regionCount)
        var directCoefficients = [[Int32]](repeating: [], count: regionCount)
        for region in 0..<regionCount {
            let length = Int(try reader.read(4, field: "RegionLength48"))
            guard length > 0 else {
                throw DTSError.malformed("DLC RegionLength48 must be greater than zero")
            }
            regionLengths[region] = length
            let order = Int(try reader.read(5, field: "Order48"))
            orders[region] = order
            var lattice = [Int32](repeating: 0, count: order + 1)
            for index in 1...max(1, order) where order > 0 {
                lattice[index] = Int32(try reader.read(10, field: "KCoeff48"))
            }
            directCoefficients[region] = convertLatticeToDirectForm(lattice: lattice, order: order)
        }
        if regionCount > 0 {
            guard regionLengths.reduce(0, +) == subBlockCount else {
                throw DTSError.malformed("DLC predictor regions do not cover every sub block")
            }
        }

        // Entropy-coded residual (section 9.6).
        var residual = [Int32](repeating: 0, count: sampleCount)
        for subBlock in 0..<subBlockCount {
            let base = subBlock * subBlockSize
            let codeType = try reader.read(1, field: "DLC CodeType")
            if codeType == 0 {
                let bitDepth = Int(try reader.read(5, field: "DLC BitDepth"))
                for index in 0..<subBlockSize {
                    var magnitude: Int64 = 0
                    if bitDepth > 0 {
                        magnitude = Int64(try reader.read(bitDepth, field: "Residual48"))
                    }
                    residual[base + index] = try signedResidual(magnitude, reader: &reader)
                }
            } else {
                let riceRemainderBits = Int(try reader.read(5, field: "RiceRemBits"))
                for index in 0..<subBlockSize {
                    var quotient: Int64 = 0
                    while try reader.read(1, field: "DLC UnaryBit") == 1 {
                        quotient += 1
                        guard quotient <= 1 << 24 else {
                            throw DTSError.malformed("DLC unary quotient is implausibly large")
                        }
                    }
                    var magnitude = quotient << riceRemainderBits
                    if riceRemainderBits > 0 {
                        magnitude += Int64(try reader.read(riceRemainderBits, field: "Residual48 remainder"))
                    }
                    residual[base + index] = try signedResidual(magnitude, reader: &reader)
                }
            }
        }

        // Inverse prediction (B.8) and final shifting (B.10).
        var pcm = [Int32](repeating: 0, count: sampleCount)
        if regionCount == 0 {
            pcm = residual
        } else {
            var buffer = [Int32](repeating: 0, count: 64)
            var writeIndex = 0
            var sample = 0
            for region in 0..<regionCount {
                let coefficients = directCoefficients[region]
                let order = orders[region]
                for _ in 0..<(regionLengths[region] * subBlockSize) {
                    var readIndex = writeIndex
                    var accumulator: Int64 = 0
                    for tap in 1...max(1, order) where order > 0 {
                        accumulator -= Int64(buffer[readIndex]) * Int64(coefficients[tap])
                        readIndex = (readIndex - 1) & 63
                    }
                    let predicted = Int32(truncatingIfNeeded: accumulator >> 20)
                    let output = predicted &+ residual[sample]
                    writeIndex = (writeIndex + 1) & 63
                    buffer[writeIndex] = output
                    pcm[sample] = output
                    sample += 1
                }
            }
            guard sample == sampleCount else {
                throw DTSError.malformed("DLC predictor regions decoded \(sample) of \(sampleCount) samples")
            }
        }
        for index in 0..<sampleCount {
            // B.10 produces 32-bit output; the top 24 bits are the sample.
            pcm[index] = (pcm[index] &<< shiftBits) >> 8
        }
        return pcm
    }

    private static func signedResidual(_ magnitude: Int64, reader: inout BitReader) throws -> Int32 {
        guard magnitude <= Int64(Int32.max) else {
            throw DTSError.valueOutOfRange(field: "DLC residual", value: String(magnitude))
        }
        if magnitude == 0 { return 0 }
        let sign = try reader.read(1, field: "DLC residual sign")
        return sign == 1 ? -Int32(magnitude) : Int32(magnitude)
    }

    /// B.7: lattice reflection coefficients to direct-form coefficients with
    /// exact Q20 integer arithmetic.
    private static func convertLatticeToDirectForm(lattice: [Int32], order: Int) -> [Int32] {
        var direct = [Int32](repeating: 0, count: order + 1)
        direct[0] = 1_048_576
        guard order > 0 else { return direct }
        var scaled = lattice
        var temporary = [Int32](repeating: 0, count: order + 1)
        for j in 1...order {
            scaled[j] = (scaled[j] &- 512) &<< 11
            direct[j] = 0
            for k in 1...j {
                let product = Int64(scaled[j]) * Int64(direct[j - k])
                temporary[k] = direct[k] &+ Int32(truncatingIfNeeded: product >> 20)
            }
            for k in 1...j { direct[k] = temporary[k] }
        }
        return direct
    }

    /// ST 2098-2 Table 30. DLC is undefined for the fractional frame rate.
    private static func dlcSubBlocks(frameRateCode: Int) throws -> (count: Int, size: Int) {
        switch frameRateCode {
        case 0x0: (10, 200)
        case 0x1: (10, 192)
        case 0x2: (8, 200)
        case 0x3: (5, 200)
        case 0x4: (5, 192)
        case 0x5: (4, 200)
        case 0x6: (5, 100)
        case 0x7: (4, 120)
        case 0x8: (4, 100)
        default:
            throw DTSError.unsupported("AudioDataDLC is not defined for IAB frame rate code \(frameRateCode)")
        }
    }
}
