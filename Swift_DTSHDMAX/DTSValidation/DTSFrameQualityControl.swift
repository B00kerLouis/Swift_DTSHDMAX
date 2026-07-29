import Foundation

/// Access-unit evidence used by the encoder/QC pipeline.
///
/// Hashes are reported for the complete AU and for each public component. A
/// reference comparison also performs a byte-for-byte range comparison; the
/// comparison is not inferred from hashes alone.
public struct DTSAccessUnitQualityRecord: Sendable, Equatable, Codable {
    public let index: Int
    public let byteOffset: UInt64
    public let byteCount: Int
    public let pcmSampleCount: Int
    public let accessUnitSHA256: String
    public let coreByteOffset: UInt64?
    public let coreByteCount: Int?
    public let coreSHA256: String?
    public let exssByteOffset: UInt64?
    public let exssByteCount: Int?
    public let exssSHA256: String?
    public let byteIdenticalToExpected: Bool?
    public let coreByteIdenticalToExpected: Bool?
    public let exssByteIdenticalToExpected: Bool?
}

public struct DTSFrameQualityReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let expectedPath: String?
    public let fileByteCount: UInt64
    public let elementaryStreamOffset: UInt64
    public let elementaryStreamByteCount: UInt64
    public let streamSHA256: String
    public let expectedStreamSHA256: String?
    public let accessUnitCount: Int
    public let coreAccessUnitCount: Int
    public let exssAccessUnitCount: Int
    public let totalAccessUnitByteCount: UInt64
    public let pcmSampleCount: UInt64
    public let offsetsAreContiguous: Bool
    public let endsAtElementaryStreamBoundary: Bool
    public let firstDifferingAccessUnit: Int?
    public let allAccessUnitsByteIdentical: Bool?
    public let allCoreComponentsByteIdentical: Bool?
    public let allExSSComponentsByteIdentical: Bool?
    public let records: [DTSAccessUnitQualityRecord]

    public var isStructurallyValid: Bool {
        accessUnitCount > 0
            && offsetsAreContiguous
            && endsAtElementaryStreamBoundary
            && accessUnitCount == exssAccessUnitCount
    }

    public var isByteExactToExpected: Bool {
        isStructurallyValid && allAccessUnitsByteIdentical == true
    }
}

/// Performs complete, access-unit-aligned QC without invoking an external
/// decoder. It is intentionally independent of the encoder and can therefore
/// be used as a release gate for generated streams and supplied oracles.
public enum DTSFrameQualityControl {
    public static func inspect(
        inputURL: URL,
        expectedURL: URL? = nil
    ) throws -> DTSFrameQualityReport {
        let input = inputURL.standardizedFileURL
        let expected = expectedURL?.standardizedFileURL
        let inputSize = try fileSize(input)
        let inputElementary = try elementaryRange(input, fileByteCount: inputSize)
        let infos = try DTSStreamInspector().inspect(
            url: input,
            maximumAccessUnits: Int.max
        )
        let expectedInfos: [DTSAccessUnitInfo]
        if let expected {
            let size = try fileSize(expected)
            _ = try elementaryRange(expected, fileByteCount: size)
            expectedInfos = try DTSStreamInspector().inspect(
                url: expected,
                maximumAccessUnits: Int.max
            )
        } else {
            expectedInfos = []
        }

        let inputStreamSHA = try SHA256Hasher.hash(fileAt: input)
        let expectedStreamSHA = try expected.map { try SHA256Hasher.hash(fileAt: $0) }
        var records: [DTSAccessUnitQualityRecord] = []
        records.reserveCapacity(infos.count)
        var offsetsAreContiguous = true
        var totalBytes: UInt64 = 0
        var totalSamples: UInt64 = 0
        var firstDiffering: Int?
        var allUnitsEqual = expected != nil && infos.count == expectedInfos.count
        var allCoreEqual = allUnitsEqual
        var allExSSEqual = allUnitsEqual

        for (index, info) in infos.enumerated() {
            // Core starts at the AU boundary. ExSS follows the 32-bit aligned
            // Core size; for ExSS-only streams it starts at the AU boundary.
            let exssOffset: UInt64?
            if let coreByteCount = info.coreByteCount, info.exssByteCount != nil {
                exssOffset = info.byteOffset + UInt64((coreByteCount + 3) & ~3)
            } else if info.coreByteCount == nil, info.exssByteCount != nil {
                exssOffset = info.byteOffset
            } else {
                exssOffset = nil
            }
            let coreHash = try info.coreByteCount.map {
                try SHA256Hasher.hash(
                    fileAt: input,
                    byteOffset: info.byteOffset,
                    byteCount: UInt64($0)
                )
            }
            let exssHash = try zipOptional(exssOffset, info.exssByteCount).map { offset, count in
                try SHA256Hasher.hash(
                    fileAt: input,
                    byteOffset: offset,
                    byteCount: UInt64(count)
                )
            }
            let unitHash = try SHA256Hasher.hash(
                fileAt: input,
                byteOffset: info.byteOffset,
                byteCount: UInt64(info.byteCount)
            )

            let isContiguous: Bool
            if let previous = infos[safe: index - 1] {
                isContiguous = previous.byteOffset + UInt64(previous.byteCount) == info.byteOffset
            } else {
                isContiguous = info.byteOffset == inputElementary.byteOffset
            }
            offsetsAreContiguous = offsetsAreContiguous && isContiguous
            totalBytes += UInt64(info.byteCount)
            totalSamples += UInt64(info.pcmSampleCount)

            var unitEqual: Bool?
            var coreEqual: Bool?
            var exssEqual: Bool?
            if let expected, index < expectedInfos.count {
                let expectedInfo = expectedInfos[index]
                let sameSize = info.byteCount == expectedInfo.byteCount
                if sameSize {
                    unitEqual = try rangesAreIdentical(
                        input,
                        info.byteOffset,
                        UInt64(info.byteCount),
                        expected,
                        expectedInfo.byteOffset,
                        UInt64(expectedInfo.byteCount)
                    )
                } else {
                    unitEqual = false
                }
                coreEqual = try componentRangesAreIdentical(
                    input: input,
                    info: info,
                    expected: expected,
                    expectedInfo: expectedInfo,
                    component: .core
                )
                exssEqual = try componentRangesAreIdentical(
                    input: input,
                    info: info,
                    expected: expected,
                    expectedInfo: expectedInfo,
                    component: .exss
                )
                if unitEqual != true, firstDiffering == nil { firstDiffering = index }
                allUnitsEqual = allUnitsEqual && unitEqual == true
                allCoreEqual = allCoreEqual && coreEqual == true
                allExSSEqual = allExSSEqual && exssEqual == true
            } else if expected != nil {
                unitEqual = false
                coreEqual = false
                exssEqual = false
                if firstDiffering == nil { firstDiffering = index }
                allUnitsEqual = false
                allCoreEqual = false
                allExSSEqual = false
            }

            records.append(DTSAccessUnitQualityRecord(
                index: index,
                byteOffset: info.byteOffset,
                byteCount: info.byteCount,
                pcmSampleCount: info.pcmSampleCount,
                accessUnitSHA256: unitHash,
                coreByteOffset: info.coreByteCount == nil ? nil : info.byteOffset,
                coreByteCount: info.coreByteCount,
                coreSHA256: coreHash,
                exssByteOffset: exssOffset,
                exssByteCount: info.exssByteCount,
                exssSHA256: exssHash,
                byteIdenticalToExpected: unitEqual,
                coreByteIdenticalToExpected: coreEqual,
                exssByteIdenticalToExpected: exssEqual
            ))
        }

        let endOffset = infos.last.map { $0.byteOffset + UInt64($0.byteCount) }
        return DTSFrameQualityReport(
            inputPath: input.path,
            expectedPath: expected?.path,
            fileByteCount: inputSize,
            elementaryStreamOffset: inputElementary.byteOffset,
            elementaryStreamByteCount: inputElementary.byteCount,
            streamSHA256: inputStreamSHA,
            expectedStreamSHA256: expectedStreamSHA,
            accessUnitCount: infos.count,
            coreAccessUnitCount: infos.filter { $0.coreByteCount != nil }.count,
            exssAccessUnitCount: infos.filter { $0.exssByteCount != nil }.count,
            totalAccessUnitByteCount: totalBytes,
            pcmSampleCount: totalSamples,
            offsetsAreContiguous: offsetsAreContiguous,
            endsAtElementaryStreamBoundary: endOffset == inputElementary.endOffset,
            firstDifferingAccessUnit: firstDiffering,
            allAccessUnitsByteIdentical: expected == nil ? nil : allUnitsEqual,
            allCoreComponentsByteIdentical: expected == nil ? nil : allCoreEqual,
            allExSSComponentsByteIdentical: expected == nil ? nil : allExSSEqual,
            records: records
        )
    }

    private enum Component { case core, exss }

    private static func componentRangesAreIdentical(
        input: URL,
        info: DTSAccessUnitInfo,
        expected: URL,
        expectedInfo: DTSAccessUnitInfo,
        component: Component
    ) throws -> Bool {
        let lhs: (UInt64, UInt64)?
        let rhs: (UInt64, UInt64)?
        switch component {
        case .core:
            lhs = info.coreByteCount.map { (info.byteOffset, UInt64($0)) }
            rhs = expectedInfo.coreByteCount.map { (expectedInfo.byteOffset, UInt64($0)) }
        case .exss:
            lhs = componentRange(info, exss: true)
            rhs = componentRange(expectedInfo, exss: true)
        }
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?):
            return try rangesAreIdentical(input, left.0, left.1, expected, right.0, right.1)
        default: return false
        }
    }

    private static func componentRange(_ info: DTSAccessUnitInfo, exss: Bool) -> (UInt64, UInt64)? {
        guard exss, let count = info.exssByteCount else { return nil }
        let start = info.coreByteCount.map { ($0 + 3) & ~3 } ?? 0
        return (info.byteOffset + UInt64(start), UInt64(count))
    }

    private static func rangesAreIdentical(
        _ lhsURL: URL, _ lhsOffset: UInt64, _ lhsCount: UInt64,
        _ rhsURL: URL, _ rhsOffset: UInt64, _ rhsCount: UInt64
    ) throws -> Bool {
        guard lhsCount == rhsCount else { return false }
        let lhs = try FileHandle(forReadingFrom: lhsURL)
        let rhs = try FileHandle(forReadingFrom: rhsURL)
        defer { try? lhs.close(); try? rhs.close() }
        try lhs.seek(toOffset: lhsOffset)
        try rhs.seek(toOffset: rhsOffset)
        var remaining = lhsCount
        while remaining > 0 {
            let count = Int(min(remaining, UInt64(1 << 20)))
            let left = try lhs.read(upToCount: count) ?? Data()
            let right = try rhs.read(upToCount: count) ?? Data()
            guard left.count == count, right.count == count else { return false }
            guard left == right else { return false }
            remaining -= UInt64(count)
        }
        return true
    }

    private static func elementaryRange(_ url: URL, fileByteCount: UInt64) throws -> DTSHDFileContainer.ElementaryStreamRange {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: Int(min(fileByteCount, UInt64(1 << 16)))) ?? Data()
        return try DTSHDFileContainer.elementaryStreamRange(in: prefix, fileByteCount: fileByteCount)
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw DTSError.io("cannot determine stream size: \(url.path)")
            }
            return size.uint64Value
        } catch let error as DTSError { throw error }
        catch { throw DTSError.io("cannot inspect \(url.path): \(error.localizedDescription)") }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

private func zipOptional<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
