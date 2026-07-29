import Foundation

public struct DTSXValueFrequency: Sendable, Equatable, Codable {
    public let value: Int
    public let count: Int
}

public struct DTSXHexFrequency: Sendable, Equatable, Codable {
    public let hex: String
    public let count: Int
}

public struct DTSXFixedByteStatistic: Sendable, Equatable, Codable {
    public let byteOffset: Int
    public let observedFrameCount: Int
    public let uniqueValueCount: Int
    public let dominantHex: String
    public let dominantCount: Int
}

public struct DTSXLengthFieldCandidate: Sendable, Equatable, Codable {
    public let bitOffset: Int
    public let bitWidth: Int
    public let scale: Int
    public let bias: Int
    public let observedFrameCount: Int
    public let matchingFrameCount: Int
    public let uniqueFieldValueCount: Int
    public let matchRatio: Double
}

public struct DTSXHeaderCodeLengthStatistic: Sendable, Equatable, Codable {
    public let code: Int
    public let frameCount: Int
    public let minimumPayloadByteCount: Int
    public let maximumPayloadByteCount: Int
    public let meanPayloadByteCount: Double
}

public struct DTSXPrivateSyntaxSurveyReport: Sendable, Equatable, Codable {
    public let extractionIndexPath: String
    public let payloadPath: String
    public let frameCount: Int
    public let uniquePayloadCount: Int
    public let adjacentIdenticalFrameCount: Int
    public let commonPrefixByteCount: Int
    public let commonPrefixHex: String
    public let commonSuffixByteCount: Int
    public let commonSuffixHex: String
    public let fixedPreambleAfterSyncHex: String?
    public let crc16ZeroPrefixByteCounts: [Int]
    public let payloadLengthModuloFourCounts: [DTSXValueFrequency]
    public let payloadLengthFrequencies: [DTSXValueFrequency]
    public let markerOffsetFrequencies: [DTSXValueFrequency]
    public let accessUnitSpanFrequencies: [DTSXValueFrequency]
    public let headerReservedHighFourBitFrequencies: [DTSXValueFrequency]
    public let headerCodeLowSixBitFrequencies: [DTSXValueFrequency]
    public let headerCodeLengthStatistics: [DTSXHeaderCodeLengthStatistic]
    public let headerCodeDeltaFrequencies: [DTSXValueFrequency]
    public let headerCodePayloadLengthPearsonCorrelation: Double
    public let secondaryHeaderPrefixSixBitFrequencies: [DTSXValueFrequency]
    public let secondaryHeaderCodeLengthStatistics: [DTSXHeaderCodeLengthStatistic]
    public let secondaryHeaderCodeDeltaFrequencies: [DTSXValueFrequency]
    public let secondaryHeaderCodePayloadLengthPearsonCorrelation: Double
    public let trailingZeroBitFrequencies: [DTSXValueFrequency]
    public let prefix24Frequencies: [DTSXHexFrequency]
    public let fixedByteStatistics: [DTSXFixedByteStatistic]
    public let lengthFieldCandidates: [DTSXLengthFieldCandidate]
}

public enum DTSXPrivateSyntaxSurvey {
    public static func analyze(
        indexURL: URL,
        payloadURL: URL,
        outputURL: URL
    ) throws -> DTSXPrivateSyntaxSurveyReport {
        let decoder = JSONDecoder()
        let extraction: DTSXExtractionReport
        let payload: Data
        do {
            extraction = try decoder.decode(
                DTSXExtractionReport.self,
                from: Data(contentsOf: indexURL, options: .mappedIfSafe)
            )
            payload = try Data(contentsOf: payloadURL, options: .mappedIfSafe)
        } catch {
            throw DTSError.io("cannot read XLL-X extraction artifacts: \(error.localizedDescription)")
        }

        let records = extraction.frames.filter { $0.payloadFileOffset != nil && $0.payloadByteCount > 0 }
        guard !records.isEmpty else { throw DTSError.malformed("XLL-X extraction contains no private frames") }
        for record in records {
            let offset = record.payloadFileOffset!
            guard offset >= 0, record.payloadByteCount >= 4,
                  offset + record.payloadByteCount <= payload.count else {
                throw DTSError.malformed("XLL-X payload index is outside its binary payload")
            }
        }

        func frameBytes(_ record: DTSXPrivateFrameRecord) -> Data.SubSequence {
            let start = record.payloadFileOffset!
            return payload[start..<(start + record.payloadByteCount)]
        }

        let first = frameBytes(records[0])
        let minimumByteCount = records.map(\.payloadByteCount).min()!
        var commonPrefixByteCount = 0
        while commonPrefixByteCount < minimumByteCount {
            let expected = first[first.startIndex + commonPrefixByteCount]
            if records.allSatisfy({ record in
                let bytes = frameBytes(record)
                return bytes[bytes.startIndex + commonPrefixByteCount] == expected
            }) {
                commonPrefixByteCount += 1
            } else {
                break
            }
        }
        let commonPrefix = Data(first.prefix(commonPrefixByteCount))
        var commonSuffixByteCount = 0
        while commonSuffixByteCount < minimumByteCount {
            let expected = first[first.endIndex - 1 - commonSuffixByteCount]
            if records.allSatisfy({ record in
                let bytes = frameBytes(record)
                return bytes[bytes.endIndex - 1 - commonSuffixByteCount] == expected
            }) {
                commonSuffixByteCount += 1
            } else {
                break
            }
        }
        let commonSuffix = Data(first.suffix(commonSuffixByteCount))
        let fixedPreambleAfterSync = commonPrefixByteCount > 4
            ? hex(Data(first.dropFirst(4).prefix(commonPrefixByteCount - 4)))
            : nil

        var crc16ZeroPrefixByteCounts: [Int] = []
        if minimumByteCount >= 2 {
            for byteCount in 2...min(64, minimumByteCount) {
                if records.allSatisfy({ record in
                    DTSCRC16.checksum(frameBytes(record).prefix(byteCount)) == 0
                }) {
                    crc16ZeroPrefixByteCounts.append(byteCount)
                }
            }
        }

        let payloadLengthFrequencies = frequencies(records.map(\.payloadByteCount), limit: 64)
        let markerOffsetFrequencies = frequencies(
            records.compactMap { $0.markerCandidates.count == 1 ? $0.markerCandidates[0].byteOffset : nil },
            limit: 64
        )
        let spanFrequencies = frequencies(
            records.map { $0.endAccessUnit - $0.startAccessUnit + 1 },
            limit: 16
        )
        let moduloFrequencies = frequencies(records.map { $0.payloadByteCount & 3 }, limit: 4)
        var headerCodeGroups: [Int: [Int]] = [:]
        var secondaryHeaderCodeGroups: [Int: [Int]] = [:]
        var headerCodes: [Int] = []
        var secondaryHeaderCodes: [Int] = []
        var secondaryHeaderPrefixSixBits: [Int] = []
        var headerReservedHighFourBits: [Int] = []
        var headerCodeLowSixBits: [Int] = []
        var trailingZeroBits: [Int] = []
        headerCodes.reserveCapacity(records.count)
        secondaryHeaderCodes.reserveCapacity(records.count)
        secondaryHeaderPrefixSixBits.reserveCapacity(records.count)
        headerReservedHighFourBits.reserveCapacity(records.count)
        headerCodeLowSixBits.reserveCapacity(records.count)
        trailingZeroBits.reserveCapacity(records.count)
        for record in records {
            let bytes = frameBytes(record)
            if bytes.count >= 24 {
                let word = (Int(bytes[bytes.startIndex + 22]) << 8)
                    | Int(bytes[bytes.startIndex + 23])
                let code = (word >> 6) & 0x3f
                headerReservedHighFourBits.append((word >> 12) & 0x0f)
                headerCodes.append(code)
                headerCodeGroups[code, default: []].append(record.payloadByteCount)
                headerCodeLowSixBits.append(word & 0x3f)
            }
            if bytes.count >= 28 {
                let firstByte = Int(bytes[bytes.startIndex + 26])
                let code = ((firstByte & 0x03) << 8) | Int(bytes[bytes.startIndex + 27])
                secondaryHeaderPrefixSixBits.append(firstByte >> 2)
                secondaryHeaderCodes.append(code)
                secondaryHeaderCodeGroups[code, default: []].append(record.payloadByteCount)
            }
            trailingZeroBits.append(trailingZeroBitCount(bytes))
        }
        let headerCodeLengthStatistics = headerCodeGroups.map { code, lengths in
            DTSXHeaderCodeLengthStatistic(
                code: code,
                frameCount: lengths.count,
                minimumPayloadByteCount: lengths.min()!,
                maximumPayloadByteCount: lengths.max()!,
                meanPayloadByteCount: Double(lengths.reduce(0, +)) / Double(lengths.count)
            )
        }.sorted { $0.code < $1.code }
        let secondaryHeaderCodeLengthStatistics = secondaryHeaderCodeGroups.map { code, lengths in
            DTSXHeaderCodeLengthStatistic(
                code: code,
                frameCount: lengths.count,
                minimumPayloadByteCount: lengths.min()!,
                maximumPayloadByteCount: lengths.max()!,
                meanPayloadByteCount: Double(lengths.reduce(0, +)) / Double(lengths.count)
            )
        }.sorted { $0.code < $1.code }

        var prefixCounts: [String: Int] = [:]
        var payloadHashes = Set<String>()
        var adjacentIdenticalFrameCount = 0
        var previousHash: String?
        for record in records {
            let bytes = frameBytes(record)
            let prefix = hex(Data(bytes.prefix(min(24, bytes.count))))
            prefixCounts[prefix, default: 0] += 1
            if let hash = record.payloadSHA256 {
                payloadHashes.insert(hash)
                if hash == previousHash { adjacentIdenticalFrameCount += 1 }
                previousHash = hash
            }
        }
        var prefixFrequencyValues: [DTSXHexFrequency] = prefixCounts.map {
            DTSXHexFrequency(hex: $0.key, count: $0.value)
        }
        prefixFrequencyValues.sort {
            $0.count == $1.count ? $0.hex < $1.hex : $0.count > $1.count
        }
        let prefixFrequencies = Array(prefixFrequencyValues.prefix(32))

        var fixedByteStatistics: [DTSXFixedByteStatistic] = []
        for byteOffset in 0..<64 {
            var counts: [UInt8: Int] = [:]
            for record in records where record.payloadByteCount > byteOffset {
                let bytes = frameBytes(record)
                counts[bytes[bytes.startIndex + byteOffset], default: 0] += 1
            }
            guard let dominant = counts.max(by: { $0.value < $1.value }) else { continue }
            fixedByteStatistics.append(DTSXFixedByteStatistic(
                byteOffset: byteOffset,
                observedFrameCount: counts.values.reduce(0, +),
                uniqueValueCount: counts.count,
                dominantHex: String(format: "%02x", dominant.key),
                dominantCount: dominant.value
            ))
        }

        let lengthCandidates = findLengthFieldCandidates(records: records, payload: payload)
        let report = DTSXPrivateSyntaxSurveyReport(
            extractionIndexPath: indexURL.standardizedFileURL.path,
            payloadPath: payloadURL.standardizedFileURL.path,
            frameCount: records.count,
            uniquePayloadCount: payloadHashes.count,
            adjacentIdenticalFrameCount: adjacentIdenticalFrameCount,
            commonPrefixByteCount: commonPrefixByteCount,
            commonPrefixHex: hex(commonPrefix),
            commonSuffixByteCount: commonSuffixByteCount,
            commonSuffixHex: hex(commonSuffix),
            fixedPreambleAfterSyncHex: fixedPreambleAfterSync,
            crc16ZeroPrefixByteCounts: crc16ZeroPrefixByteCounts,
            payloadLengthModuloFourCounts: moduloFrequencies,
            payloadLengthFrequencies: payloadLengthFrequencies,
            markerOffsetFrequencies: markerOffsetFrequencies,
            accessUnitSpanFrequencies: spanFrequencies,
            headerReservedHighFourBitFrequencies: frequencies(
                headerReservedHighFourBits,
                limit: 16
            ),
            headerCodeLowSixBitFrequencies: frequencies(headerCodeLowSixBits, limit: 64),
            headerCodeLengthStatistics: headerCodeLengthStatistics,
            headerCodeDeltaFrequencies: frequencies(adjacentDeltas(headerCodes), limit: 64),
            headerCodePayloadLengthPearsonCorrelation: pearsonCorrelation(
                headerCodes,
                records.map(\.payloadByteCount)
            ),
            secondaryHeaderPrefixSixBitFrequencies: frequencies(
                secondaryHeaderPrefixSixBits,
                limit: 64
            ),
            secondaryHeaderCodeLengthStatistics: secondaryHeaderCodeLengthStatistics,
            secondaryHeaderCodeDeltaFrequencies: frequencies(
                adjacentDeltas(secondaryHeaderCodes),
                limit: 64
            ),
            secondaryHeaderCodePayloadLengthPearsonCorrelation: pearsonCorrelation(
                secondaryHeaderCodes,
                records.map(\.payloadByteCount)
            ),
            trailingZeroBitFrequencies: frequencies(trailingZeroBits, limit: 64),
            prefix24Frequencies: prefixFrequencies,
            fixedByteStatistics: fixedByteStatistics,
            lengthFieldCandidates: lengthCandidates
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try encoder.encode(report).write(to: outputURL, options: .atomic) }
        catch { throw DTSError.io("cannot write XLL-X syntax survey: \(error.localizedDescription)") }
        return report
    }

    private static func findLengthFieldCandidates(
        records: [DTSXPrivateFrameRecord],
        payload: Data
    ) -> [DTSXLengthFieldCandidate] {
        var candidates: [DTSXLengthFieldCandidate] = []
        let scales = [1, 2, 4, 8]
        for bitOffset in 160..<320 {
            for bitWidth in 4...20 where bitOffset + bitWidth <= 384 {
                var values: [(length: Int, field: Int)] = []
                values.reserveCapacity(records.count)
                var uniqueValues = Set<Int>()
                for record in records where record.payloadByteCount * 8 >= bitOffset + bitWidth {
                    let start = record.payloadFileOffset!
                    let value = readBits(payload, byteOffset: start, bitOffset: bitOffset, width: bitWidth)
                    values.append((record.payloadByteCount, value))
                    uniqueValues.insert(value)
                }
                guard values.count == records.count, uniqueValues.count > 1 else { continue }
                for scale in scales {
                    var biasCounts: [Int: Int] = [:]
                    for value in values {
                        biasCounts[value.length - scale * value.field, default: 0] += 1
                    }
                    guard let best = biasCounts.max(by: { $0.value < $1.value }) else { continue }
                    let ratio = Double(best.value) / Double(values.count)
                    if ratio >= 0.95 {
                        candidates.append(DTSXLengthFieldCandidate(
                            bitOffset: bitOffset,
                            bitWidth: bitWidth,
                            scale: scale,
                            bias: best.key,
                            observedFrameCount: values.count,
                            matchingFrameCount: best.value,
                            uniqueFieldValueCount: uniqueValues.count,
                            matchRatio: ratio
                        ))
                    }
                }
            }
        }
        return candidates.sorted {
            if $0.matchRatio != $1.matchRatio { return $0.matchRatio > $1.matchRatio }
            if $0.matchingFrameCount != $1.matchingFrameCount {
                return $0.matchingFrameCount > $1.matchingFrameCount
            }
            return $0.bitWidth < $1.bitWidth
        }.prefix(64).map { $0 }
    }

    private static func readBits(
        _ data: Data,
        byteOffset: Int,
        bitOffset: Int,
        width: Int
    ) -> Int {
        var value = 0
        for index in 0..<width {
            let absoluteBit = bitOffset + index
            let byte = data[byteOffset + (absoluteBit >> 3)]
            value = (value << 1) | Int((byte >> UInt8(7 - (absoluteBit & 7))) & 1)
        }
        return value
    }

    private static func frequencies(_ values: [Int], limit: Int) -> [DTSXValueFrequency] {
        var counts: [Int: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        var frequencyValues: [DTSXValueFrequency] = counts.map {
            DTSXValueFrequency(value: $0.key, count: $0.value)
        }
        frequencyValues.sort {
            $0.count == $1.count ? $0.value < $1.value : $0.count > $1.count
        }
        return Array(frequencyValues.prefix(limit))
    }

    private static func trailingZeroBitCount(_ bytes: Data.SubSequence) -> Int {
        var count = 0
        for byte in bytes.reversed() {
            if byte == 0 {
                count += 8
                continue
            }
            count += byte.trailingZeroBitCount
            break
        }
        return count
    }

    private static func adjacentDeltas(_ values: [Int]) -> [Int] {
        guard values.count > 1 else { return [] }
        return (1..<values.count).map { values[$0] - values[$0 - 1] }
    }

    private static func pearsonCorrelation(_ lhs: [Int], _ rhs: [Int]) -> Double {
        guard lhs.count == rhs.count, lhs.count > 1 else { return 0 }
        let count = Double(lhs.count)
        let lhsMean = Double(lhs.reduce(0, +)) / count
        let rhsMean = Double(rhs.reduce(0, +)) / count
        var covariance = 0.0
        var lhsVariance = 0.0
        var rhsVariance = 0.0
        for index in lhs.indices {
            let lhsDelta = Double(lhs[index]) - lhsMean
            let rhsDelta = Double(rhs[index]) - rhsMean
            covariance += lhsDelta * rhsDelta
            lhsVariance += lhsDelta * lhsDelta
            rhsVariance += rhsDelta * rhsDelta
        }
        guard lhsVariance > 0, rhsVariance > 0 else { return 0 }
        return covariance / (lhsVariance * rhsVariance).squareRoot()
    }

    private static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(data.count * 2)
        for byte in data {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
