import Foundation

struct ExSSWriter: Sendable {
    func wrap(
        xllFrame: XLLEncodedFrame,
        backwardCompatibleCore: Bool = false,
        assetDescriptorProfile: ExSSAssetDescriptorProfile = .standardHDMA
    ) throws -> Data {
        let dtsxSignal: ExSSDTSXAssetDescriptorSignal?
        switch assetDescriptorProfile {
        case .standardHDMA:
            dtsxSignal = nil
        case .dtsxXLLX:
            guard backwardCompatibleCore else {
                throw DTSError.invalidArgument(
                    "DTS:X ExSS asset descriptors require a backward-compatible Core"
                )
            }
            let xll = try XLLFrameASTParser.parse(xllFrame.data)
            guard !xll.privateData.isEmpty else {
                throw DTSError.malformed(
                    "DTS:X ExSS asset descriptor requires an aligned XLL-X private frame"
                )
            }
            _ = try DTSXPrivateFrameAST.parse(xll.privateData[...])
            dtsxSignal = try ExSSDTSXAssetDescriptorSignal(
                xllXByteOffset: xll.privateDataByteRange.lowerBound,
                xllXFrameByteCount: xll.privateDataByteRange.count
            )
        case .dtsxFixedChannels:
            guard backwardCompatibleCore else { throw DTSError.invalidArgument("Fixed speaker DTS:X requires compatible Core") }
            let xll = try XLLFrameASTParser.parse(xllFrame.data)
            let fixed = try DTSXFixedPrivateFrame.parse(xll.privateData,segmentCount: xll.segmentCount,publicNavigationWidth: xll.segmentSizeBitCount)
            dtsxSignal = try ExSSDTSXAssetDescriptorSignal(fixedOffset: xll.privateDataByteRange.lowerBound,
                metadataByteCount: fixed.format.metadata.count,groupByteCount: fixed.groupByteCount)
        case .dtsxIMAX:
            guard backwardCompatibleCore else { throw DTSError.invalidArgument("IMAX requires compatible Core") }
            let xll = try XLLFrameASTParser.parse(xllFrame.data)
            let imax = try DTSIMAXPrivateFrame.parse(xll.privateData)
            dtsxSignal = try ExSSDTSXAssetDescriptorSignal(
                imaxOffset: xll.privateDataByteRange.lowerBound,
                groupByteCounts: imax.groups.map(\.chunkByteCount)
            )
        case .dtsxDynamic:
            guard backwardCompatibleCore else { throw DTSError.invalidArgument("Dynamic objects require compatible Core") }
            let xll = try XLLFrameASTParser.parse(xllFrame.data)
            let objects = try DTSXDynamicPrivateFrame.parse(xll.privateData)
            dtsxSignal = try ExSSDTSXAssetDescriptorSignal(
                imaxOffset: xll.privateDataByteRange.lowerBound,
                groupByteCounts: objects.groups.map(\.chunkByteCount),
                metadataByteCounts: objects.metadata.chunkByteCounts
            )
        }
        let format = xllFrame.info.format
        let assetDescriptor = try encodeAssetDescriptor(
            format: format,
            xllByteCount: xllFrame.data.count,
            backwardCompatibleCore: backwardCompatibleCore,
            dtsxSignal: dtsxSignal
        )

        var writer = BitWriter()
        try writer.write(ExSSSyntax.syncWord, bitCount: 32, field: "SYNCEXTSSH")
        try writer.write(0, bitCount: 8, field: "UserDefinedBits")
        try writer.write(0, bitCount: 2, field: "nExtSSIndex")
        try writer.write(0, bitCount: 1, field: "bHeaderSizeType")
        let headerSizeOffset = writer.bitCount
        try writer.write(0, bitCount: 8, field: "nuExtSSHeaderSizeMinus1")
        let frameSizeOffset = writer.bitCount
        try writer.write(0, bitCount: 16, field: "nuExtSSFsizeMinus1")
        try writer.write(1, bitCount: 1, field: "bStaticFieldsPresent")
        try writer.write(2, bitCount: 2, field: "nuRefClockCode") // 1/48000 s
        try writer.write(0, bitCount: 3, field: "nuExSSFrameDurationCodeMinus1") // 512 clocks
        try writer.write(0, bitCount: 1, field: "bTimeStampFlag")
        try writer.write(0, bitCount: 3, field: "nuNumAudioPresntMinus1")
        try writer.write(0, bitCount: 3, field: "nuNumAssetsMinus1")
        try writer.write(1, bitCount: 1, field: "nuActiveExSSMask")
        try writer.write(1, bitCount: 8, field: "nuActiveAssetMask")
        try writer.write(0, bitCount: 1, field: "bMixMetadataEnbl")
        try writer.write(
            UInt64(xllFrame.data.count - 1),
            bitCount: ExSSSyntax.shortFrameSizeBitCount,
            field: "nuAssetFsizeMinus1"
        )
        try writer.write(bytes: assetDescriptor, field: "AssetDescriptor")
        try writer.write(backwardCompatibleCore ? 1 : 0, bitCount: 1, field: "bBcCorePresent")
        if backwardCompatibleCore {
            try writer.write(0, bitCount: 2, field: "nuBcCoreExtSSIndex")
            try writer.write(0, bitCount: 3, field: "nuBcCoreAssetIndex")
        }
        writer.alignToByte()
        // Ordinary Core+XLL HDMA references use a 36-byte header and a
        // 16-byte asset descriptor. DTS:X uses its qualified 23-byte
        // descriptor signal above and naturally closes as a 40-byte header.
        if backwardCompatibleCore, assetDescriptorProfile == .standardHDMA {
            while writer.byteCount + 2 < 36 {
                try writer.write(0, bitCount: 8, field: "ReservedCompatibilityPadding")
            }
        }
        while (writer.byteCount + 2) % 4 != 0 {
            try writer.write(0, bitCount: 8, field: "Reserved")
        }

        let headerByteCount = writer.byteCount + 2
        let frameByteCount = headerByteCount + xllFrame.data.count
        guard headerByteCount <= 256, frameByteCount <= 65_536 else {
            throw DTSError.valueOutOfRange(
                field: "ExSS short header/frame size",
                value: "header=\(headerByteCount), frame=\(frameByteCount)"
            )
        }
        try writer.patch(
            at: headerSizeOffset,
            value: UInt64(headerByteCount - 1),
            bitCount: 8,
            field: "nuExtSSHeaderSizeMinus1"
        )
        try writer.patch(
            at: frameSizeOffset,
            value: UInt64(frameByteCount - 1),
            bitCount: 16,
            field: "nuExtSSFsizeMinus1"
        )
        try DTSCRC16.appendChecksum(to: &writer, protectedByteOffset: 5, component: "ExSS header")
        guard writer.byteCount == headerByteCount, headerByteCount.isMultiple(of: 4) else {
            throw DTSError.malformed("ExSS header size/alignment did not close")
        }
        switch assetDescriptorProfile {
        case .standardHDMA:
            if backwardCompatibleCore, headerByteCount != 36 {
                throw DTSError.malformed("ordinary Core+XLL ExSS header is not 36 bytes")
            }
        case .dtsxFixedChannels:
            let expectedDescriptorBytes = format.layout == .sevenOne ? 23 : 21
            guard assetDescriptor.count == expectedDescriptorBytes, headerByteCount == 40 else {
                throw DTSError.malformed("Fixed speaker ExSS header dimensions are invalid: descriptor=\(assetDescriptor.count), header=\(headerByteCount)")
            }
        case .dtsxXLLX:
            guard assetDescriptor.count == 23, headerByteCount == 40 else {
                throw DTSError.malformed(
                    "DTS:X ExSS header must use a 23-byte descriptor and total 40 bytes"
                )
            }
        case .dtsxIMAX:
            guard headerByteCount == 44 else { throw DTSError.malformed("IMAX ExSS header is not 44 bytes") }
        case .dtsxDynamic:
            guard headerByteCount == 44 else { throw DTSError.malformed("Object ExSS header size is invalid") }
        }
        try writer.write(bytes: xllFrame.data, field: "XLL asset")
        guard writer.byteCount == frameByteCount, frameByteCount.isMultiple(of: 4) else {
            throw DTSError.malformed("ExSS frame size/alignment did not close")
        }
        return writer.data()
    }

    private func encodeAssetDescriptor(
        format: PCMFormat,
        xllByteCount: Int,
        backwardCompatibleCore: Bool,
        dtsxSignal: ExSSDTSXAssetDescriptorSignal?
    ) throws -> Data {
        var writer = BitWriter()
        let descriptorSizeOffset = writer.bitCount
        try writer.write(0, bitCount: 9, field: "nuAssetDescriptFsizeMinus1")
        try writer.write(0, bitCount: 3, field: "nuAssetIndex")
        try writer.write(dtsxSignal?.hasAlternateAudioGroups == true ? 1 : 0, bitCount: 1, field: "bAssetTypeDescrPresent")
        if dtsxSignal?.hasAlternateAudioGroups == true { try writer.write(13, bitCount: 4, field: "Alternate DTS:X asset type") }
        try writer.write(0, bitCount: 1, field: "bLanguageDescrPresent")
        try writer.write(0, bitCount: 1, field: "bInfoTextPresent")
        try writer.write(23, bitCount: 5, field: "nuBitResolutionMinus1")
        try writer.write(UInt64(XLLSyntax.samplingFrequencyIndex48k), bitCount: 4, field: "nuMaxSampleRate")
        try writer.write(UInt64(format.layout.channelCount - 1), bitCount: 8, field: "nuTotalNumChsMinus1")
        try writer.write(1, bitCount: 1, field: "bOne2OneMapChannels2Speakers")
        if format.layout.channelCount > 2 {
            try writer.write(0, bitCount: 1, field: "bEmbeddedStereoFlag")
        }
        if format.layout.channelCount > 6 {
            try writer.write(
                backwardCompatibleCore ? 1 : 0,
                bitCount: 1,
                field: "bEmbeddedSixChFlag"
            )
        }
        try writer.write(1, bitCount: 1, field: "bSpkrMaskEnabled")
        let speakerMaskBitCount = format.layout.channelCount > 6 ? 12 : dtsxSignal?.fixedMetadataByteCount != nil ? 4 : 8
        try writer.write(
            UInt64(speakerMaskBitCount / 4 - 1),
            bitCount: 2,
            field: "nuBits4SpkrMaskMinus1Quads"
        )
        try writer.write(
            UInt64(format.layout.exssSpeakerPairMask),
            bitCount: speakerMaskBitCount,
            field: "nuSpkrActivityMask"
        )
        try writer.write(0, bitCount: 3, field: "nuNumSpkrRemapSets")

        try writer.write(0, bitCount: 1, field: "bDRCCoefPresent")
        try writer.write(0, bitCount: 1, field: "bDialNormPresent")
        if backwardCompatibleCore {
            try writer.write(0, bitCount: 2, field: "nuCodingMode")
            try writer.write(0x201, bitCount: 12, field: "nuCoreExtensionMask")
            try writer.write(
                UInt64(xllByteCount - 1),
                bitCount: ExSSSyntax.shortFrameSizeBitCount,
                field: "nuExSSXLLFsizeMinus1"
            )
            try writer.write(1, bitCount: 1, field: "bExSSXLLSyncPresent")
            try writer.write(0, bitCount: 4, field: "nuPeakBRCntrlBuffSzkB")
            try writer.write(0, bitCount: 5, field: "nuBitsInitDecDlyMinus1")
            try writer.write(0, bitCount: 1, field: "nuInitLLDecDlyFrames")
            try writer.write(
                0,
                bitCount: ExSSSyntax.shortFrameSizeBitCount,
                field: "nuExSSXLLSyncOffset"
            )
        } else {
            try writer.write(1, bitCount: 2, field: "nuCodingMode")
            try writer.write(
                UInt64(xllByteCount - 1),
                bitCount: ExSSSyntax.shortFrameSizeBitCount,
                field: "nuXLLFsizeMinus1"
            )
            try writer.write(1, bitCount: 1, field: "bXLLSyncPresent")
            try writer.write(0, bitCount: 4, field: "nuPeakBRSmoothingBufSize")
            try writer.write(0, bitCount: 5, field: "nuBits4XLLDelayMinus1")
            try writer.write(0, bitCount: 1, field: "nuInitialXLLDecodingDelay")
            try writer.write(
                0,
                bitCount: ExSSSyntax.shortFrameSizeBitCount,
                field: "nuXLLSyncOffset"
            )
        }
        try writer.write(0, bitCount: 3, field: "nuDTSHDStreamID")
        try writer.write(0, bitCount: 1, field: "bDecodeAssetInSecondaryDecoder")
        try writer.write(0, bitCount: 1, field: "bDRCMetadataRev2Present")
        if let signal = dtsxSignal {
            try writer.write(
                UInt64(ExSSDTSXAssetDescriptorSignal.profileCode),
                bitCount: 5,
                field: "nuDTSXProfileCode"
            )
            try writer.write(
                UInt64(signal.xllXByteOffset),
                bitCount: 16,
                field: "nuDTSXXLLXByteOffset"
            )
            if let counts = signal.alternateGroupByteCounts {
                let metadata = signal.alternateMetadataByteCounts ?? [20,23]
                // Metadata NAVI: count-minus-one, eight-bit size coding, then
                // byte counts excluding each element's two-byte identifier.
                // Audio chunk declarations retain the observed type/width 0x44.
                try writer.write(UInt64(metadata.count-1), bitCount: 4, field: "Object metadata chunk count")
                try writer.write(1, bitCount: 4, field: "Object metadata size coding")
                for bytes in metadata { try writer.write(UInt64(bytes-2), bitCount: 8, field: "Object metadata chunk size") }
                for _ in counts { try writer.write(0x44, bitCount: 8, field: "Object audio chunk type/width") }
                for count in counts { try writer.write(UInt64(count - 1), bitCount: 15, field: "Alternate associated chunk size") }
                writer.alignToByte()
            } else if let metadata = signal.fixedMetadataByteCount, let group = signal.fixedAudioGroupByteCount {
                try writer.write(UInt64((metadata-4)<<8 | 0x45),bitCount: 24,field: "Fixed metadata/audio navigation")
                try writer.write(UInt64(group-1),bitCount: 15,field: "Fixed audio group byte count")
                writer.alignToByte()
            } else {
            try writer.write(
                ExSSDTSXAssetDescriptorSignal.signature,
                bitCount: 24,
                field: "nuDTSXDescriptorSignature"
            )
            try writer.write(
                UInt64(signal.xllXPayloadNibbleCount),
                bitCount: 16,
                field: "nuDTSXXLLXPayloadNibbleCount"
            )
            try writer.write(0, bitCount: 6, field: "DTSXDescriptorZeroPad")
            }
            guard writer.bitCount.isMultiple(of: 8) else {
                throw DTSError.malformed("DTS:X asset descriptor is not byte aligned")
            }
        } else {
            try writer.alignTo(byteMultiple: 4)
        }

        let descriptorByteCount = writer.byteCount
        if let signal = dtsxSignal, descriptorByteCount != (signal.hasAlternateAudioGroups ? 27 : signal.fixedMetadataByteCount != nil && format.layout != .sevenOne ? 21 : 23) {
            throw DTSError.malformed("DTS:X asset descriptor byte count does not match its navigation profile")
        }
        try writer.patch(
            at: descriptorSizeOffset,
            value: UInt64(descriptorByteCount - 1),
            bitCount: 9,
            field: "nuAssetDescriptFsizeMinus1"
        )
        return writer.data()
    }
}
