import Foundation

public struct DTSHDMADecoder: Sendable {
    public init() {}

    public func decode(_ stream: Data) throws -> PCMBuffer {
        try decodeInternal(DTSHDFileContainer.elementaryStream(in: stream))
    }

    /// Decodes only after validating the requested transport contract.
    public func decode(
        _ stream: Data,
        as expectedStreamKind: DTSHDMAStreamKind
    ) throws -> PCMBuffer {
        guard expectedStreamKind == .xllStandalone || expectedStreamKind == .dtsHDMA else {
            throw DTSError.invalidArgument(
                "strict DTS-HD decoder accepts XLL-Standalone or DTS HDMA only"
            )
        }
        _ = try DTSHDMAStreamStructureVerifier.verify(
            stream,
            expectedStreamKind: expectedStreamKind
        )
        return try decodeInternal(DTSHDFileContainer.elementaryStream(in: stream))
    }

    private func decodeInternal(_ stream: Data) throws -> PCMBuffer {
        guard !stream.isEmpty else { throw DTSError.malformed("DTS-HD stream is empty") }
        let exssParser = ExSSParser()
        let xllDecoder = XLLDecoder()
        var offset = 0
        var format: PCMFormat?
        var outputPlanes: [[Int32]] = []
        var hasBackwardCompatibleCore = false
        var coreDecoder = DTSCoreDecoder()

        while offset < stream.count {
            guard stream.count - offset >= 10 else {
                throw DTSError.truncated(field: "ExSS frame prefix", bitOffset: offset * 8)
            }
            var exssOffset = offset
            var decodedCore: PCMBuffer?
            if try stream.bigEndianUInt32(at: offset) == 0x7ffe_8001 {
                hasBackwardCompatibleCore = true
                var coreReader = try BitReader(data: stream, byteOffset: offset)
                _ = try coreReader.read(32, field: "DTS Core sync")
                _ = try coreReader.read(1, field: "FTYPE")
                _ = try coreReader.read(5, field: "SHORT")
                _ = try coreReader.read(1, field: "CPF")
                _ = try coreReader.read(7, field: "NBLKS")
                let coreByteCount = Int(try coreReader.read(14, field: "FSIZE")) + 1
                guard offset + coreByteCount <= stream.count else {
                    throw DTSError.truncated(field: "DTS Core frame", bitOffset: offset * 8)
                }
                decodedCore = try coreDecoder.decode(
                    frame: stream.subdata(in: offset..<(offset + coreByteCount))
                )
                exssOffset += (coreByteCount + 3) & ~3
                guard exssOffset + 10 <= stream.count else {
                    throw DTSError.truncated(field: "Core-compatible ExSS", bitOffset: exssOffset * 8)
                }
            }
            let remaining = stream.subdata(in: exssOffset..<stream.count)
            var sizeReader = try BitReader(data: remaining)
            guard try sizeReader.read(32, field: "SYNCEXTSSH") == ExSSSyntax.syncWord else {
                throw DTSError.malformed("expected ExSS sync at byte \(exssOffset)")
            }
            _ = try sizeReader.read(8, field: "UserDefinedBits")
            _ = try sizeReader.read(2, field: "nExtSSIndex")
            let wide = try sizeReader.read(1, field: "bHeaderSizeType") == 1
            _ = try sizeReader.read(wide ? 12 : 8, field: "nuExtSSHeaderSize")
            let frameByteCount = Int(try sizeReader.read(wide ? 20 : 16, field: "nuExtSSFsize")) + 1
            guard frameByteCount <= stream.count - exssOffset else {
                throw DTSError.truncated(field: "ExSS frame", bitOffset: exssOffset * 8)
            }
            let frameData = stream.subdata(in: exssOffset..<(exssOffset + frameByteCount))
            let exss = try exssParser.parse(frame: frameData)
            let xllPCM: PCMBuffer
            if exss.info.format.layout == .sevenOne, let decodedCore {
                let channelSets = try xllDecoder.decodeChannelSets(frame: exss.xllData)
                xllPCM = try XLLCoreReconstructor.reconstruct(channelSets, core: decodedCore)
            } else {
                xllPCM = try xllDecoder.decode(frame: exss.xllData).pcm
            }
            guard exss.info.format == xllPCM.format else {
                throw DTSError.malformed("ExSS and XLL audio formats disagree")
            }

            if let existing = format {
                guard existing == xllPCM.format else {
                    throw DTSError.unsupported("format changes between DTS-HD frames")
                }
            } else {
                format = xllPCM.format
                outputPlanes = Array(repeating: [], count: format!.layout.channelCount)
            }
            for channel in outputPlanes.indices {
                outputPlanes[channel].append(contentsOf: xllPCM.planes[channel])
            }
            offset = exssOffset + frameByteCount
        }

        guard let format else { throw DTSError.malformed("DTS-HD stream contains no frames") }
        if hasBackwardCompatibleCore {
            let trim = XLLSyntax.coreCompatiblePrimingSampleCount
            guard outputPlanes.allSatisfy({ $0.count >= trim }) else {
                throw DTSError.truncated(field: "Core-compatible XLL priming", bitOffset: 0)
            }
            outputPlanes = outputPlanes.map { Array($0.dropFirst(trim)) }
        }
        return try PCMBuffer(format: format, planes: outputPlanes)
    }
}
