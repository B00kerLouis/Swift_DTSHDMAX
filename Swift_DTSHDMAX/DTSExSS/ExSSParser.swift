import Foundation

struct ExSSParser: Sendable {
    func parse(frame data: Data) throws -> ExSSParsedFrame {
        let bytes = Array(data)
        var reader = try BitReader(bytes: bytes)
        guard try reader.read(32, field: "SYNCEXTSSH") == ExSSSyntax.syncWord else {
            throw DTSError.malformed("ExSS sync word is missing")
        }
        _ = try reader.read(8, field: "UserDefinedBits")
        let exssIndex = Int(try reader.read(2, field: "nExtSSIndex"))
        let wideHeader = try reader.read(1, field: "bHeaderSizeType") == 1
        guard exssIndex == 0, !wideHeader else {
            throw DTSError.unsupported("ExSS index/long-header profile")
        }
        let headerByteCount = Int(try reader.read(8, field: "nuExtSSHeaderSize")) + 1
        let frameByteCount = Int(try reader.read(16, field: "nuExtSSFsize")) + 1
        guard headerByteCount <= frameByteCount, frameByteCount <= data.count else {
            throw DTSError.truncated(field: "ExSS frame", bitOffset: 0)
        }
        try DTSCRC16.validate(bytes[5..<headerByteCount], component: "ExSS header")

        guard try reader.read(1, field: "bStaticFieldsPresent") == 1 else {
            throw DTSError.unsupported("ExSS frames without repeated static metadata")
        }
        guard try reader.read(2, field: "nuRefClockCode") == 2,
              try reader.read(3, field: "nuExSSFrameDurationCode") == 0,
              try reader.read(1, field: "bTimeStampFlag") == 0 else {
            throw DTSError.unsupported("ExSS clock/timestamp configuration")
        }
        let presentationCount = Int(try reader.read(3, field: "nuNumAudioPresnt")) + 1
        let assetCount = Int(try reader.read(3, field: "nuNumAssets")) + 1
        guard presentationCount == 1, assetCount == 1 else {
            throw DTSError.unsupported("multiple ExSS presentations/assets")
        }
        guard try reader.read(1, field: "nuActiveExSSMask") == 1,
              try reader.read(8, field: "nuActiveAssetMask") == 1 else {
            throw DTSError.unsupported("ExSS presentation/mixing metadata")
        }
        let mixMetadataEnabled = try reader.read(1, field: "bMixMetadataEnbl") == 1
        let assetByteCount = Int(try reader.read(16, field: "nuAssetFsize")) + 1

        let descriptorStart = reader.bitOffset
        let descriptorByteCount = Int(try reader.read(9, field: "nuAssetDescriptFsize")) + 1
        let descriptorEnd = descriptorStart + descriptorByteCount * 8
        guard descriptorEnd <= headerByteCount * 8 else {
            throw DTSError.malformed("ExSS asset descriptor exceeds header")
        }
        guard try reader.read(3, field: "nuAssetIndex") == 0 else { throw DTSError.unsupported("ExSS asset index") }
        let hasAssetType = try reader.read(1, field: "bAssetTypeDescrPresent") == 1
        if hasAssetType, try reader.read(4, field: "nuAssetType") != 13 { throw DTSError.unsupported("ExSS optional asset type") }
        guard
              try reader.read(1, field: "bLanguageDescrPresent") == 0,
              try reader.read(1, field: "bInfoTextPresent") == 0 else {
            throw DTSError.unsupported("ExSS optional asset descriptors")
        }
        let bitDepth = Int(try reader.read(5, field: "nuBitResolution")) + 1
        let sampleRateIndex = Int(try reader.read(4, field: "nuMaxSampleRate"))
        let channelCount = Int(try reader.read(8, field: "nuTotalNumChs")) + 1
        guard bitDepth == 24, sampleRateIndex == XLLSyntax.samplingFrequencyIndex48k else {
            throw DTSError.unsupported("ExSS asset is outside 48 kHz/24-bit profile")
        }
        guard try reader.read(1, field: "bOne2OneMapChannels2Speakers") == 1 else {
            throw DTSError.unsupported("non-speaker-mapped ExSS assets")
        }
        let embeddedStereo: Bool
        if channelCount > 2 {
            // A compliant 7.1 asset may carry the backward-compatible
            // embedded-stereo indicator. It describes the asset's legacy
            // presentation and does not change the XLL channel map used for
            // lossless reconstruction.
            embeddedStereo = try reader.read(1, field: "bEmbeddedStereoFlag") == 1
        } else {
            embeddedStereo = false
        }
        if channelCount > 6 {
            // The same applies to the embedded-six-channel indicator on a
            // native 7.1 HDMA asset. Keep parsing the declared speaker mask;
            // the XLL payload remains the authoritative lossless map.
            _ = try reader.read(1, field: "bEmbeddedSixChFlag")
        }
        guard try reader.read(1, field: "bSpkrMaskEnabled") == 1 else {
            throw DTSError.unsupported("ExSS asset without speaker mask")
        }
        let speakerMaskBitCount = (Int(try reader.read(2, field: "nuBits4SpkrMask")) + 1) << 2
        let speakerPairMask = try reader.read(speakerMaskBitCount, field: "nuSpkrActivityMask")
        guard try reader.read(3, field: "nuNumSpkrRemapSets") == 0 else {
            throw DTSError.unsupported("ExSS speaker remapping sets")
        }
        let layout: DTSChannelLayout
        switch (channelCount, speakerPairMask) {
        case (2, UInt64(DTSChannelLayout.stereo.exssSpeakerPairMask)):
            layout = .stereo
        case (6, UInt64(DTSChannelLayout.fiveOneSide.exssSpeakerPairMask)):
            layout = .fiveOneSide
        case (8, UInt64(DTSChannelLayout.sevenOne.exssSpeakerPairMask)):
            layout = .sevenOne
        default:
            throw DTSError.unsupported("ExSS speaker pair mask 0x\(String(speakerPairMask, radix: 16))")
        }

        let drcPresent = try reader.read(1, field: "bDRCCoefPresent") == 1
        if drcPresent { _ = try reader.read(8, field: "nuDRCCode") }
        let dialNormPresent = try reader.read(1, field: "bDialNormPresent") == 1
        if dialNormPresent { _ = try reader.read(5, field: "nuDialNormCode") }
        if drcPresent && embeddedStereo {
            // The two-channel downmix DRC value is present only when the
            // embedded-stereo flag is set. The flag itself was consumed above.
            // The supplied 7.1 references leave this field absent.
            _ = try reader.read(8, field: "nuDRC2ChDmixCode")
        }
        guard !mixMetadataEnabled else {
            throw DTSError.unsupported("ExSS mix metadata")
        }

        let codingMode = Int(try reader.read(2, field: "nuCodingMode"))
        var xllByteCount: Int?
        var peakBitRateSmoothingBufferSizeCode = 0
        var xllInitialDecodingDelayBitCount = 0
        var xllInitialDecodingDelayFrames = 0
        var xllSyncByteOffset = 0
        switch codingMode {
        case 0:
            let coreExtensionMask = try reader.read(12, field: "nuCoreExtensionMask")
            // Navigation sizes for components preceding XLL. The native
            // decoder currently consumes Core separately, but must still walk
            // these fields to reach the XLL size in a valid mixed asset.
            if coreExtensionMask & 0x010 != 0 {
                _ = try reader.read(14, field: "nuExSSCoreFsize")
                let syncPresent = try reader.read(1, field: "bExSSCoreSyncPresent") == 1
                if syncPresent { _ = try reader.read(2, field: "nuExSSCoreSyncDistInFrames") }
            }
            if coreExtensionMask & 0x020 != 0 {
                _ = try reader.read(14, field: "nuExSSXBRFsize")
            }
            if coreExtensionMask & 0x040 != 0 {
                _ = try reader.read(14, field: "nuExSSXXCHFsize")
            }
            if coreExtensionMask & 0x080 != 0 {
                _ = try reader.read(12, field: "nuExSSX96Fsize")
            }
            if coreExtensionMask & 0x100 != 0 {
                _ = try reader.read(14, field: "nuExSSLBRFsize")
                let syncPresent = try reader.read(1, field: "bExSSLBRSyncPresent") == 1
                if syncPresent { _ = try reader.read(2, field: "nuExSSLBRSyncDistInFrames") }
            }
            guard coreExtensionMask & 0x200 != 0 else {
                throw DTSError.unsupported("ExSS asset has no XLL component")
            }
            xllByteCount = Int(try reader.read(16, field: "nuExSSXLLFsize")) + 1
            guard try reader.read(1, field: "bExSSXLLSyncPresent") == 1 else {
                throw DTSError.unsupported("XLL component without per-frame sync")
            }
            peakBitRateSmoothingBufferSizeCode = Int(
                try reader.read(4, field: "nuPeakBRCntrlBuffSzkB")
            )
            let delayBitCount = Int(try reader.read(5, field: "nuBitsInitDecDly")) + 1
            xllInitialDecodingDelayBitCount = delayBitCount
            xllInitialDecodingDelayFrames = Int(try reader.read(delayBitCount, field: "nuInitLLDecDlyFrames"))
            xllSyncByteOffset = Int(try reader.read(16, field: "nuExSSXLLSyncOffset"))
        case 1:
            xllByteCount = Int(try reader.read(16, field: "nuXLLFsize")) + 1
            guard try reader.read(1, field: "bXLLSyncPresent") == 1 else {
                throw DTSError.unsupported("XLL component without per-frame sync")
            }
            peakBitRateSmoothingBufferSizeCode = Int(
                try reader.read(4, field: "nuPeakBRSmoothingBufSize")
            )
            let delayBitCount = Int(try reader.read(5, field: "nuBits4XLLDelay")) + 1
            xllInitialDecodingDelayBitCount = delayBitCount
            xllInitialDecodingDelayFrames = Int(try reader.read(delayBitCount, field: "nuInitialXLLDecodingDelay"))
            xllSyncByteOffset = Int(try reader.read(16, field: "nuXLLSyncOffset"))
        default:
            throw DTSError.unsupported("ExSS coding mode \(codingMode) without XLL")
        }
        guard let xllByteCount else {
            throw DTSError.malformed("ExSS XLL component size is missing")
        }
        _ = try reader.read(3, field: "nuDTSHDStreamID")

        // Public decoder-navigation flags that precede the reserved asset-
        // descriptor extension.  The supported HDMA and DTS:X profiles keep
        // both disabled; Rev2 DRC would add frame-duration-dependent fields.
        guard try reader.read(1, field: "bDecodeAssetInSecondaryDecoder") == 0,
              try reader.read(1, field: "bDRCMetadataRev2Present") == 0 else {
            throw DTSError.unsupported("ExSS secondary-decoder/Rev2-DRC asset metadata")
        }

        let remainingDescriptorBitCount = descriptorEnd - reader.bitOffset
        guard remainingDescriptorBitCount >= 0 else {
            throw DTSError.malformed("ExSS asset descriptor ended before decoder navigation data")
        }
        let dtsxAssetDescriptorSignal: ExSSDTSXAssetDescriptorSignal?
        if remainingDescriptorBitCount == ExSSDTSXAssetDescriptorSignal.imaxEncodedBitCount, hasAssetType {
            guard try reader.read(5, field: "IMAX profile code") == 3 else { throw DTSError.malformed("IMAX profile code") }
            let offset = Int(try reader.read(16, field: "IMAX XLL-X offset"))
            guard try reader.read(40, field: "IMAX metadata declarations") == ExSSDTSXAssetDescriptorSignal.imaxSignature else {
                throw DTSError.malformed("IMAX metadata declarations")
            }
            let counts = try (0..<2).map { _ in Int(try reader.read(15, field: "IMAX chunk size")) + 1 }
            guard try reader.read(4, field: "IMAX descriptor padding") == 0 else { throw DTSError.malformed("IMAX descriptor padding") }
            dtsxAssetDescriptorSignal = try ExSSDTSXAssetDescriptorSignal(imaxOffset: offset, groupByteCounts: counts)
        } else if remainingDescriptorBitCount == ExSSDTSXAssetDescriptorSignal.encodedBitCount {
            let profileCode = Int(try reader.read(5, field: "nuDTSXProfileCode"))
            let xllXByteOffset = Int(try reader.read(16, field: "nuDTSXXLLXByteOffset"))
            let signature = try reader.read(24, field: "nuDTSXDescriptorSignature")
            let payloadNibbleCount = Int(
                try reader.read(16, field: "nuDTSXXLLXPayloadNibbleCount")
            )
            let zeroPadding = try reader.read(6, field: "DTSXDescriptorZeroPad")
            guard profileCode == ExSSDTSXAssetDescriptorSignal.profileCode,
                  signature == ExSSDTSXAssetDescriptorSignal.signature,
                  zeroPadding == 0 else {
                throw DTSError.malformed(
                    "ExSS DTS:X asset-descriptor signal does not match the qualified profile"
                )
            }
            dtsxAssetDescriptorSignal = try ExSSDTSXAssetDescriptorSignal(
                xllXByteOffset: xllXByteOffset,
                xllXPayloadNibbleCount: payloadNibbleCount
            )
        } else {
            var reservedBitsAreZero = true
            for _ in 0..<remainingDescriptorBitCount {
                if try reader.read(1, field: "AssetDescriptorReserved") != 0 {
                    reservedBitsAreZero = false
                }
            }
            guard reservedBitsAreZero else {
                throw DTSError.unsupported(
                    "unrecognized ExSS asset-descriptor reserved extension"
                )
            }
            dtsxAssetDescriptorSignal = nil
        }
        guard reader.bitOffset == descriptorEnd else {
            throw DTSError.malformed("ExSS asset-descriptor size did not close")
        }
        let backwardCompatibleCorePresent = try reader.read(1, field: "bBcCorePresent") == 1
        if backwardCompatibleCorePresent {
            guard try reader.read(2, field: "nuBcCoreExtSSIndex") == 0,
                  try reader.read(3, field: "nuBcCoreAssetIndex") == 0 else {
                throw DTSError.unsupported("backward-compatible Core association points outside asset 0")
            }
        }

        let xllByteOffset = headerByteCount
        guard assetByteCount == xllByteCount,
              xllByteOffset + xllByteCount <= frameByteCount else {
            throw DTSError.malformed("ExSS asset/XLL sizes do not close")
        }
        let xllData = data.subdata(in: xllByteOffset..<(xllByteOffset + xllByteCount))
        if let signal = dtsxAssetDescriptorSignal {
            guard signal.xllXByteOffset + signal.xllXFrameByteCount == xllData.count else {
                throw DTSError.malformed(
                    "ExSS DTS:X descriptor XLL-X offset/size does not close at the XLL frame boundary"
                )
            }
            let xll = try XLLFrameASTParser.parse(xllData)
            guard xll.privateDataByteRange.lowerBound == signal.xllXByteOffset,
                  xll.privateDataByteRange.count == signal.xllXFrameByteCount else {
                throw DTSError.malformed(
                    "ExSS DTS:X descriptor does not match the parsed XLL private-data range"
                )
            }
            if signal.isIMAX {
                let imax = try DTSIMAXPrivateFrame.parse(xll.privateData)
                guard imax.groups.map(\.chunkByteCount) == signal.imaxGroupByteCounts else {
                    throw DTSError.malformed("IMAX descriptor chunk sizes disagree with payload")
                }
            } else { _ = try DTSXPrivateFrameAST.parse(xll.privateData[...]) }
        }

        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: layout)
        let info = ExSSFrameInfo(
            byteCount: frameByteCount,
            headerByteCount: headerByteCount,
            assetDescriptorByteCount: descriptorByteCount,
            assetByteCount: assetByteCount,
            xllByteCount: xllByteCount,
            xllByteOffset: xllByteOffset,
            codingMode: codingMode,
            peakBitRateSmoothingBufferSizeCode: peakBitRateSmoothingBufferSizeCode,
            xllInitialDecodingDelayBitCount: xllInitialDecodingDelayBitCount,
            xllInitialDecodingDelayFrames: xllInitialDecodingDelayFrames,
            xllSyncByteOffset: xllSyncByteOffset,
            backwardCompatibleCorePresent: backwardCompatibleCorePresent,
            dtsxAssetDescriptorSignal: dtsxAssetDescriptorSignal,
            format: format
        )
        return ExSSParsedFrame(
            info: info,
            xllData: xllData
        )
    }
}
