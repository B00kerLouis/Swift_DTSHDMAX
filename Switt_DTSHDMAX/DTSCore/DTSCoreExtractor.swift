import Foundation

public struct DTSCoreExtractionReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let outputPath: String
    public let frameCount: Int
    public let sampleCount: Int
    public let byteCount: Int
    public let sha256: String
}

public enum DTSCoreExtractor {
    public static func extract(inputURL: URL, outputURL: URL) throws -> DTSCoreExtractionReport {
        let input = inputURL.standardizedFileURL
        let output = outputURL.standardizedFileURL
        guard input.path != output.path else {
            throw DTSError.invalidArgument("Core input and output paths must differ")
        }
        let infos = try DTSStreamInspector().inspect(url: input, maximumAccessUnits: Int.max)
        guard !infos.isEmpty, infos.allSatisfy({ $0.coreByteCount != nil }) else {
            throw DTSError.unsupported("Core extraction requires a Core-bearing access unit in every frame")
        }
        let inputHandle: FileHandle
        do { inputHandle = try FileHandle(forReadingFrom: input) }
        catch { throw DTSError.io("cannot open \(input.path): \(error.localizedDescription)") }
        defer { try? inputHandle.close() }

        var core = Data()
        core.reserveCapacity(infos.reduce(0) { $0 + ($1.coreByteCount ?? 0) })
        for info in infos {
            let count = info.coreByteCount!
            do { try inputHandle.seek(toOffset: info.byteOffset) }
            catch { throw DTSError.io("cannot seek Core frame: \(error.localizedDescription)") }
            let frame: Data
            do { frame = try inputHandle.read(upToCount: count) ?? Data() }
            catch { throw DTSError.io("cannot read Core frame: \(error.localizedDescription)") }
            guard frame.count == count else {
                throw DTSError.truncated(field: "DTS Core frame", bitOffset: Int(info.byteOffset) * 8 + frame.count * 8)
            }
            core.append(frame)
        }
        do { try core.write(to: output, options: .atomic) }
        catch { throw DTSError.io("cannot write \(output.path): \(error.localizedDescription)") }
        return DTSCoreExtractionReport(
            inputPath: input.path,
            outputPath: output.path,
            frameCount: infos.count,
            sampleCount: infos.reduce(0) { $0 + $1.pcmSampleCount },
            byteCount: core.count,
            sha256: SHA256Hasher.hash(core)
        )
    }
}
