import Foundation

/// A compact, machine-readable description of the layers observed in a DTS-HD
/// or DTS:X elementary stream. The report describes what the public parser can
/// prove; it does not infer the meaning of the private DTS:X object payload.
public struct DTSAlgorithmChannelSetReport: Sendable, Equatable, Codable {
    public let channelCount: Int
    public let speakerMask: UInt64?
    public let residualChannelMask: UInt64
    public let bitDepth: Int
    public let storageBitDepth: Int
    public let sampleRateIndex: Int
    public let isPrimary: Bool
}

public struct DTSAlgorithmAnalysisReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let streamKind: DTSHDMAStreamKind
    public let streamByteCount: UInt64
    public let streamSHA256: String
    public let accessUnitCount: Int
    public let coreAccessUnitCount: Int
    public let exssAccessUnitCount: Int
    public let coreByteCounts: [Int]
    public let exssByteCounts: [Int]
    public let pcmSampleCountsPerAccessUnit: [Int]
    public let xllFrameCount: Int
    public let xllFrameByteCounts: [Int]
    public let xllSegmentCounts: [Int]
    public let xllSegmentSampleCounts: [Int]
    public let channelSetCount: Int
    public let channelSets: [DTSAlgorithmChannelSetReport]
    public let privateMarkerKinds: [DTSXPrivateMarkerKind]
    public let privateFrameCount: Int
    public let dtsxAssetDescriptorFrameCount: Int
    public let privatePayloadByteCount: Int
    public let resynchronizationByteCount: Int
    public let trailingBufferedByteCount: Int
    public let publicXLLStructureValid: Bool
    public let hasPrivateXLLX: Bool
    public let privateObjectStructureValid: Bool
    public let structuralVerificationPassed: Bool
    public let nativePCMVerification: String
    public let flow: [String]
}

/// Performs the first-file algorithm/data-flow audit without calling an
/// external codec. XLL syntax is extracted once into a temporary index so the
/// report can include channel-set details in addition to stream boundaries.
public enum DTSAlgorithmAnalyzer {
    public static func analyze(inputURL: URL) throws -> DTSAlgorithmAnalysisReport {
        let input = inputURL.standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-dts-algorithm-\(UUID().uuidString)", isDirectory: true)
        let payloadURL = temporaryDirectory.appendingPathComponent("payload.bin")
        let indexURL = temporaryDirectory.appendingPathComponent("index.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let extraction = try DTSXObjectExtractor.extract(
            inputURL: input,
            payloadOutputURL: payloadURL,
            indexOutputURL: indexURL
        )
        let infos = try DTSStreamInspector().inspect(
            url: input,
            maximumAccessUnits: max(1, extraction.summary.accessUnitCount)
        )
        let syntax = extraction.frames.compactMap(\.xllSyntax)
        let firstChannelSets = syntax.first?.channelSets ?? []
        let channelSets = firstChannelSets.map {
            DTSAlgorithmChannelSetReport(
                channelCount: $0.channelCount,
                speakerMask: $0.speakerMask,
                residualChannelMask: $0.residualChannelMask,
                bitDepth: $0.bitDepth,
                storageBitDepth: $0.storageBitDepth,
                sampleRateIndex: $0.sampleRateIndex,
                isPrimary: $0.isPrimary
            )
        }
        let hasScalableChannelSets = firstChannelSets.count > 1
            || firstChannelSets.contains { $0.residualChannelMask != 0 }
        let hasPrivateXLLX = extraction.summary.privateFrameCount > 0
        let hasDTSXAssetDescriptorSignal =
            extraction.summary.dtsxAssetDescriptorFrameCount == extraction.summary.accessUnitCount
        let privateObjectStructureValid = !hasPrivateXLLX
            || (extraction.summary.privateFrameCount == extraction.summary.xllFrameCount
                && hasDTSXAssetDescriptorSignal
                && extraction.summary.ambiguousMarkerFrameCount == 0)
        let publicXLLStructureValid = extraction.summary.xllFrameCount > 0
            && extraction.summary.xllFrameCount == extraction.summary.accessUnitCount
            && extraction.summary.resynchronizationByteCount == 0
            && extraction.summary.trailingBufferedByteCount == 0
            && extraction.frames.allSatisfy { $0.xllSyntax != nil }
        let streamKind: DTSHDMAStreamKind
        if hasPrivateXLLX && hasDTSXAssetDescriptorSignal {
            streamKind = .dtsxHDMA
        } else if extraction.summary.accessUnitCount > 0,
                  extraction.summary.accessUnitCount == infos.count,
                  infos.allSatisfy({ $0.coreByteCount != nil }) {
            streamKind = .dtsHDMA
        } else {
            streamKind = .xllStandalone
        }
        let nativePCMVerification: String
        if hasPrivateXLLX {
            nativePCMVerification = "public-xll-channel-sets-decodable; private-xllx-object-semantics-pending"
        } else if hasScalableChannelSets {
            nativePCMVerification = "pure-swift-core-and-scalable-channel-set-decoders-available; source-pcm-not-supplied"
        } else {
            nativePCMVerification = "public-single-channel-set-profile-can-be-decoded-by-XLLDecoder"
        }
        let coreByteCounts = infos.compactMap(\.coreByteCount)
        let exssByteCounts = infos.compactMap(\.exssByteCount)
        let report = DTSAlgorithmAnalysisReport(
            inputPath: input.path,
            streamKind: streamKind,
            streamByteCount: try fileSize(input),
            streamSHA256: try SHA256Hasher.hash(fileAt: input),
            accessUnitCount: extraction.summary.accessUnitCount,
            coreAccessUnitCount: coreByteCounts.count,
            exssAccessUnitCount: exssByteCounts.count,
            coreByteCounts: sortedUnique(coreByteCounts),
            exssByteCounts: sortedUnique(exssByteCounts),
            pcmSampleCountsPerAccessUnit: sortedUnique(infos.map(\.pcmSampleCount)),
            xllFrameCount: extraction.summary.xllFrameCount,
            xllFrameByteCounts: sortedUnique(
                extraction.frames.compactMap { frame in
                    frame.xllSyntax == nil ? nil : frame.xllFrameByteCount
                }
            ),
            xllSegmentCounts: sortedUnique(syntax.map(\.segmentCount)),
            xllSegmentSampleCounts: sortedUnique(syntax.map(\.segmentSampleCount)),
            channelSetCount: channelSets.count,
            channelSets: channelSets,
            privateMarkerKinds: extraction.summary.standardMarkerCount > 0
                ? [.xllX] + (extraction.summary.imaxMarkerCount > 0 ? [.xllXIMAX] : [])
                : (extraction.summary.imaxMarkerCount > 0 ? [.xllXIMAX] : []),
            privateFrameCount: extraction.summary.privateFrameCount,
            dtsxAssetDescriptorFrameCount: extraction.summary.dtsxAssetDescriptorFrameCount,
            privatePayloadByteCount: extraction.summary.privatePayloadByteCount,
            resynchronizationByteCount: extraction.summary.resynchronizationByteCount,
            trailingBufferedByteCount: extraction.summary.trailingBufferedByteCount,
            publicXLLStructureValid: publicXLLStructureValid,
            hasPrivateXLLX: hasPrivateXLLX,
            privateObjectStructureValid: privateObjectStructureValid,
            structuralVerificationPassed: publicXLLStructureValid && privateObjectStructureValid,
            nativePCMVerification: nativePCMVerification,
            flow: [
                "DTS Core sync/header -> Core access unit and 32-bit aligned FSIZE boundary",
                "ExSS static fields -> presentation/asset descriptor -> XLL component",
                "XLL common header -> channel-set headers -> NAVI segment sizes -> entropy-coded samples",
                hasPrivateXLLX
                    ? "XLL band end -> 32-bit aligned private DTS:X payload boundary"
                    : "XLL band end -> end of public DTS-HD lossless component",
                hasPrivateXLLX
                    ? "Private DTS:X payload -> object/navigation semantics (not defined by the public ETSI parser)"
                    : "No private DTS:X object payload is present"
            ]
        )
        guard report.structuralVerificationPassed else {
            throw DTSError.malformed("DTS algorithm analysis found an invalid public DTS-HD stream")
        }
        return report
    }

    private static func sortedUnique(_ values: [Int]) -> [Int] {
        Array(Set(values)).sorted()
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw DTSError.io("cannot determine stream size: \(url.path)")
            }
            return size.uint64Value
        } catch let error as DTSError {
            throw error
        } catch {
            throw DTSError.io("cannot inspect \(url.path): \(error.localizedDescription)")
        }
    }
}
