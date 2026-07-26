import Foundation

/// Byte-accurate, access-unit-aligned differential for DTS-HD elementary
/// streams. Semantic parsing is deliberately limited to public Core/ExSS
/// headers. XLL entropy data and DTS:X XLL-X data remain byte ranges until a
/// decoder-verified grammar is available.
public struct DTSCoreHeaderSummary: Sendable, Equatable, Codable {
    public let frameByteCount: Int
    public let pcmBlockCount: Int
    public let audioMode: Int
    public let sampleRateCode: Int
    public let bitrateCode: Int
}

public struct DTSExSSHeaderSummary: Sendable, Equatable, Codable {
    public let frameByteCount: Int
    public let headerByteCount: Int
    public let extensionSubstreamIndex: Int
    public let usesWideSizes: Bool
    public let hasStaticFields: Bool
    public let referenceClockCode: Int?
    public let frameDurationCode: Int?
    public let presentationCount: Int?
    public let assetCount: Int?
}

public struct DTSHDByteDifference: Sendable, Equatable, Codable {
    public let baselineByteCount: Int
    public let variantByteCount: Int
    public let differingByteCount: Int
    public let differingBitCount: Int
    public let firstDifferingByteOffset: Int?
    public let lastDifferingByteOffset: Int?

    public var isIdentical: Bool { differingByteCount == 0 }
}

public struct DTSAccessUnitDifferential: Sendable, Equatable, Codable {
    public let index: Int
    public let baseline: DTSAccessUnitInfo
    public let variant: DTSAccessUnitInfo
    public let baselineCoreHeader: DTSCoreHeaderSummary?
    public let variantCoreHeader: DTSCoreHeaderSummary?
    public let baselineExSSHeader: DTSExSSHeaderSummary?
    public let variantExSSHeader: DTSExSSHeaderSummary?
    public let accessUnitDifference: DTSHDByteDifference
    public let coreDifference: DTSHDByteDifference?
    public let exssDifference: DTSHDByteDifference?
}

public struct DTSHDFrameDifferentialReport: Sendable, Equatable, Codable {
    public let baselinePath: String
    public let variantPath: String
    public let requestedAccessUnitCount: Int
    public let baselineAccessUnitCount: Int
    public let variantAccessUnitCount: Int
    public let comparedAccessUnitCount: Int
    public let identicalAccessUnitCount: Int
    public let firstDifferingAccessUnit: Int?
    public let totalDifferingByteCount: Int64
    public let totalDifferingBitCount: Int64
    public let accessUnits: [DTSAccessUnitDifferential]
}

public struct DTSHDFrameDifferentialSummary: Sendable, Equatable, Codable {
    public let baselinePath: String
    public let variantPath: String
    public let requestedAccessUnitCount: Int
    public let baselineAccessUnitCount: Int
    public let variantAccessUnitCount: Int
    public let comparedAccessUnitCount: Int
    public let identicalAccessUnitCount: Int
    public let firstDifferingAccessUnit: Int?
    public let identicalCoreAccessUnitCount: Int
    public let firstCoreDifferingAccessUnit: Int?
    public let identicalExSSAccessUnitCount: Int
    public let firstExSSDifferingAccessUnit: Int?
    public let totalDifferingByteCount: Int64
    public let totalDifferingBitCount: Int64
}

public struct DTSHDFrameDifferential: Sendable {
    public init() {}

    public func compare(
        baselineURL: URL,
        variantURL: URL,
        maximumAccessUnits: Int
    ) throws -> DTSHDFrameDifferentialReport {
        guard maximumAccessUnits > 0 else {
            throw DTSError.invalidArgument("access-unit comparison count must be positive")
        }

        let baseline = try DTSStreamInspector().inspect(
            url: baselineURL,
            maximumAccessUnits: maximumAccessUnits
        )
        let variant = try DTSStreamInspector().inspect(
            url: variantURL,
            maximumAccessUnits: maximumAccessUnits
        )
        let comparedCount = min(baseline.count, variant.count)
        let baselineHandle = try open(url: baselineURL, role: "baseline")
        let variantHandle = try open(url: variantURL, role: "variant")
        defer {
            try? baselineHandle.close()
            try? variantHandle.close()
        }

        var accessUnits: [DTSAccessUnitDifferential] = []
        accessUnits.reserveCapacity(comparedCount)
        var identicalAccessUnitCount = 0
        var firstDifferingAccessUnit: Int?
        var totalDifferingByteCount: Int64 = 0
        var totalDifferingBitCount: Int64 = 0

        for index in 0..<comparedCount {
            let baselineInfo = baseline[index]
            let variantInfo = variant[index]
            let baselineBytes = try readAccessUnit(
                from: baselineHandle,
                info: baselineInfo,
                role: "baseline"
            )
            let variantBytes = try readAccessUnit(
                from: variantHandle,
                info: variantInfo,
                role: "variant"
            )
            let accessUnitDifference = byteDifference(baselineBytes, variantBytes)
            let coreDifference = difference(
                baseline: component(.core, in: baselineBytes, info: baselineInfo),
                variant: component(.core, in: variantBytes, info: variantInfo)
            )
            let exssDifference = difference(
                baseline: component(.exss, in: baselineBytes, info: baselineInfo),
                variant: component(.exss, in: variantBytes, info: variantInfo)
            )
            if accessUnitDifference.isIdentical {
                identicalAccessUnitCount += 1
            } else if firstDifferingAccessUnit == nil {
                firstDifferingAccessUnit = index
            }
            totalDifferingByteCount += Int64(accessUnitDifference.differingByteCount)
            totalDifferingBitCount += Int64(accessUnitDifference.differingBitCount)

            accessUnits.append(DTSAccessUnitDifferential(
                index: index,
                baseline: baselineInfo,
                variant: variantInfo,
                baselineCoreHeader: coreHeader(in: baselineBytes, info: baselineInfo),
                variantCoreHeader: coreHeader(in: variantBytes, info: variantInfo),
                baselineExSSHeader: exssHeader(in: baselineBytes, info: baselineInfo),
                variantExSSHeader: exssHeader(in: variantBytes, info: variantInfo),
                accessUnitDifference: accessUnitDifference,
                coreDifference: coreDifference,
                exssDifference: exssDifference
            ))
        }

        if firstDifferingAccessUnit == nil, baseline.count != variant.count {
            firstDifferingAccessUnit = comparedCount
        }
        return DTSHDFrameDifferentialReport(
            baselinePath: baselineURL.standardizedFileURL.path,
            variantPath: variantURL.standardizedFileURL.path,
            requestedAccessUnitCount: maximumAccessUnits,
            baselineAccessUnitCount: baseline.count,
            variantAccessUnitCount: variant.count,
            comparedAccessUnitCount: comparedCount,
            identicalAccessUnitCount: identicalAccessUnitCount,
            firstDifferingAccessUnit: firstDifferingAccessUnit,
            totalDifferingByteCount: totalDifferingByteCount,
            totalDifferingBitCount: totalDifferingBitCount,
            accessUnits: accessUnits
        )
    }

    public func summary(of report: DTSHDFrameDifferentialReport) -> DTSHDFrameDifferentialSummary {
        var identicalCoreAccessUnitCount = 0
        var firstCoreDifferingAccessUnit: Int?
        var identicalExSSAccessUnitCount = 0
        var firstExSSDifferingAccessUnit: Int?
        for accessUnit in report.accessUnits {
            if let coreDifference = accessUnit.coreDifference {
                if coreDifference.isIdentical {
                    identicalCoreAccessUnitCount += 1
                } else if firstCoreDifferingAccessUnit == nil {
                    firstCoreDifferingAccessUnit = accessUnit.index
                }
            }
            if let exssDifference = accessUnit.exssDifference {
                if exssDifference.isIdentical {
                    identicalExSSAccessUnitCount += 1
                } else if firstExSSDifferingAccessUnit == nil {
                    firstExSSDifferingAccessUnit = accessUnit.index
                }
            }
        }
        return DTSHDFrameDifferentialSummary(
            baselinePath: report.baselinePath,
            variantPath: report.variantPath,
            requestedAccessUnitCount: report.requestedAccessUnitCount,
            baselineAccessUnitCount: report.baselineAccessUnitCount,
            variantAccessUnitCount: report.variantAccessUnitCount,
            comparedAccessUnitCount: report.comparedAccessUnitCount,
            identicalAccessUnitCount: report.identicalAccessUnitCount,
            firstDifferingAccessUnit: report.firstDifferingAccessUnit,
            identicalCoreAccessUnitCount: identicalCoreAccessUnitCount,
            firstCoreDifferingAccessUnit: firstCoreDifferingAccessUnit,
            identicalExSSAccessUnitCount: identicalExSSAccessUnitCount,
            firstExSSDifferingAccessUnit: firstExSSDifferingAccessUnit,
            totalDifferingByteCount: report.totalDifferingByteCount,
            totalDifferingBitCount: report.totalDifferingBitCount
        )
    }

    private enum Component {
        case core
        case exss
    }

    private func open(url: URL, role: String) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw DTSError.io("cannot open \(role) DTS stream \(url.path): \(error.localizedDescription)")
        }
    }

    private func readAccessUnit(
        from handle: FileHandle,
        info: DTSAccessUnitInfo,
        role: String
    ) throws -> Data {
        do {
            try handle.seek(toOffset: info.byteOffset)
            let data = try handle.read(upToCount: info.byteCount) ?? Data()
            guard data.count == info.byteCount else {
                throw DTSError.truncated(field: "\(role) access unit \(info.index)", bitOffset: data.count * 8)
            }
            return data
        } catch let error as DTSError {
            throw error
        } catch {
            throw DTSError.io("cannot read \(role) access unit \(info.index): \(error.localizedDescription)")
        }
    }

    private func component(
        _ component: Component,
        in bytes: Data,
        info: DTSAccessUnitInfo
    ) -> Data? {
        switch component {
        case .core:
            guard let coreByteCount = info.coreByteCount, coreByteCount <= bytes.count else { return nil }
            return bytes.subdata(in: 0..<coreByteCount)
        case .exss:
            guard let exssByteCount = info.exssByteCount else { return nil }
            let start = info.coreByteCount.map { ($0 + 3) & ~3 } ?? 0
            guard exssByteCount >= 0, start + exssByteCount <= bytes.count else { return nil }
            return bytes.subdata(in: start..<(start + exssByteCount))
        }
    }

    private func difference(baseline: Data?, variant: Data?) -> DTSHDByteDifference? {
        switch (baseline, variant) {
        case (nil, nil): return nil
        case let (baseline?, variant?): return byteDifference(baseline, variant)
        case let (baseline?, nil): return byteDifference(baseline, Data())
        case let (nil, variant?): return byteDifference(Data(), variant)
        }
    }

    private func byteDifference(_ baseline: Data, _ variant: Data) -> DTSHDByteDifference {
        let commonCount = min(baseline.count, variant.count)
        var differingByteCount = 0
        var differingBitCount = 0
        var first: Int?
        var last: Int?
        for index in 0..<commonCount {
            let xor = baseline[index] ^ variant[index]
            guard xor != 0 else { continue }
            differingByteCount += 1
            differingBitCount += xor.nonzeroBitCount
            if first == nil { first = index }
            last = index
        }
        if baseline.count != variant.count {
            let extraCount = abs(baseline.count - variant.count)
            differingByteCount += extraCount
            differingBitCount += extraCount * 8
            if first == nil { first = commonCount }
            last = max(baseline.count, variant.count) - 1
        }
        return DTSHDByteDifference(
            baselineByteCount: baseline.count,
            variantByteCount: variant.count,
            differingByteCount: differingByteCount,
            differingBitCount: differingBitCount,
            firstDifferingByteOffset: first,
            lastDifferingByteOffset: last
        )
    }

    private func coreHeader(in bytes: Data, info: DTSAccessUnitInfo) -> DTSCoreHeaderSummary? {
        guard info.coreByteCount != nil else { return nil }
        do {
            var reader = try BitReader(data: bytes)
            guard try reader.read(32, field: "Core sync") == 0x7ffe_8001 else { return nil }
            _ = try reader.read(1, field: "FTYPE")
            _ = try reader.read(5, field: "SHORT")
            _ = try reader.read(1, field: "CPF")
            let pcmBlockCount = Int(try reader.read(7, field: "NBLKS")) + 1
            let frameByteCount = Int(try reader.read(14, field: "FSIZE")) + 1
            let audioMode = Int(try reader.read(6, field: "AMODE"))
            let sampleRateCode = Int(try reader.read(4, field: "SFREQ"))
            let bitrateCode = Int(try reader.read(5, field: "RATE"))
            return DTSCoreHeaderSummary(
                frameByteCount: frameByteCount,
                pcmBlockCount: pcmBlockCount,
                audioMode: audioMode,
                sampleRateCode: sampleRateCode,
                bitrateCode: bitrateCode
            )
        } catch {
            return nil
        }
    }

    private func exssHeader(in bytes: Data, info: DTSAccessUnitInfo) -> DTSExSSHeaderSummary? {
        guard let exss = component(.exss, in: bytes, info: info) else { return nil }
        do {
            var reader = try BitReader(data: exss)
            guard try reader.read(32, field: "SYNCEXTSSH") == ExSSSyntax.syncWord else { return nil }
            _ = try reader.read(8, field: "UserDefinedBits")
            let extensionSubstreamIndex = Int(try reader.read(2, field: "nExtSSIndex"))
            let usesWideSizes = try reader.read(1, field: "bHeaderSizeType") == 1
            let headerByteCount = Int(try reader.read(usesWideSizes ? 12 : 8, field: "nuExtSSHeaderSize")) + 1
            let frameByteCount = Int(try reader.read(usesWideSizes ? 20 : 16, field: "nuExtSSFsize")) + 1
            let hasStaticFields = try reader.read(1, field: "bStaticFieldsPresent") == 1
            guard hasStaticFields else {
                return DTSExSSHeaderSummary(
                    frameByteCount: frameByteCount,
                    headerByteCount: headerByteCount,
                    extensionSubstreamIndex: extensionSubstreamIndex,
                    usesWideSizes: usesWideSizes,
                    hasStaticFields: false,
                    referenceClockCode: nil,
                    frameDurationCode: nil,
                    presentationCount: nil,
                    assetCount: nil
                )
            }
            let referenceClockCode = Int(try reader.read(2, field: "nuRefClockCode"))
            let frameDurationCode = Int(try reader.read(3, field: "nuExSSFrameDurationCode"))
            _ = try reader.read(1, field: "bTimeStampFlag")
            let presentationCount = Int(try reader.read(3, field: "nuNumAudioPresnt")) + 1
            let assetCount = Int(try reader.read(3, field: "nuNumAssets")) + 1
            return DTSExSSHeaderSummary(
                frameByteCount: frameByteCount,
                headerByteCount: headerByteCount,
                extensionSubstreamIndex: extensionSubstreamIndex,
                usesWideSizes: usesWideSizes,
                hasStaticFields: true,
                referenceClockCode: referenceClockCode,
                frameDurationCode: frameDurationCode,
                presentationCount: presentationCount,
                assetCount: assetCount
            )
        } catch {
            return nil
        }
    }
}
