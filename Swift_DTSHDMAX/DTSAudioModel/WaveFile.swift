import Foundation

/// Integer PCM held in its WAVE container precision rather than the encoder's
/// supported 24-bit program format. This is intentionally separate from
/// ``PCMBuffer`` so a decoder reconstruction trace can preserve its unshifted
/// Int32 sample units without being treated as authoring PCM.
public struct WaveInt32PCM: Sendable, Equatable {
    public let sampleRate: Int
    public let validBits: Int
    public let layout: DTSChannelLayout
    public let planes: [[Int32]]

    public var sampleCount: Int { planes.first?.count ?? 0 }

    public init(
        sampleRate: Int,
        validBits: Int,
        layout: DTSChannelLayout,
        planes: [[Int32]]
    ) throws {
        guard planes.count == layout.channelCount else {
            throw DTSError.malformed(
                "expected \(layout.channelCount) integer PCM planes, found \(planes.count)"
            )
        }
        let sampleCount = planes.first?.count ?? 0
        guard planes.allSatisfy({ $0.count == sampleCount }) else {
            throw DTSError.malformed("integer PCM plane lengths differ")
        }
        self.sampleRate = sampleRate
        self.validBits = validBits
        self.layout = layout
        self.planes = planes
    }
}

public enum WaveFile {
    private struct FormatChunk {
        let formatTag: UInt16
        let channelCount: Int
        let sampleRate: Int
        let blockAlign: Int
        let containerBits: Int
        let validBits: Int
        let speakerMask: UInt32
    }

    public static func read(from url: URL) throws -> PCMBuffer {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DTSError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
        guard data.count >= 12 else {
            throw DTSError.truncated(field: "RIFF header", bitOffset: 0)
        }
        let container = try data.fourCC(at: 0)
        guard container == "RIFF" || container == "RF64" else {
            throw DTSError.unsupported("input is not RIFF/RF64 WAVE")
        }
        guard try data.fourCC(at: 8) == "WAVE" else {
            throw DTSError.malformed("RIFF form type is not WAVE")
        }

        var cursor = 12
        var format: FormatChunk?
        var dataRange: Range<Int>?
        var rf64DataSize: UInt64?

        while cursor + 8 <= data.count {
            let identifier = try data.fourCC(at: cursor)
            let declaredSize = try data.littleEndianUInt32(at: cursor + 4)
            let body = cursor + 8
            let effectiveSize: UInt64
            if identifier == "data", declaredSize == UInt32.max, let rf64DataSize {
                effectiveSize = rf64DataSize
            } else {
                effectiveSize = UInt64(declaredSize)
            }
            guard effectiveSize <= UInt64(Int.max) else {
                throw DTSError.valueOutOfRange(field: "WAVE chunk size", value: String(effectiveSize))
            }
            let size = Int(effectiveSize)
            guard body <= data.count, size <= data.count - body else {
                throw DTSError.truncated(field: "WAVE chunk \(identifier)", bitOffset: body * 8)
            }

            switch identifier {
            case "ds64":
                guard size >= 16 else { throw DTSError.malformed("RF64 ds64 chunk is too short") }
                rf64DataSize = try data.littleEndianUInt64(at: body + 8)
            case "fmt ":
                format = try parseFormat(data: data, offset: body, size: size)
            case "data":
                dataRange = body..<(body + size)
            default:
                break
            }

            let paddedSize = size + (size & 1)
            guard paddedSize <= data.count - body else { break }
            cursor = body + paddedSize
        }

        guard let format else { throw DTSError.malformed("WAVE fmt chunk is missing") }
        guard let dataRange else { throw DTSError.malformed("WAVE data chunk is missing") }
        guard format.sampleRate == 48_000 else {
            throw DTSError.unsupported("WAVE sample rate \(format.sampleRate) Hz")
        }
        guard format.containerBits == 24, format.validBits == 24 else {
            throw DTSError.unsupported(
                "WAVE must contain 24 valid bits in 24-bit containers, found \(format.validBits)/\(format.containerBits)"
            )
        }
        guard format.blockAlign == format.channelCount * 3 else {
            throw DTSError.malformed("WAVE blockAlign does not match packed 24-bit PCM")
        }
        guard dataRange.count.isMultiple(of: format.blockAlign) else {
            throw DTSError.malformed("WAVE data size is not a whole number of PCM frames")
        }

        let layout = try DTSChannelLayout.fromWave(
            channelCount: format.channelCount,
            speakerMask: format.speakerMask
        )
        let pcmFormat = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: layout)
        let planes = try unpack24(data: data, range: dataRange, stride: format.blockAlign,
                                  destinationBySource: Array(0..<format.channelCount))
        return try PCMBuffer(format: pcmFormat, planes: planes)
    }

    /// Reads a WAVEFORMATEXTENSIBLE 7.1.4 PCM render into the canonical
    /// DTS:X authoring order used by ``DTS714PCMBuffer``:
    /// `L, R, C, LFE, Lss, Rss, Lsr, Rsr, Lfh, Rfh, Lrh, Rrh`.
    ///
    /// WAVE stores channels in ascending speaker-mask order. For the strict
    /// 7.1.4 mask that is `L, R, C, LFE, Lsr, Rsr, Lss, Rss, Lfh, Rfh, Lrh,
    /// Rrh`; side and rear surrounds therefore need an explicit reorder.
    public static func readDTS714(from url: URL) throws -> DTS714PCMBuffer {
        let parsed = try parseWave(from: url)
        let format = parsed.format
        let data = parsed.data
        let dataRange = parsed.dataRange
        let dtsx714WaveSpeakerMask: UInt32 = 0x0002_d63f
        guard format.channelCount == DTS714Channel.allCases.count,
              format.speakerMask == dtsx714WaveSpeakerMask else {
            throw DTSError.unsupported(
                "DTS:X 7.1.4 WAVE requires 12 channels with speaker mask "
                    + "0x\(String(dtsx714WaveSpeakerMask, radix: 16)), found channels="
                    + "\(format.channelCount), mask=0x\(String(format.speakerMask, radix: 16))"
            )
        }
        guard format.sampleRate == DTS714PCMBuffer.sampleRate,
              format.containerBits == DTS714PCMBuffer.bitDepth,
              format.validBits == DTS714PCMBuffer.bitDepth else {
            throw DTSError.unsupported(
                "DTS:X 7.1.4 WAVE must contain 48 kHz packed 24-bit integer PCM"
            )
        }
        guard format.blockAlign == format.channelCount * 3,
              dataRange.count.isMultiple(of: format.blockAlign) else {
            throw DTSError.malformed("DTS:X 7.1.4 WAVE PCM frames are not packed 24-bit interleaved")
        }

        // WAVE: L R C LFE Lsr Rsr Lss Rss Lfh Rfh Lrh Rrh.
        // DTS:X: L R C LFE Lss Rss Lsr Rsr Lfh Rfh Lrh Rrh.
        let waveToDTS714 = [0, 1, 2, 3, 6, 7, 4, 5, 8, 9, 10, 11]
        let planes = try unpack24(data: data, range: dataRange, stride: format.blockAlign,
                                  destinationBySource: waveToDTS714)
        return try DTS714PCMBuffer(planes: planes)
    }

    /// Explicit IMAX selection gives zero-mask thirteen-channel WAVE the
    /// A1...A13 order. A named mask uses ascending WAVE speaker-bit order.
    public static func readIMAX(from url: URL) throws -> DTSIMAXPCMBuffer {
        let parsed = try parseWave(from: url)
        let format = parsed.format
        let namedMask: UInt32 = 0x0002_f63f
        guard format.channelCount == 13, [UInt32(0), namedMask].contains(format.speakerMask),
              format.sampleRate == 48_000, format.containerBits == 24, format.validBits == 24,
              format.blockAlign == 39, parsed.dataRange.count.isMultiple(of: 39) else {
            throw DTSError.unsupported("IMAX WAVE requires 13 channels, 48 kHz packed 24-bit PCM and mask 0 or 0x2f63f")
        }
        let order = format.speakerMask == 0 ? Array(0..<13) : [0,1,2,3,6,7,4,5,8,12,9,10,11]
        let planes = try unpack24(data: parsed.data, range: parsed.dataRange, stride: 39,
                                  destinationBySource: order)
        return try DTSIMAXPCMBuffer(planes: planes)
    }

    /// Borrow immutable file bytes for each lane. No interleaved payload copy
    /// is made; Foundation retains its safe-mapping policy for the file itself.
    private static func unpack24(data: Data, range: Range<Int>, stride: Int,
                                 destinationBySource: [Int]) throws -> [[Int32]] {
        let frames = range.count / stride
        let decoded = try DTSParallel.map(count: destinationBySource.count,
            workerCount: frames >= 65_536 ? DTSParallel.workerCount(for: destinationBySource.count) : 1) { channel in
            var plane = [Int32](repeating: 0, count: frames)
            data.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: UInt8.self)
                plane.withUnsafeMutableBufferPointer { output in
                    var offset = range.lowerBound + channel * 3
                    for sample in 0..<frames {
                        let value = UInt32(source[offset]) | UInt32(source[offset + 1]) << 8 | UInt32(source[offset + 2]) << 16
                        output[sample] = value & 0x800000 == 0 ? Int32(value) : Int32(Int64(value) - 0x1000000)
                        offset += stride
                    }
                }
            }
            return plane
        }
        var planes = Array(repeating: [Int32](), count: decoded.count)
        for source in decoded.indices { planes[destinationBySource[source]] = decoded[source] }
        return planes
    }

    /// Reads little-endian signed PCM in 32-bit containers without applying a
    /// 24-bit range check or shifting the samples. The Core/XLL differential
    /// verifier uses this for a development trace captured before the public
    /// decoder's final `clip23 * 256` conversion.
    public static func readInt32(from url: URL) throws -> WaveInt32PCM {
        let pcm = try readIntegerPCM(from: url)
        guard pcm.validBits == 32 else {
            throw DTSError.unsupported(
                "WAVE must contain 32 valid bits in 32-bit containers, found \(pcm.validBits)-bit integer PCM"
            )
        }
        return pcm
    }

    /// Reads packed 24-bit or 32-bit little-endian integer PCM without
    /// rescaling. Differential tools use packed 24-bit FFmpeg output and
    /// unshifted 32-bit fixed-point traces through the same explicit path.
    public static func readIntegerPCM(from url: URL) throws -> WaveInt32PCM {
        let parsed = try parseWave(from: url)
        let format = parsed.format
        let data = parsed.data
        let dataRange = parsed.dataRange
        guard format.sampleRate == 48_000 else {
            throw DTSError.unsupported("WAVE sample rate \(format.sampleRate) Hz")
        }
        guard (format.containerBits == 24 && format.validBits == 24)
            || (format.containerBits == 32 && format.validBits == 32) else {
            throw DTSError.unsupported(
                "integer PCM oracle must be packed 24-bit or 32-bit, found \(format.validBits)/\(format.containerBits)"
            )
        }
        let bytesPerSample = format.containerBits / 8
        guard format.blockAlign == format.channelCount * bytesPerSample else {
            throw DTSError.malformed("WAVE blockAlign does not match integer PCM precision")
        }
        guard dataRange.count.isMultiple(of: format.blockAlign) else {
            throw DTSError.malformed("WAVE data size is not a whole number of PCM frames")
        }

        let layout = try DTSChannelLayout.fromWave(
            channelCount: format.channelCount,
            speakerMask: format.speakerMask
        )
        let frameCount = dataRange.count / format.blockAlign
        var planes = Array(repeating: [Int32](), count: format.channelCount)
        for channel in planes.indices { planes[channel].reserveCapacity(frameCount) }

        var sampleOffset = dataRange.lowerBound
        for _ in 0..<frameCount {
            for channel in 0..<format.channelCount {
                var raw = UInt32(data[sampleOffset])
                    | (UInt32(data[sampleOffset + 1]) << 8)
                    | (UInt32(data[sampleOffset + 2]) << 16)
                if bytesPerSample == 4 {
                    raw |= UInt32(data[sampleOffset + 3]) << 24
                } else if raw & 0x0080_0000 != 0 {
                    raw |= 0xff00_0000
                }
                planes[channel].append(Int32(bitPattern: raw))
                sampleOffset += bytesPerSample
            }
        }
        return try WaveInt32PCM(
            sampleRate: format.sampleRate,
            validBits: format.validBits,
            layout: layout,
            planes: planes
        )
    }

    /// Reads a single packed-24 mono WAVE without forcing it through a DTS-HD
    /// channel layout. This is used for the supplied 7.1.4 renderer oracle,
    /// whose twelve channels are intentionally stored as individual files.
    public static func readMono24(from url: URL) throws -> [Int32] {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DTSError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
        guard data.count >= 12,
              (try data.fourCC(at: 0) == "RIFF" || data.fourCC(at: 0) == "RF64"),
              try data.fourCC(at: 8) == "WAVE" else {
            throw DTSError.unsupported("input is not RIFF/RF64 WAVE")
        }

        var cursor = 12
        var format: FormatChunk?
        var dataRange: Range<Int>?
        var rf64DataSize: UInt64?
        while cursor + 8 <= data.count {
            let identifier = try data.fourCC(at: cursor)
            let declaredSize = try data.littleEndianUInt32(at: cursor + 4)
            let body = cursor + 8
            let effectiveSize: UInt64
            if identifier == "data", declaredSize == UInt32.max, let rf64DataSize {
                effectiveSize = rf64DataSize
            } else {
                effectiveSize = UInt64(declaredSize)
            }
            guard effectiveSize <= UInt64(Int.max) else {
                throw DTSError.valueOutOfRange(field: "WAVE chunk size", value: String(effectiveSize))
            }
            let size = Int(effectiveSize)
            guard body <= data.count, size <= data.count - body else {
                throw DTSError.truncated(field: "WAVE chunk \(identifier)", bitOffset: body * 8)
            }
            switch identifier {
            case "ds64":
                guard size >= 16 else { throw DTSError.malformed("RF64 ds64 chunk is too short") }
                rf64DataSize = try data.littleEndianUInt64(at: body + 8)
            case "fmt ":
                format = try parseFormat(data: data, offset: body, size: size)
            case "data":
                dataRange = body..<(body + size)
            default:
                break
            }
            let paddedSize = size + (size & 1)
            guard paddedSize <= data.count - body else { break }
            cursor = body + paddedSize
        }

        guard let format, let dataRange else { throw DTSError.malformed("mono WAVE is incomplete") }
        guard format.channelCount == 1, format.sampleRate == 48_000,
              format.containerBits == 24, format.validBits == 24, format.blockAlign == 3 else {
            throw DTSError.unsupported("reference WAVE must be mono 48 kHz packed 24-bit PCM")
        }
        guard dataRange.count.isMultiple(of: 3) else {
            throw DTSError.malformed("mono WAVE data size is not a whole number of samples")
        }
        var samples: [Int32] = []
        samples.reserveCapacity(dataRange.count / 3)
        var offset = dataRange.lowerBound
        while offset < dataRange.upperBound {
            let raw = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16)
            samples.append((raw & 0x0080_0000) == 0 ? Int32(raw) : Int32(Int64(raw) - 0x0100_0000))
            offset += 3
        }
        return samples
    }

    public static func write(_ pcm: PCMBuffer, to url: URL) throws {
        let channels = pcm.format.layout.channelCount
        let dataByteCount64 = UInt64(pcm.sampleCount) * UInt64(channels) * 3
        guard dataByteCount64 <= UInt64(UInt32.max - 68) else {
            throw DTSError.unsupported("RF64 output is not implemented for decoded PCM larger than 4 GiB")
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(68 + Int(dataByteCount64))
        appendASCII("RIFF", to: &bytes)
        appendLE(UInt32(60 + dataByteCount64), to: &bytes)
        appendASCII("WAVE", to: &bytes)
        appendASCII("fmt ", to: &bytes)
        appendLE(UInt32(40), to: &bytes)
        appendLE(UInt16(0xfffe), to: &bytes)
        appendLE(UInt16(channels), to: &bytes)
        appendLE(UInt32(pcm.format.sampleRate), to: &bytes)
        appendLE(UInt32(pcm.format.sampleRate * channels * 3), to: &bytes)
        appendLE(UInt16(channels * 3), to: &bytes)
        appendLE(UInt16(24), to: &bytes)
        appendLE(UInt16(22), to: &bytes)
        appendLE(UInt16(24), to: &bytes)
        appendLE(pcm.format.layout.waveSpeakerMask, to: &bytes)
        // KSDATAFORMAT_SUBTYPE_PCM GUID, stored in Windows GUID byte order.
        bytes.append(contentsOf: [
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
            0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71
        ])
        appendASCII("data", to: &bytes)
        appendLE(UInt32(dataByteCount64), to: &bytes)

        for frame in 0..<pcm.sampleCount {
            for channel in 0..<channels {
                let sample = UInt32(bitPattern: pcm.planes[channel][frame]) & 0x00ff_ffff
                bytes.append(UInt8(sample & 0xff))
                bytes.append(UInt8((sample >> 8) & 0xff))
                bytes.append(UInt8((sample >> 16) & 0xff))
            }
        }

        do {
            try Data(bytes).write(to: url, options: .atomic)
        } catch {
            throw DTSError.io("cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    public static func writeMono24(_ samples: [Int32], to url: URL) throws {
        for sample in samples where sample < -8_388_608 || sample > 8_388_607 {
            throw DTSError.valueOutOfRange(field: "mono PCM", value: String(sample))
        }
        let dataByteCount = samples.count * 3
        guard dataByteCount <= Int(UInt32.max) - 36 else {
            throw DTSError.unsupported("RF64 output is not implemented for mono PCM larger than 4 GiB")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(44 + dataByteCount)
        appendASCII("RIFF", to: &bytes)
        appendLE(UInt32(36 + dataByteCount), to: &bytes)
        appendASCII("WAVE", to: &bytes)
        appendASCII("fmt ", to: &bytes)
        appendLE(UInt32(16), to: &bytes)
        appendLE(UInt16(1), to: &bytes)
        appendLE(UInt16(1), to: &bytes)
        appendLE(UInt32(48_000), to: &bytes)
        appendLE(UInt32(144_000), to: &bytes)
        appendLE(UInt16(3), to: &bytes)
        appendLE(UInt16(24), to: &bytes)
        appendASCII("data", to: &bytes)
        appendLE(UInt32(dataByteCount), to: &bytes)
        for value in samples {
            let sample = UInt32(bitPattern: value) & 0x00ff_ffff
            bytes.append(UInt8(sample & 0xff))
            bytes.append(UInt8((sample >> 8) & 0xff))
            bytes.append(UInt8((sample >> 16) & 0xff))
        }
        do {
            try Data(bytes).write(to: url, options: .atomic)
        } catch {
            throw DTSError.io("cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    private static func parseFormat(data: Data, offset: Int, size: Int) throws -> FormatChunk {
        guard size >= 16 else { throw DTSError.malformed("WAVE fmt chunk is shorter than 16 bytes") }
        let tag = try data.littleEndianUInt16(at: offset)
        let channels = Int(try data.littleEndianUInt16(at: offset + 2))
        let sampleRate = Int(try data.littleEndianUInt32(at: offset + 4))
        let blockAlign = Int(try data.littleEndianUInt16(at: offset + 12))
        let containerBits = Int(try data.littleEndianUInt16(at: offset + 14))

        switch tag {
        case 1:
            return FormatChunk(
                formatTag: tag,
                channelCount: channels,
                sampleRate: sampleRate,
                blockAlign: blockAlign,
                containerBits: containerBits,
                validBits: containerBits,
                speakerMask: channels == 2 ? DTSChannelLayout.stereo.waveSpeakerMask : 0
            )
        case 0xfffe:
            guard size >= 40 else { throw DTSError.malformed("WAVE extensible fmt chunk is shorter than 40 bytes") }
            let extensionSize = try data.littleEndianUInt16(at: offset + 16)
            guard extensionSize >= 22 else { throw DTSError.malformed("WAVE extensible cbSize is less than 22") }
            guard try data.littleEndianUInt16(at: offset + 24) == 1 else {
                throw DTSError.unsupported("WAVE extensible subformat is not integer PCM")
            }
            return FormatChunk(
                formatTag: tag,
                channelCount: channels,
                sampleRate: sampleRate,
                blockAlign: blockAlign,
                containerBits: containerBits,
                validBits: Int(try data.littleEndianUInt16(at: offset + 18)),
                speakerMask: try data.littleEndianUInt32(at: offset + 20)
            )
        default:
            throw DTSError.unsupported("WAVE format tag 0x\(String(tag, radix: 16))")
        }
    }

    private static func parseWave(
        from url: URL
    ) throws -> (data: Data, format: FormatChunk, dataRange: Range<Int>) {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DTSError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
        guard data.count >= 12 else {
            throw DTSError.truncated(field: "RIFF header", bitOffset: 0)
        }
        let container = try data.fourCC(at: 0)
        guard container == "RIFF" || container == "RF64" else {
            throw DTSError.unsupported("input is not RIFF/RF64 WAVE")
        }
        guard try data.fourCC(at: 8) == "WAVE" else {
            throw DTSError.malformed("RIFF form type is not WAVE")
        }

        var cursor = 12
        var format: FormatChunk?
        var dataRange: Range<Int>?
        var rf64DataSize: UInt64?
        while cursor + 8 <= data.count {
            let identifier = try data.fourCC(at: cursor)
            let declaredSize = try data.littleEndianUInt32(at: cursor + 4)
            let body = cursor + 8
            let effectiveSize: UInt64
            if identifier == "data", declaredSize == UInt32.max, let rf64DataSize {
                effectiveSize = rf64DataSize
            } else {
                effectiveSize = UInt64(declaredSize)
            }
            guard effectiveSize <= UInt64(Int.max) else {
                throw DTSError.valueOutOfRange(field: "WAVE chunk size", value: String(effectiveSize))
            }
            let size = Int(effectiveSize)
            guard body <= data.count, size <= data.count - body else {
                throw DTSError.truncated(field: "WAVE chunk \(identifier)", bitOffset: body * 8)
            }
            switch identifier {
            case "ds64":
                guard size >= 16 else { throw DTSError.malformed("RF64 ds64 chunk is too short") }
                rf64DataSize = try data.littleEndianUInt64(at: body + 8)
            case "fmt ":
                format = try parseFormat(data: data, offset: body, size: size)
            case "data":
                dataRange = body..<(body + size)
            default:
                break
            }
            let paddedSize = size + (size & 1)
            guard paddedSize <= data.count - body else { break }
            cursor = body + paddedSize
        }
        guard let format else { throw DTSError.malformed("WAVE fmt chunk is missing") }
        guard let dataRange else { throw DTSError.malformed("WAVE data chunk is missing") }
        return (data, format, dataRange)
    }

    private static func appendASCII(_ string: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: string.utf8)
    }

    private static func appendLE(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8(value >> 8))
    }

    private static func appendLE(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 24) & 0xff))
    }
}

private extension Data {
    func littleEndianUInt64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= count else {
            throw DTSError.truncated(field: "UInt64", bitOffset: Swift.max(0, offset) * 8)
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[offset + index]) << UInt64(index * 8)
        }
        return value
    }
}
