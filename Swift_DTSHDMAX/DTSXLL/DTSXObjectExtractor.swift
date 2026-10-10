import Foundation

public enum DTSXPrivateMarkerKind: String, Sendable, Equatable, Codable {
    case xllX
    case xllXIMAX
}

public struct DTSXPrivateMarkerCandidate: Sendable, Equatable, Codable {
    public let byteOffset: Int
    public let kind: DTSXPrivateMarkerKind
    public let rawWord: UInt32
}

public struct DTSXXLLChannelSetSummary: Sendable, Equatable, Codable {
    public let channelCount: Int
    public let residualChannelMask: UInt64
    public let bitDepth: Int
    public let storageBitDepth: Int
    public let sampleRateIndex: Int
    public let isPrimary: Bool
    public let speakerMask: UInt64?
}

public struct DTSXXLLFrameSyntaxSummary: Sendable, Equatable, Codable {
    public let commonHeaderByteCount: Int
    public let frameSizeBitCount: Int
    public let segmentCount: Int
    public let segmentSampleCount: Int
    /// Optional so older standalone extraction indices remain readable.
    /// Fresh stream extraction always records the enclosing NAVI width.
    public let segmentSizeBitCount: Int?
    public let channelMaskBitCount: Int
    public let channelSets: [DTSXXLLChannelSetSummary]
}

public struct DTSXPrivateFrameRecord: Sendable, Equatable, Codable {
    public let frameIndex: Int
    public let startAccessUnit: Int
    public let endAccessUnit: Int
    public let xllFrameByteCount: Int
    public let frameSHA256: String
    public let xllSyntax: DTSXXLLFrameSyntaxSummary?
    public let bandDataEndByteOffset: Int
    public let privateDataAlignedByteOffset: Int
    public let markerCandidates: [DTSXPrivateMarkerCandidate]
    public let payloadFileOffset: Int?
    public let payloadByteCount: Int
    public let payloadSHA256: String?
}

public struct DTSXExtractionSummary: Sendable, Equatable, Codable {
    public let inputPath: String
    public let payloadPath: String
    public let indexPath: String
    public let accessUnitCount: Int
    public let xllFrameCount: Int
    public let privateFrameCount: Int
    public let dtsxAssetDescriptorFrameCount: Int
    public let ambiguousMarkerFrameCount: Int
    public let standardMarkerCount: Int
    public let imaxMarkerCount: Int
    public let privatePayloadByteCount: Int
    public let resynchronizationByteCount: Int
    public let trailingBufferedByteCount: Int
}

public struct DTSXExtractionReport: Sendable, Equatable, Codable {
    public let summary: DTSXExtractionSummary
    public let frames: [DTSXPrivateFrameRecord]
}

/// Structural qualification for a DTS:X elementary stream.
///
/// This deliberately does not claim that the private payload has been
/// semantically decoded.  The public XLL framing, CRCs, access-unit
/// reassembly, and the aligned XLL-X marker can be checked independently;
/// object PCM/metadata correctness still requires a DTS:X-aware decoder.
public struct DTSXStreamVerificationReport: Sendable, Equatable, Codable {
    public let inputPath: String
    public let expectedPath: String?
    public let streamByteCount: UInt64
    public let streamSHA256: String
    public let expectedSHA256: String?
    public let byteIdenticalToExpected: Bool?
    public let accessUnitCount: Int
    public let xllFrameCount: Int
    public let privateFrameCount: Int
    public let dtsxAssetDescriptorFrameCount: Int
    public let privatePayloadByteCount: Int
    public let markerKinds: [DTSXPrivateMarkerKind]
    public let resynchronizationByteCount: Int
    public let trailingBufferedByteCount: Int
    public let ambiguousMarkerFrameCount: Int
    public let allPrivateFramesIndexed: Bool
    public let privateSegmentationMatchedFrameCount: Int
    public let allPrivateFramesMatchPublicSegmentation: Bool
    public let privateNavigationWidthMatchedFrameCount: Int
    public let allPrivateNavigationWidthsMatchPublicHeader: Bool
    public let containerNavigationOffsetsMatchAccessUnits: Bool
    public let isStructurallyValid: Bool

    public init(
        inputPath: String,
        expectedPath: String?,
        streamByteCount: UInt64,
        streamSHA256: String,
        expectedSHA256: String?,
        byteIdenticalToExpected: Bool?,
        summary: DTSXExtractionSummary,
        markerKinds: [DTSXPrivateMarkerKind],
        allPrivateFramesIndexed: Bool,
        privateSegmentationMatchedFrameCount: Int,
        privateNavigationWidthMatchedFrameCount: Int = 0,
        containerNavigationOffsetsMatchAccessUnits: Bool = false
    ) {
        self.inputPath = inputPath
        self.expectedPath = expectedPath
        self.streamByteCount = streamByteCount
        self.streamSHA256 = streamSHA256
        self.expectedSHA256 = expectedSHA256
        self.byteIdenticalToExpected = byteIdenticalToExpected
        accessUnitCount = summary.accessUnitCount
        xllFrameCount = summary.xllFrameCount
        privateFrameCount = summary.privateFrameCount
        dtsxAssetDescriptorFrameCount = summary.dtsxAssetDescriptorFrameCount
        privatePayloadByteCount = summary.privatePayloadByteCount
        self.markerKinds = markerKinds
        resynchronizationByteCount = summary.resynchronizationByteCount
        trailingBufferedByteCount = summary.trailingBufferedByteCount
        ambiguousMarkerFrameCount = summary.ambiguousMarkerFrameCount
        self.allPrivateFramesIndexed = allPrivateFramesIndexed
        self.privateSegmentationMatchedFrameCount = privateSegmentationMatchedFrameCount
        allPrivateFramesMatchPublicSegmentation = summary.privateFrameCount > 0
            && privateSegmentationMatchedFrameCount == summary.privateFrameCount
        self.privateNavigationWidthMatchedFrameCount = privateNavigationWidthMatchedFrameCount
        allPrivateNavigationWidthsMatchPublicHeader = summary.privateFrameCount > 0
            && privateNavigationWidthMatchedFrameCount == summary.privateFrameCount
        self.containerNavigationOffsetsMatchAccessUnits = containerNavigationOffsetsMatchAccessUnits
        isStructurallyValid = summary.xllFrameCount > 0
            && summary.xllFrameCount == summary.privateFrameCount
            && summary.accessUnitCount == summary.dtsxAssetDescriptorFrameCount
            && summary.resynchronizationByteCount == 0
            && summary.trailingBufferedByteCount == 0
            && summary.ambiguousMarkerFrameCount == 0
            && allPrivateFramesIndexed
            && allPrivateFramesMatchPublicSegmentation
            && allPrivateNavigationWidthsMatchPublicHeader
            && containerNavigationOffsetsMatchAccessUnits
    }
}

public enum DTSXObjectExtractor {
    private static let coreSyncWord: UInt64 = 0x7ffe_8001
    private static let xllSyncWord: UInt32 = 0x41a2_9547
    private static let xllXSyncWord: UInt32 = 0x0200_0850
    private static let xllXIMAXSyncWord: UInt32 = 0xf140_00d0
    private static let maximumXLLFrameByteCount = 240 << 10

    private struct AccessUnitAsset {
        let byteCount: Int
        let data: Data
        let hasQualifiedDTSXAssetDescriptor: Bool
    }

    private struct PendingSpan {
        var byteCount: Int
        let accessUnit: Int
    }

    private struct PrivateDataBoundary {
        let bandDataEndByteOffset: Int
        let alignedByteOffset: Int
        let marker: DTSXPrivateMarkerCandidate?
        let xllSyntax: DTSXXLLFrameSyntaxSummary
    }

    public static func extract(
        inputURL: URL,
        payloadOutputURL: URL,
        indexOutputURL: URL
    ) throws -> DTSXExtractionReport {
        let input = inputURL.standardizedFileURL
        let payloadOutput = payloadOutputURL.standardizedFileURL
        let indexOutput = indexOutputURL.standardizedFileURL
        let paths = Set([input.path, payloadOutput.path, indexOutput.path])
        guard paths.count == 3 else {
            throw DTSError.invalidArgument("input, payload output, and index output paths must differ")
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: input) }
        catch { throw DTSError.io("cannot open \(input.path): \(error.localizedDescription)") }
        defer { try? handle.close() }
        let fileByteCount = try fileSize(input)

        let headerProbeByteCount = Int(min(fileByteCount, UInt64(1 << 16)))
        let headerProbe = try readExactly(
            handle: handle,
            offset: 0,
            count: headerProbeByteCount,
            field: "DTS-HD file header"
        )
        let elementary = try DTSHDFileContainer.elementaryStreamRange(
            in: headerProbe,
            fileByteCount: fileByteCount
        )

        var streamOffset = elementary.byteOffset
        var accessUnit = 0
        var pending = Data()
        var pendingSpans: [PendingSpan] = []
        var payload = Data()
        var records: [DTSXPrivateFrameRecord] = []
        var resynchronizationByteCount = 0
        var standardMarkerCount = 0
        var imaxMarkerCount = 0
        var ambiguousMarkerFrameCount = 0
        var dtsxAssetDescriptorFrameCount = 0

        while streamOffset < elementary.endOffset {
            let asset = try readAccessUnitAsset(
                handle: handle,
                streamOffset: streamOffset,
                fileByteCount: elementary.endOffset
            )
            streamOffset += UInt64(asset.byteCount)
            if asset.hasQualifiedDTSXAssetDescriptor {
                dtsxAssetDescriptorFrameCount += 1
            }

            var assetStart = 0
            if pending.isEmpty {
                guard let syncOffset = findXLLSync(in: asset.data) else {
                    resynchronizationByteCount += asset.data.count
                    accessUnit += 1
                    continue
                }
                assetStart = syncOffset
                resynchronizationByteCount += syncOffset
            }
            let appended = asset.data.subdata(in: assetStart..<asset.data.count)
            pending.append(appended)
            if !appended.isEmpty {
                pendingSpans.append(PendingSpan(byteCount: appended.count, accessUnit: accessUnit))
            }

            while pending.count >= 8 {
                if bigEndianUInt32(pending, at: 0) != xllSyncWord {
                    guard let syncOffset = findXLLSync(in: pending), syncOffset > 0 else { break }
                    resynchronizationByteCount += syncOffset
                    _ = consume(syncOffset, from: &pending, spans: &pendingSpans)
                    continue
                }

                let frameByteCount = try parseXLLFrameByteCount(pending)
                if pending.count < frameByteCount { break }
                let frame = pending.subdata(in: 0..<frameByteCount)
                let accessUnitRange = consume(frameByteCount, from: &pending, spans: &pendingSpans)
                let boundary = try locatePrivateDataBoundary(in: frame)
                let markers = boundary.marker.map { [$0] } ?? []
                standardMarkerCount += markers.lazy.filter { $0.kind == .xllX }.count
                imaxMarkerCount += markers.lazy.filter { $0.kind == .xllXIMAX }.count

                var payloadOffset: Int?
                var payloadByteCount = 0
                var payloadHash: String?
                if markers.count == 1, let marker = markers.first {
                    let extensionData = frame.subdata(in: marker.byteOffset..<frame.count)
                    payloadOffset = payload.count
                    payloadByteCount = extensionData.count
                    payloadHash = SHA256Hasher.hash(extensionData)
                    payload.append(extensionData)
                } else if markers.count > 1 {
                    ambiguousMarkerFrameCount += 1
                }

                records.append(DTSXPrivateFrameRecord(
                    frameIndex: records.count,
                    startAccessUnit: accessUnitRange.start,
                    endAccessUnit: accessUnitRange.end,
                    xllFrameByteCount: frameByteCount,
                    frameSHA256: SHA256Hasher.hash(frame),
                    xllSyntax: boundary.xllSyntax,
                    bandDataEndByteOffset: boundary.bandDataEndByteOffset,
                    privateDataAlignedByteOffset: boundary.alignedByteOffset,
                    markerCandidates: markers,
                    payloadFileOffset: payloadOffset,
                    payloadByteCount: payloadByteCount,
                    payloadSHA256: payloadHash
                ))
            }
            accessUnit += 1
        }

        let privateFrameCount = records.lazy.filter { $0.payloadFileOffset != nil }.count
        let summary = DTSXExtractionSummary(
            inputPath: input.path,
            payloadPath: payloadOutput.path,
            indexPath: indexOutput.path,
            accessUnitCount: accessUnit,
            xllFrameCount: records.count,
            privateFrameCount: privateFrameCount,
            dtsxAssetDescriptorFrameCount: dtsxAssetDescriptorFrameCount,
            ambiguousMarkerFrameCount: ambiguousMarkerFrameCount,
            standardMarkerCount: standardMarkerCount,
            imaxMarkerCount: imaxMarkerCount,
            privatePayloadByteCount: payload.count,
            resynchronizationByteCount: resynchronizationByteCount,
            trailingBufferedByteCount: pending.count
        )
        let report = DTSXExtractionReport(summary: summary, frames: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try payload.write(to: payloadOutput, options: .atomic)
            try encoder.encode(report).write(to: indexOutput, options: .atomic)
        } catch {
            throw DTSError.io("cannot write XLL-X extraction output: \(error.localizedDescription)")
        }
        return report
    }

    public static func verify(
        inputURL: URL,
        expectedReferenceURL: URL? = nil
    ) throws -> DTSXStreamVerificationReport {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("swift-dtsx-verify-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            throw DTSError.io(
                "cannot create DTS:X verification directory: \(error.localizedDescription)"
            )
        }
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let payloadURL = temporaryDirectory.appendingPathComponent("payload.xllx")
        let extraction = try extract(
            inputURL: inputURL,
            payloadOutputURL: payloadURL,
            indexOutputURL: temporaryDirectory.appendingPathComponent("index.json")
        )
        let allPrivateFramesIndexed = extraction.frames.count == extraction.summary.xllFrameCount
            && extraction.frames.allSatisfy { frame in
                frame.xllSyntax != nil
                    && frame.markerCandidates.count == 1
                    && frame.markerCandidates[0].byteOffset == frame.privateDataAlignedByteOffset
                    && frame.payloadFileOffset != nil
                    && frame.payloadByteCount >= 28
                    && frame.payloadSHA256 != nil
            }
        let payload: Data
        do { payload = try Data(contentsOf: payloadURL, options: .mappedIfSafe) }
        catch {
            throw DTSError.io(
                "cannot read extracted XLL-X verification payload: \(error.localizedDescription)"
            )
        }
        var privateSegmentationMatchedFrameCount = 0
        var privateNavigationWidthMatchedFrameCount = 0
        for frame in extraction.frames {
            guard let syntax = frame.xllSyntax,
                  let payloadFileOffset = frame.payloadFileOffset,
                  payloadFileOffset >= 0,
                  payloadFileOffset + frame.payloadByteCount <= payload.count else {
                continue
            }
            let privateFrame = payload.subdata(
                in: payloadFileOffset..<(payloadFileOffset + frame.payloadByteCount)
            )
            if DTSIMAXPrivateFrame.isIMAX(privateFrame) {
                if let imax = try? DTSIMAXPrivateFrame.parse(privateFrame),
                   (try? imax.decode()) != nil,
                   imax.groups.allSatisfy({ $0.segmentCount == syntax.segmentCount }),
                   let width = syntax.segmentSizeBitCount {
                    privateSegmentationMatchedFrameCount += 1
                    if imax.groups.allSatisfy({ $0.navigationWidth == max(8, width) }) {
                        privateNavigationWidthMatchedFrameCount += 1
                    }
                }
                continue
            }
            guard let ast = try? DTSXPrivateFrameAST.parse(privateFrame[...]),
                  let decoded = try? DTSXPrivateFrameDecoder.decode(
                      ast,
                      segmentCount: syntax.segmentCount,
                      segmentSampleCount: syntax.segmentSampleCount
                  ),
                  decoded.segmentDataEndBitOffsets.count == syntax.segmentCount,
                  decoded.trailingBitsAreAllZero else {
                continue
            }
            privateSegmentationMatchedFrameCount += 1
            guard let sharedWidth = syntax.segmentSizeBitCount else { continue }
            if decoded.noNavigationZeroSideInfo != nil {
                // Legacy "side-info controls" are compact zero NAVI entries
                // at particular widths. They are not exempt from the shared
                // public/private width contract, especially after a seek.
                if (try? ast.parseNavigation(
                    segmentCount: syntax.segmentCount,
                    sharedSegmentSizeBitCount: sharedWidth
                )) != nil {
                    privateNavigationWidthMatchedFrameCount += 1
                }
                continue
            }
            // The native entropy decoder can infer the wrong width and still
            // reproduce its own PCM. Gate actual stream playback separately
            // against the common-header declaration on every access unit.
            let inferredNavigation = try? ast.parseNavigation(
                segmentCount: syntax.segmentCount,
                matching: decoded
            )
            if inferredNavigation == nil {
                if privateFrame.count == 48, ast.primarySixBitCode == 15,
                   syntax.segmentCount == 2, sharedWidth <= 8,
                   decoded.codedPlanes.allSatisfy({ $0.allSatisfy({ $0 == 0 }) }) {
                    privateNavigationWidthMatchedFrameCount += 1
                }
            } else if (try? ast.parseNavigation(
                segmentCount: syntax.segmentCount,
                sharedSegmentSizeBitCount: sharedWidth
            )) != nil {
                privateNavigationWidthMatchedFrameCount += 1
            }
        }
        var markerKinds: [DTSXPrivateMarkerKind] = []
        if extraction.summary.standardMarkerCount > 0 { markerKinds.append(.xllX) }
        if extraction.summary.imaxMarkerCount > 0 { markerKinds.append(.xllXIMAX) }

        let input = inputURL.standardizedFileURL
        let reference = expectedReferenceURL?.standardizedFileURL
        let streamHash = try SHA256Hasher.hash(fileAt: input)
        let expectedHash = try reference.map { try SHA256Hasher.hash(fileAt: $0) }
        let byteIdentical = try reference.map { try filesAreByteIdentical(input, $0) }
        return DTSXStreamVerificationReport(
            inputPath: input.path,
            expectedPath: reference?.path,
            streamByteCount: try fileSize(input),
            streamSHA256: streamHash,
            expectedSHA256: expectedHash,
            byteIdenticalToExpected: byteIdentical,
            summary: extraction.summary,
            markerKinds: markerKinds,
            allPrivateFramesIndexed: allPrivateFramesIndexed,
            privateSegmentationMatchedFrameCount: privateSegmentationMatchedFrameCount,
            privateNavigationWidthMatchedFrameCount: privateNavigationWidthMatchedFrameCount,
            containerNavigationOffsetsMatchAccessUnits: try DTSHDFileContainer.navigationOffsetsMatchAccessUnits(
                at: input,
                accessUnits: DTSStreamInspector().inspect(url: input, maximumAccessUnits: Int.max)
            )
        )
    }

    private static func readAccessUnitAsset(
        handle: FileHandle,
        streamOffset: UInt64,
        fileByteCount: UInt64
    ) throws -> AccessUnitAsset {
        let prefix = try readExactly(handle: handle, offset: streamOffset, count: 16, field: "DTS AU prefix")
        let sync = UInt64(bigEndianUInt32(prefix, at: 0))
        let exssOffset: UInt64
        let coreAlignedByteCount: Int
        if sync == coreSyncWord {
            var reader = try BitReader(data: prefix)
            _ = try reader.read(32, field: "DTS Core sync")
            _ = try reader.read(1, field: "FTYPE")
            _ = try reader.read(5, field: "SHORT")
            _ = try reader.read(1, field: "CPF")
            _ = try reader.read(7, field: "NBLKS")
            let coreByteCount = Int(try reader.read(14, field: "FSIZE")) + 1
            coreAlignedByteCount = (coreByteCount + 3) & ~3
            exssOffset = streamOffset + UInt64(coreAlignedByteCount)
        } else if sync == ExSSSyntax.syncWord {
            coreAlignedByteCount = 0
            exssOffset = streamOffset
        } else {
            throw DTSError.malformed(
                "expected DTS Core or ExSS sync at byte \(streamOffset), found 0x\(String(sync, radix: 16))"
            )
        }

        let exssPrefix = try readExactly(handle: handle, offset: exssOffset, count: 16, field: "ExSS prefix")
        let exssByteCount = try parseExSSFrameByteCount(exssPrefix)
        let totalByteCount = coreAlignedByteCount + exssByteCount
        guard streamOffset + UInt64(totalByteCount) <= fileByteCount else {
            throw DTSError.truncated(field: "DTS access unit", bitOffset: Int(streamOffset) * 8)
        }
        let exss = try readExactly(handle: handle, offset: exssOffset, count: exssByteCount, field: "ExSS frame")
        let parsed = try ExSSParser().parse(frame: exss)
        return AccessUnitAsset(
            byteCount: totalByteCount,
            data: parsed.xllData,
            hasQualifiedDTSXAssetDescriptor: parsed.info.dtsxAssetDescriptorSignal != nil
        )
    }

    private static func parseExSSFrameByteCount(_ prefix: Data) throws -> Int {
        var reader = try BitReader(data: prefix)
        guard try reader.read(32, field: "SYNCEXTSSH") == ExSSSyntax.syncWord else {
            throw DTSError.malformed("ExSS sync word is missing")
        }
        _ = try reader.read(8, field: "UserDefinedBits")
        _ = try reader.read(2, field: "nExtSSIndex")
        let wide = try reader.read(1, field: "bHeaderSizeType") == 1
        _ = try reader.read(wide ? 12 : 8, field: "nuExtSSHeaderSize")
        return Int(try reader.read(wide ? 20 : 16, field: "nuExtSSFsize")) + 1
    }

    private static func parseSingleAsset(_ exss: Data) throws -> Data {
        var reader = try BitReader(data: exss)
        guard try reader.read(32, field: "SYNCEXTSSH") == ExSSSyntax.syncWord else {
            throw DTSError.malformed("ExSS sync word is missing")
        }
        _ = try reader.read(8, field: "UserDefinedBits")
        let exssIndex = Int(try reader.read(2, field: "nExtSSIndex"))
        let wide = try reader.read(1, field: "bHeaderSizeType") == 1
        let headerByteCount = Int(try reader.read(wide ? 12 : 8, field: "nuExtSSHeaderSize")) + 1
        let frameByteCount = Int(try reader.read(wide ? 20 : 16, field: "nuExtSSFsize")) + 1
        guard frameByteCount <= exss.count, headerByteCount <= frameByteCount else {
            throw DTSError.truncated(field: "ExSS frame", bitOffset: 0)
        }

        var presentationCount = 1
        var assetCount = 1
        let staticFields = try reader.read(1, field: "bStaticFieldsPresent") == 1
        if staticFields {
            _ = try reader.read(2, field: "nuRefClockCode")
            _ = try reader.read(3, field: "nuExSSFrameDurationCode")
            if try reader.read(1, field: "bTimeStampFlag") == 1 {
                try reader.skip(36, field: "nuTimeStamp")
            }
            presentationCount = Int(try reader.read(3, field: "nuNumAudioPresnt")) + 1
            assetCount = Int(try reader.read(3, field: "nuNumAssets")) + 1
            var activeMasks: [UInt64] = []
            for presentation in 0..<presentationCount {
                activeMasks.append(try reader.read(exssIndex + 1, field: "nuActiveExSSMask[\(presentation)]"))
            }
            for (presentation, mask) in activeMasks.enumerated() {
                try reader.skip(mask.nonzeroBitCount * 8, field: "nuActiveAssetMask[\(presentation)]")
            }
            guard try reader.read(1, field: "bMixMetadataEnbl") == 0 else {
                throw DTSError.unsupported("XLL-X extraction with ExSS mix metadata")
            }
        }
        guard presentationCount == 1, assetCount == 1 else {
            throw DTSError.unsupported("XLL-X extraction requires one ExSS presentation and asset")
        }
        let sizeBitCount = wide ? 20 : 16
        let assetByteCount = Int(try reader.read(sizeBitCount, field: "nuAssetFsize")) + 1
        guard headerByteCount + assetByteCount <= frameByteCount else {
            throw DTSError.malformed("ExSS asset exceeds its frame")
        }
        return exss.subdata(in: headerByteCount..<(headerByteCount + assetByteCount))
    }

    private static func parseXLLFrameByteCount(_ data: Data) throws -> Int {
        var reader = try BitReader(data: data)
        guard try reader.read(32, field: "SYNCXLL") == UInt64(xllSyncWord) else {
            throw DTSError.malformed("XLL sync word is missing from PBR buffer")
        }
        _ = try reader.read(4, field: "nVersion")
        _ = try reader.read(8, field: "nHeaderSize")
        let sizeBitCount = Int(try reader.read(5, field: "nBits4FrameFsize")) + 1
        let frameByteCount = Int(try reader.read(sizeBitCount, field: "nLLFrameSize")) + 1
        guard frameByteCount >= 8, frameByteCount <= maximumXLLFrameByteCount else {
            throw DTSError.valueOutOfRange(field: "XLL frame size", value: String(frameByteCount))
        }
        return frameByteCount
    }

    private static func locatePrivateDataBoundary(in frame: Data) throws -> PrivateDataBoundary {
        let bytes = Array(frame)
        var reader = try BitReader(bytes: bytes)
        guard try reader.read(32, field: "SYNCXLL") == UInt64(xllSyncWord) else {
            throw DTSError.malformed("XLL sync word is missing")
        }
        let version = Int(try reader.read(4, field: "nVersion")) + 1
        guard version == 1 else { throw DTSError.unsupported("XLL syntax version \(version)") }
        let commonHeaderByteCount = Int(try reader.read(8, field: "nHeaderSize")) + 1
        let frameSizeBitCount = Int(try reader.read(5, field: "nBits4FrameFsize")) + 1
        let declaredFrameByteCount = Int(try reader.read(frameSizeBitCount, field: "nLLFrameSize")) + 1
        guard declaredFrameByteCount == frame.count else {
            throw DTSError.malformed("XLL frame size changed while locating private data")
        }
        let channelSetCount = Int(try reader.read(4, field: "nNumChSetsInFrame")) + 1
        let segmentCountLog2 = Int(try reader.read(4, field: "nSegmentsInFrame"))
        guard segmentCountLog2 <= 10 else {
            throw DTSError.valueOutOfRange(field: "nSegmentsInFrame", value: String(segmentCountLog2))
        }
        let segmentCount = 1 << segmentCountLog2
        let segmentSampleCount = 1 << Int(try reader.read(4, field: "nSmplInSeg"))
        let segmentSizeBitCount = Int(try reader.read(5, field: "nBits4SSize")) + 1
        _ = try reader.read(2, field: "nBandDataCRCEn")
        let scalableLSBs = try reader.read(1, field: "bScalableLSBs") == 1
        let channelMaskBitCount = Int(try reader.read(5, field: "nBits4ChMask")) + 1
        if scalableLSBs { _ = try reader.read(4, field: "nFixedLSBWidth") }

        guard commonHeaderByteCount >= 6, commonHeaderByteCount <= frame.count else {
            throw DTSError.malformed("XLL common-header size exceeds frame size")
        }
        try DTSCRC16.validate(bytes[4..<commonHeaderByteCount], component: "XLL common header")
        try reader.seek(to: commonHeaderByteCount * 8, field: "XLL common-header end")

        var frequencyBandCounts: [Int] = []
        var channelSets: [DTSXXLLChannelSetSummary] = []
        // All supplied DTS:X references advertise a one-to-one speaker asset
        // in the ExSS descriptor. Keep the previous hierarchy's channel count
        // so a non-primary set's embedded downmix matrix can be skipped before
        // reading its speaker mask (ETSI TS 102 114 clause 8.3.2).
        var lowerHierarchyChannelCount = 0
        frequencyBandCounts.reserveCapacity(channelSetCount)
        channelSets.reserveCapacity(channelSetCount)
        for channelSet in 0..<channelSetCount {
            let headerStart = reader.bitOffset >> 3
            let headerByteCount = Int(try reader.read(10, field: "nChSetHeaderSize[\(channelSet)]")) + 1
            let headerEnd = headerStart + headerByteCount
            guard headerByteCount >= 2, headerEnd <= frame.count else {
                throw DTSError.malformed("XLL channel-set header exceeds frame size")
            }
            try DTSCRC16.validate(bytes[headerStart..<headerEnd], component: "XLL channel-set header")
            let channelCount = Int(try reader.read(4, field: "nChSetLLChannel[\(channelSet)]")) + 1
            let residualChannelMask = try reader.read(
                channelCount,
                field: "nResidualChEncode[\(channelSet)]"
            )
            let bitDepth = Int(try reader.read(5, field: "nBitResolution[\(channelSet)]")) + 1
            let storageBitDepth = Int(try reader.read(5, field: "nBitWidth[\(channelSet)]")) + 1
            let frequencyIndex = Int(try reader.read(4, field: "sFreqIndex[\(channelSet)]"))
            let frequency = samplingFrequency(index: frequencyIndex)
            guard frequency <= 96_000 else {
                throw DTSError.unsupported("XLL-X boundary location above 96 kHz")
            }
            _ = try reader.read(2, field: "nFsInterpolate[\(channelSet)]")
            let replacementSet = try reader.read(2, field: "nReplacementSet[\(channelSet)]")
            if replacementSet != 0 {
                _ = try reader.read(1, field: "bActiveReplaceSet[\(channelSet)]")
            }
            let isPrimary = try reader.read(1, field: "bPrimaryChSet[\(channelSet)]") == 1
            let hasEmbeddedDownmix = try reader.read(
                1,
                field: "bDownmixCoeffCodeEmbedded[\(channelSet)]"
            ) == 1
            if hasEmbeddedDownmix {
                _ = try reader.read(1, field: "bDownmixEmbedded[\(channelSet)]")
                if isPrimary {
                    _ = try reader.read(3, field: "nLLDownmixType[\(channelSet)]")
                }
            }
            _ = try reader.read(1, field: "bHierChSet[\(channelSet)]")
            if hasEmbeddedDownmix {
                guard lowerHierarchyChannelCount > 0 else {
                    throw DTSError.malformed("primary XLL channel set has an unresolved downmix matrix")
                }
                let coefficientCount = (channelCount + 1) * lowerHierarchyChannelCount
                try reader.skip(
                    coefficientCount * 9,
                    field: "DownmixCoeffs[\(channelSet)]"
                )
            }
            let hasSpeakerMask = try reader.read(1, field: "bChMaskEnabled[\(channelSet)]") == 1
            let speakerMask = hasSpeakerMask
                ? try reader.read(channelMaskBitCount, field: "nChMask[\(channelSet)]")
                : nil
            channelSets.append(DTSXXLLChannelSetSummary(
                channelCount: channelCount,
                residualChannelMask: residualChannelMask,
                bitDepth: bitDepth,
                storageBitDepth: storageBitDepth,
                sampleRateIndex: frequencyIndex,
                isPrimary: isPrimary,
                speakerMask: speakerMask
            ))
            lowerHierarchyChannelCount += channelCount
            frequencyBandCounts.append(1)
            try reader.seek(to: headerEnd * 8, field: "XLL channel-set-header end")
        }

        let maximumFrequencyBandCount = frequencyBandCounts.max() ?? 0
        guard maximumFrequencyBandCount > 0 else {
            throw DTSError.malformed("XLL frame has no frequency bands")
        }
        let navigationStart = reader.bitOffset >> 3
        var bandDataByteCount = 0
        for band in 0..<maximumFrequencyBandCount {
            for segment in 0..<segmentCount {
                for channelSet in 0..<channelSetCount where frequencyBandCounts[channelSet] > band {
                    let encodedSize = Int(try reader.read(
                        segmentSizeBitCount,
                        field: "NAVI[\(band)][\(segment)][\(channelSet)]"
                    ))
                    guard encodedSize < frame.count else {
                        throw DTSError.valueOutOfRange(field: "XLL NAVI segment size", value: String(encodedSize))
                    }
                    bandDataByteCount += encodedSize + 1
                }
            }
        }
        try reader.alignToByte(field: "XLL NAVI alignment")
        try reader.skip(16, field: "XLL NAVI CRC16")
        let navigationEnd = reader.bitOffset >> 3
        try DTSCRC16.validate(bytes[navigationStart..<navigationEnd], component: "XLL NAVI")

        let bandDataEnd = navigationEnd + bandDataByteCount
        guard bandDataEnd <= frame.count else {
            throw DTSError.malformed("XLL band data exceeds frame size")
        }
        let alignedOffset = (bandDataEnd + 3) & ~3
        guard alignedOffset <= frame.count else {
            throw DTSError.malformed("XLL private-data alignment exceeds frame size")
        }
        guard alignedOffset + 4 <= frame.count else {
            return PrivateDataBoundary(
                bandDataEndByteOffset: bandDataEnd,
                alignedByteOffset: alignedOffset,
                marker: nil,
                xllSyntax: DTSXXLLFrameSyntaxSummary(
                    commonHeaderByteCount: commonHeaderByteCount,
                    frameSizeBitCount: frameSizeBitCount,
                    segmentCount: segmentCount,
                    segmentSampleCount: segmentSampleCount,
                    segmentSizeBitCount: segmentSizeBitCount,
                    channelMaskBitCount: channelMaskBitCount,
                    channelSets: channelSets
                )
            )
        }

        let word = bigEndianUInt32(frame, at: alignedOffset)
        let marker: DTSXPrivateMarkerCandidate?
        if word == xllXSyncWord {
            marker = DTSXPrivateMarkerCandidate(byteOffset: alignedOffset, kind: .xllX, rawWord: word)
        } else if (word >> 1) == (xllXIMAXSyncWord >> 1) {
            marker = DTSXPrivateMarkerCandidate(byteOffset: alignedOffset, kind: .xllXIMAX, rawWord: word)
        } else {
            marker = nil
        }
        return PrivateDataBoundary(
            bandDataEndByteOffset: bandDataEnd,
            alignedByteOffset: alignedOffset,
            marker: marker,
            xllSyntax: DTSXXLLFrameSyntaxSummary(
                commonHeaderByteCount: commonHeaderByteCount,
                frameSizeBitCount: frameSizeBitCount,
                segmentCount: segmentCount,
                segmentSampleCount: segmentSampleCount,
                segmentSizeBitCount: segmentSizeBitCount,
                channelMaskBitCount: channelMaskBitCount,
                channelSets: channelSets
            )
        )
    }

    private static func samplingFrequency(index: Int) -> Int {
        let frequencies = [
            8_000, 16_000, 32_000, 64_000, 128_000, 22_050, 44_100, 88_200,
            176_400, 352_800, 12_000, 24_000, 48_000, 96_000, 192_000, 384_000
        ]
        return frequencies[index]
    }

    private static func findXLLSync(in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        for offset in 0...(data.count - 4) {
            if bigEndianUInt32(data, at: offset) == xllSyncWord { return offset }
        }
        return nil
    }

    private static func consume(
        _ byteCount: Int,
        from data: inout Data,
        spans: inout [PendingSpan]
    ) -> (start: Int, end: Int) {
        precondition(byteCount > 0 && byteCount <= data.count && !spans.isEmpty)
        let start = spans[0].accessUnit
        var remaining = byteCount
        var end = start
        while remaining > 0 {
            end = spans[0].accessUnit
            if remaining < spans[0].byteCount {
                spans[0].byteCount -= remaining
                remaining = 0
            } else {
                remaining -= spans[0].byteCount
                spans.removeFirst()
            }
        }
        data.removeSubrange(0..<byteCount)
        return (start, end)
    }

    private static func readExactly(
        handle: FileHandle,
        offset: UInt64,
        count: Int,
        field: String
    ) throws -> Data {
        do { try handle.seek(toOffset: offset) }
        catch { throw DTSError.io("cannot seek while reading \(field): \(error.localizedDescription)") }
        let data: Data
        do { data = try handle.read(upToCount: count) ?? Data() }
        catch { throw DTSError.io("cannot read \(field): \(error.localizedDescription)") }
        guard data.count == count else {
            throw DTSError.truncated(field: field, bitOffset: Int(offset) * 8 + data.count * 8)
        }
        return data
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let number = attributes[.size] as? NSNumber else {
                throw DTSError.io("file size is unavailable for \(url.path)")
            }
            return number.uint64Value
        } catch let error as DTSError {
            throw error
        } catch {
            throw DTSError.io("cannot inspect \(url.path): \(error.localizedDescription)")
        }
    }

    private static func filesAreByteIdentical(_ lhs: URL, _ rhs: URL) throws -> Bool {
        guard try fileSize(lhs) == fileSize(rhs) else { return false }
        let lhsHandle: FileHandle
        let rhsHandle: FileHandle
        do {
            lhsHandle = try FileHandle(forReadingFrom: lhs)
            rhsHandle = try FileHandle(forReadingFrom: rhs)
        } catch {
            throw DTSError.io("cannot open DTS:X comparison streams: \(error.localizedDescription)")
        }
        defer {
            try? lhsHandle.close()
            try? rhsHandle.close()
        }
        while true {
            let lhsChunk: Data
            let rhsChunk: Data
            do {
                lhsChunk = try lhsHandle.read(upToCount: 1 << 20) ?? Data()
                rhsChunk = try rhsHandle.read(upToCount: 1 << 20) ?? Data()
            } catch {
                throw DTSError.io("cannot compare DTS:X streams: \(error.localizedDescription)")
            }
            guard lhsChunk == rhsChunk else { return false }
            if lhsChunk.isEmpty { return true }
        }
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
