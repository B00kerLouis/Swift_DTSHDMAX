import Foundation

public struct DTSOfficialASTAccessUnitRecord: Sendable, Equatable, Codable {
    public let index: Int
    public let byteOffset: UInt64
    public let byteCount: Int
    public let coreByteCount: Int?
    public let exssHeaderByteCount: Int
    public let exssByteCount: Int
    public let exssAssetByteCounts: [Int]
    public let originalSHA256: String
    public let serializedSHA256: String
    public let byteIdenticalAfterSerialization: Bool
}

public struct DTSOfficialASTVerificationReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let streamSHA256: String
    public let accessUnitCount: Int
    public let coreAccessUnitCount: Int
    public let exssAccessUnitCount: Int
    public let byteExactAccessUnitCount: Int
    public let firstDifferingAccessUnit: Int?
    public let allAccessUnitsRoundTripExactly: Bool
    public let records: [DTSOfficialASTAccessUnitRecord]
}

public enum DTSOfficialASTVerifier {
    public static func verify(inputURL: URL) throws -> DTSOfficialASTVerificationReport {
        let input = inputURL.standardizedFileURL
        let infos = try DTSStreamInspector().inspect(url: input, maximumAccessUnits: Int.max)
        guard !infos.isEmpty else { throw DTSError.malformed("official DTS-HD stream has no access units") }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: input) }
        catch { throw DTSError.io("cannot open \(input.path): \(error.localizedDescription)") }
        defer { try? handle.close() }

        var records: [DTSOfficialASTAccessUnitRecord] = []
        records.reserveCapacity(infos.count)
        var firstDifference: Int?
        var exactCount = 0
        for info in infos {
            let original = try readExactly(
                handle: handle,
                offset: info.byteOffset,
                count: info.byteCount
            )
            let ast = try DTSOfficialStreamASTParser.parseAccessUnit(original)
            let serialized = ast.serialize()
            let identical = serialized == original
            if identical { exactCount += 1 }
            else if firstDifference == nil { firstDifference = info.index }
            records.append(DTSOfficialASTAccessUnitRecord(
                index: info.index,
                byteOffset: info.byteOffset,
                byteCount: info.byteCount,
                coreByteCount: ast.core?.frameByteCount,
                exssHeaderByteCount: ast.exss.headerByteCount,
                exssByteCount: ast.exss.frameByteCount,
                exssAssetByteCounts: ast.exss.assetByteCounts,
                originalSHA256: SHA256Hasher.hash(original),
                serializedSHA256: SHA256Hasher.hash(serialized),
                byteIdenticalAfterSerialization: identical
            ))
        }
        return DTSOfficialASTVerificationReport(
            inputPath: input.path,
            streamSHA256: try SHA256Hasher.hash(fileAt: input),
            accessUnitCount: records.count,
            coreAccessUnitCount: records.lazy.filter { $0.coreByteCount != nil }.count,
            exssAccessUnitCount: records.count,
            byteExactAccessUnitCount: exactCount,
            firstDifferingAccessUnit: firstDifference,
            allAccessUnitsRoundTripExactly: exactCount == records.count,
            records: records
        )
    }

    private static func readExactly(
        handle: FileHandle,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        do { try handle.seek(toOffset: offset) }
        catch { throw DTSError.io("cannot seek DTS access unit: \(error.localizedDescription)") }
        let data: Data
        do { data = try handle.read(upToCount: count) ?? Data() }
        catch { throw DTSError.io("cannot read DTS access unit: \(error.localizedDescription)") }
        guard data.count == count else {
            throw DTSError.truncated(field: "DTS access unit", bitOffset: Int(offset) * 8 + data.count * 8)
        }
        return data
    }
}
