import Foundation

public enum DTSCoreStreamDecoder {
    /// Decodes every Core access unit while preserving ADPCM, QMF, and LFE
    /// history. Containerized `.dtshd` inputs and bare Core streams share the
    /// same access-unit scanner.
    public static func decode(inputURL: URL) throws -> PCMBuffer {
        let input = inputURL.standardizedFileURL
        let infos = try DTSStreamInspector().inspect(url: input, maximumAccessUnits: Int.max)
        guard !infos.isEmpty, infos.allSatisfy({ $0.coreByteCount != nil }) else {
            throw DTSError.unsupported("Core stream decoding requires a Core frame in every access unit")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: input) }
        catch { throw DTSError.io("cannot open \(input.path): \(error.localizedDescription)") }
        defer { try? handle.close() }

        var decoder = DTSCoreDecoder()
        var planes = Array(repeating: [Int32](), count: 6)
        let sampleCapacity = infos.reduce(0) { $0 + $1.pcmSampleCount }
        for channel in planes.indices { planes[channel].reserveCapacity(sampleCapacity) }
        for info in infos {
            let count = info.coreByteCount!
            do { try handle.seek(toOffset: info.byteOffset) }
            catch { throw DTSError.io("cannot seek Core frame: \(error.localizedDescription)") }
            let frame: Data
            do { frame = try handle.read(upToCount: count) ?? Data() }
            catch { throw DTSError.io("cannot read Core frame: \(error.localizedDescription)") }
            guard frame.count == count else {
                throw DTSError.truncated(field: "DTS Core frame", bitOffset: Int(info.byteOffset) * 8)
            }
            let decoded = try decoder.decode(frame: frame)
            for channel in planes.indices {
                planes[channel].append(contentsOf: decoded.planes[channel])
            }
        }
        return try PCMBuffer(
            format: PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .fiveOneSide),
            planes: planes
        )
    }
}
