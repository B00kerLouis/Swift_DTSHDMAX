import Foundation

public struct DTSOfficialASTRebuildReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let outputPath: String
    public let accessUnitCount: Int
    public let inputSHA256: String
    public let outputSHA256: String
    public let byteIdentical: Bool
}

/// Reconstructs a DTS-HD file access unit by access unit through the reversible
/// Core/ExSS AST. Container prefix/suffix bytes are preserved, while every
/// elementary-stream access unit is parsed, validated, and serialized again.
public enum DTSOfficialASTRebuilder {
    public static func rebuild(inputURL: URL, outputURL: URL) throws -> DTSOfficialASTRebuildReport {
        let input = inputURL.standardizedFileURL
        let output = outputURL.standardizedFileURL
        guard input.path != output.path else {
            throw DTSError.invalidArgument("AST rebuild input and output paths must differ")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw DTSError.invalidArgument("AST rebuild output already exists: \(output.path)")
        }
        let infos = try DTSStreamInspector().inspect(url: input, maximumAccessUnits: Int.max)
        guard let first = infos.first, let last = infos.last else {
            throw DTSError.malformed("DTS-HD AST rebuild input has no access units")
        }
        let inputHandle: FileHandle
        do { inputHandle = try FileHandle(forReadingFrom: input) }
        catch { throw DTSError.io("cannot open \(input.path): \(error.localizedDescription)") }
        defer { try? inputHandle.close() }
        let fileByteCount: UInt64
        do { fileByteCount = try inputHandle.seekToEnd() }
        catch { throw DTSError.io("cannot determine \(input.path) size: \(error.localizedDescription)") }

        let parent = output.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: temporary) } }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
        } catch {
            throw DTSError.io("cannot create AST rebuild output: \(error.localizedDescription)")
        }
        let outputHandle: FileHandle
        do { outputHandle = try FileHandle(forWritingTo: temporary) }
        catch { throw DTSError.io("cannot open AST rebuild output: \(error.localizedDescription)") }
        defer { try? outputHandle.close() }

        try writeRange(
            input: inputHandle,
            output: outputHandle,
            offset: 0,
            count: Int(first.byteOffset)
        )
        for info in infos {
            let original = try readExactly(inputHandle, offset: info.byteOffset, count: info.byteCount)
            let serialized = try DTSOfficialStreamASTParser.parseAccessUnit(original).serialize()
            guard serialized.count == info.byteCount else {
                throw DTSError.malformed("serialized DTS access-unit size changed at frame \(info.index)")
            }
            do { try outputHandle.write(contentsOf: serialized) }
            catch { throw DTSError.io("cannot write DTS access unit \(info.index): \(error.localizedDescription)") }
        }
        let elementaryEnd = last.byteOffset + UInt64(last.byteCount)
        guard elementaryEnd <= fileByteCount else {
            throw DTSError.truncated(field: "DTS-HD elementary stream", bitOffset: Int(elementaryEnd) * 8)
        }
        try writeRange(
            input: inputHandle,
            output: outputHandle,
            offset: elementaryEnd,
            count: Int(fileByteCount - elementaryEnd)
        )
        do { try outputHandle.synchronize() }
        catch { throw DTSError.io("cannot flush AST rebuild output: \(error.localizedDescription)") }
        do { try FileManager.default.moveItem(at: temporary, to: output) }
        catch { throw DTSError.io("cannot commit AST rebuild output: \(error.localizedDescription)") }
        committed = true

        let inputHash = try SHA256Hasher.hash(fileAt: input)
        let outputHash = try SHA256Hasher.hash(fileAt: output)
        let identical = try filesAreByteIdentical(input, output)
        guard identical, inputHash == outputHash else {
            try? FileManager.default.removeItem(at: output)
            throw DTSError.malformed("DTS-HD AST rebuild differs from its source")
        }
        return DTSOfficialASTRebuildReport(
            inputPath: input.path,
            outputPath: output.path,
            accessUnitCount: infos.count,
            inputSHA256: inputHash,
            outputSHA256: outputHash,
            byteIdentical: true
        )
    }

    private static func writeRange(
        input: FileHandle,
        output: FileHandle,
        offset: UInt64,
        count: Int
    ) throws {
        guard count >= 0 else { throw DTSError.malformed("negative DTS copy range") }
        var cursor = offset
        var remaining = count
        while remaining > 0 {
            let chunk = try readExactly(input, offset: cursor, count: min(1 << 20, remaining))
            do { try output.write(contentsOf: chunk) }
            catch { throw DTSError.io("cannot write DTS copy range: \(error.localizedDescription)") }
            cursor += UInt64(chunk.count)
            remaining -= chunk.count
        }
    }

    private static func readExactly(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        do { try handle.seek(toOffset: offset) }
        catch { throw DTSError.io("cannot seek DTS input: \(error.localizedDescription)") }
        let data: Data
        do { data = try handle.read(upToCount: count) ?? Data() }
        catch { throw DTSError.io("cannot read DTS input: \(error.localizedDescription)") }
        guard data.count == count else {
            throw DTSError.truncated(field: "DTS input", bitOffset: Int(offset) * 8 + data.count * 8)
        }
        return data
    }

    private static func filesAreByteIdentical(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let left = try FileHandle(forReadingFrom: lhs)
        let right = try FileHandle(forReadingFrom: rhs)
        defer { try? left.close(); try? right.close() }
        while true {
            let a = try left.read(upToCount: 1 << 20) ?? Data()
            let b = try right.read(upToCount: 1 << 20) ?? Data()
            guard a == b else { return false }
            if a.isEmpty { return true }
        }
    }
}
