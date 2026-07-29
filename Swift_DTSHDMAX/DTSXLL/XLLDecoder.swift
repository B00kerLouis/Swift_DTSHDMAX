import Foundation

struct XLLDecodedFrame: Sendable, Equatable {
    let pcm: PCMBuffer
    let info: XLLFrameInfo
}

public struct XLLDecodedChannelSet: Sendable, Equatable {
    public let index: Int
    public let speakerMask: UInt64
    public let residualChannelMask: UInt64
    public let pcmBitDepth: Int
    public let storageBitDepth: Int
    public let planes: [[Int32]]
    public let downmixCoefficientsPresent: Bool
    public let downmixEmbedded: Bool
    public let downmixScaleCodes: [Int]
    public let downmixCoefficientCodes: [Int]
    public let decorrelationEnabled: Bool
    public let originalOrder: [Int]
    public let decorrelationCoefficients: [Int32]
    public let adaptivePredictionOrders: [Int]
    public let fixedPredictionOrders: [Int]
    public let scalableLSBWidths: [Int]
    public let bitWidthAdjustments: [Int]

    public var sampleCount: Int { planes.first?.count ?? 0 }
}

public struct XLLDecodedChannelSetFrame: Sendable, Equatable {
    public let frameByteCount: Int
    public let sampleCount: Int
    public let fixedLSBWidth: Int
    public let hybridRiceParameterCount: Int
    public let hybridIsolatedSampleCount: Int
    public let channelSets: [XLLDecodedChannelSet]
}

enum XLLCoreReconstructor {
    private static let coreWaveToPrimaryOrder = [2, 0, 1, 3, 4, 5]
    private static let primaryAndSecondaryToWaveOrder = [1, 2, 0, 3, 6, 7, 4, 5]

    static func reconstruct(
        _ decoded: XLLDecodedChannelSetFrame,
        core: PCMBuffer
    ) throws -> PCMBuffer {
        guard core.format.sampleRate == 48_000,
              core.format.bitDepth == 24,
              core.format.layout == .fiveOneSide,
              core.sampleCount == decoded.sampleCount else {
            throw DTSError.invalidArgument(
                "XLL Core reconstruction requires one aligned 48 kHz/24-bit 5.1 Core frame"
            )
        }
        guard decoded.channelSets.count == 2,
              decoded.channelSets[0].planes.count == 6,
              decoded.channelSets[1].planes.count == 2 else {
            throw DTSError.unsupported("XLL Core reconstruction requires a 6+2 hierarchy")
        }

        let primary = decoded.channelSets[0]
        let secondary = decoded.channelSets[1]
        let scaleCodes = secondary.downmixEmbedded ? secondary.downmixScaleCodes : []
        let coefficientCodes = secondary.downmixEmbedded ? secondary.downmixCoefficientCodes : []
        guard scaleCodes.isEmpty || scaleCodes.count >= 6 else {
            throw DTSError.malformed("XLL hierarchical downmix scale matrix is incomplete")
        }
        guard coefficientCodes.isEmpty || coefficientCodes.count >= 12 else {
            throw DTSError.malformed("XLL hierarchical downmix coefficient matrix is incomplete")
        }
        let inverseScales = try scaleCodes.map(XLLSyntax.inverseDownmixScaleQ16)
        var undoCoefficients = Array(repeating: Int32(0), count: 12)
        if !coefficientCodes.isEmpty {
            for primaryChannel in 0..<6 {
                for secondaryChannel in 0..<2 {
                    let index = primaryChannel * 2 + secondaryChannel
                    undoCoefficients[index] = try XLLSyntax.undoDownmixCoefficientQ15(
                        scaleCode: scaleCodes[primaryChannel],
                        coefficientCode: coefficientCodes[index]
                    )
                }
            }
        }

        var output = Array(
            repeating: Array(repeating: Int32(0), count: decoded.sampleCount),
            count: 8
        )
        for sample in 0..<decoded.sampleCount {
            var hierarchical = Array(repeating: Int32(0), count: 8)
            for channel in 0..<6 {
                let xll = primary.planes[channel][sample]
                if primary.residualChannelMask & (UInt64(1) << UInt64(channel)) != 0 {
                    hierarchical[channel] = xll
                } else {
                    let coreValue = core.planes[coreWaveToPrimaryOrder[channel]][sample]
                    let scaledCore = inverseScales.isEmpty
                        ? Int64(coreValue)
                        : multiplyQ16(coreValue, inverseScales[channel])
                    let assemblyShift = try effectiveLSBWidth(
                        channelSet: primary,
                        channel: channel,
                        fixedLSBWidth: decoded.fixedLSBWidth
                    )
                    let coreShift = primary.storageBitDepth - primary.pcmBitDepth + assemblyShift
                    guard coreShift >= 0, coreShift <= primary.storageBitDepth else {
                        throw DTSError.malformed("XLL Core residual shift is outside storage precision")
                    }
                    let rounding = coreShift > 0 ? Int64(1) << Int64(coreShift - 1) : 0
                    let reducedCore = clip24((scaledCore + rounding) >> coreShift)
                    let assembledCore = Int32(
                        truncatingIfNeeded: Int64(reducedCore) << Int64(assemblyShift)
                    )
                    hierarchical[channel] = xll &+ assembledCore
                }
            }
            hierarchical[6] = secondary.planes[0][sample]
            hierarchical[7] = secondary.planes[1][sample]
            if !coefficientCodes.isEmpty {
                for primaryChannel in 0..<6 {
                    for secondaryChannel in 0..<2 {
                        let coefficient = undoCoefficients[primaryChannel * 2 + secondaryChannel]
                        if coefficient != 0 {
                            hierarchical[primaryChannel] = hierarchical[primaryChannel] &- multiplyQ15(
                                hierarchical[6 + secondaryChannel],
                                coefficient
                            )
                        }
                    }
                }
            }
            for channel in 0..<8 {
                output[channel][sample] = hierarchical[primaryAndSecondaryToWaveOrder[channel]]
            }
        }
        return try PCMBuffer(
            format: PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: .sevenOne),
            planes: output
        )
    }

    private static func effectiveLSBWidth(
        channelSet: XLLDecodedChannelSet,
        channel: Int,
        fixedLSBWidth: Int
    ) throws -> Int {
        guard channelSet.scalableLSBWidths.indices.contains(channel),
              channelSet.bitWidthAdjustments.indices.contains(channel) else {
            throw DTSError.malformed("XLL scalable-LSB channel metadata is incomplete")
        }
        if fixedLSBWidth > 0 { return fixedLSBWidth }
        let scalable = channelSet.scalableLSBWidths[channel]
        let adjustment = channelSet.bitWidthAdjustments[channel]
        return scalable > 0 && adjustment > 0
            ? scalable + adjustment - 1
            : scalable + adjustment
    }

    private static func multiplyQ16(_ first: Int32, _ second: Int32) -> Int64 {
        (Int64(first) * Int64(second) + 32_768) >> 16
    }

    private static func multiplyQ15(_ first: Int32, _ second: Int32) -> Int32 {
        Int32(truncatingIfNeeded: (Int64(first) * Int64(second) + 16_384) >> 15)
    }

    private static func clip24(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }
}

struct XLLDecoder: Sendable {
    func decode(frame data: Data) throws -> XLLDecodedFrame {
        let decoded = try decodeChannelSets(frame: data)
        guard !decoded.channelSets.isEmpty else {
            throw DTSError.malformed("XLL frame has no decoded channel sets")
        }
        let allChannels = decoded.channelSets.reduce(0) { $0 + $1.planes.count }
        let allFullChannels = decoded.channelSets.allSatisfy {
            $0.residualChannelMask == UInt64.lowBitMask(width: $0.planes.count)
        }
        guard allFullChannels else {
            throw DTSError.unsupported("core-residual XLL channels require a DTS Core decoder")
        }
        let speakerMask = decoded.channelSets.reduce(UInt64(0)) { $0 | $1.speakerMask }
        let layout = try DTSChannelLayout.fromXLL(channelCount: allChannels, speakerMask: speakerMask)
        var planesBySpeaker: [Int: [Int32]] = [:]
        for channelSet in decoded.channelSets {
            let speakers = channelSet.speakerMask.setBitIndices
            guard speakers.count == channelSet.planes.count else {
                throw DTSError.malformed("XLL speaker mask does not match decoded channel count")
            }
            for (speaker, plane) in zip(speakers, channelSet.planes) {
                guard planesBySpeaker.updateValue(plane, forKey: speaker) == nil else {
                    throw DTSError.malformed("XLL channel sets contain an overlapping speaker")
                }
            }
        }
        let dtsPlanes = speakerMask.setBitIndices.map { planesBySpeaker[$0]! }
        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: layout)
        let pcm = try PCMBuffer(
            format: format,
            planes: layout.dtsToWavePlaneOrder.map { dtsPlanes[$0] }
        )
        return XLLDecodedFrame(
            pcm: pcm,
            info: XLLFrameInfo(
                byteCount: decoded.frameByteCount,
                sampleCount: decoded.sampleCount,
                segmentCount: decoded.sampleCount / XLLSyntax.segmentSampleCount,
                segmentByteCounts: [],
                format: format,
                segmentationPlan: nil
            )
        )
    }

    func decodeChannelSets(frame data: Data) throws -> XLLDecodedChannelSetFrame {
        var parser = try XLLFrameDecoderParser(data: data)
        return try parser.decode()
    }
}

private struct XLLBandConfiguration {
    let decorrelationEnabled: Bool
    let originalOrder: [Int]
    let decorrelationCoefficients: [Int32]
    let adaptivePredictionOrders: [Int]
    let fixedPredictionOrders: [Int]
    let adaptiveReflectionCoefficients: [[Int32]]
    let lsbSectionByteCount: Int
    let scalableLSBWidths: [Int]
    let bitWidthAdjustments: [Int]
}

private struct XLLChannelSetConfiguration {
    let index: Int
    let channelCount: Int
    let residualChannelMask: UInt64
    let pcmBitDepth: Int
    let storageBitDepth: Int
    let speakerMask: UInt64
    let downmixCoefficientsPresent: Bool
    let downmixEmbedded: Bool
    let downmixScaleCodes: [Int]
    let downmixCoefficientCodes: [Int]
    let bitAllocationWidth: Int
    let band: XLLBandConfiguration
}

private struct XLLEntropyState {
    var commonParameters = false
    var riceCoding: [Bool]
    var hybridLinearWidths: [Int]
    var partABitAllocations: [Int]
    var partBBitAllocations: [Int]
    var partASampleCounts: [Int]

    init(channelCount: Int) {
        riceCoding = Array(repeating: false, count: channelCount)
        hybridLinearWidths = Array(repeating: 0, count: channelCount)
        partABitAllocations = Array(repeating: 0, count: channelCount)
        partBBitAllocations = Array(repeating: 0, count: channelCount)
        partASampleCounts = Array(repeating: 0, count: channelCount)
    }
}

private struct XLLFrameDecoderParser {
    let data: Data
    let bytes: [UInt8]
    var reader: BitReader
    var frameByteCount = 0
    var channelSetCount = 0
    var segmentCount = 0
    var segmentSampleCount = 0
    var segmentSampleCountLog2 = 0
    var segmentSizeBitCount = 0
    var bandCRCMode = 0
    var scalableLSBs = false
    var fixedLSBWidth = 0
    var hybridRiceParameterCount = 0
    var hybridIsolatedSampleCount = 0
    var channelMaskBitCount = 0

    init(data: Data) throws {
        self.data = data
        bytes = Array(data)
        reader = try BitReader(data: data)
    }

    mutating func decode() throws -> XLLDecodedChannelSetFrame {
        try parseCommonHeader()
        let channelSets = try parseChannelSetHeaders()
        let navigation = try parseNavigation(channelSets: channelSets)
        let planes = try decodeBandData(channelSets: channelSets, navigation: navigation)
        return XLLDecodedChannelSetFrame(
            frameByteCount: frameByteCount,
            sampleCount: segmentCount * segmentSampleCount,
            fixedLSBWidth: fixedLSBWidth,
            hybridRiceParameterCount: hybridRiceParameterCount,
            hybridIsolatedSampleCount: hybridIsolatedSampleCount,
            channelSets: zip(channelSets, planes).map { configuration, decodedPlanes in
                XLLDecodedChannelSet(
                    index: configuration.index,
                    speakerMask: configuration.speakerMask,
                    residualChannelMask: configuration.residualChannelMask,
                    pcmBitDepth: configuration.pcmBitDepth,
                    storageBitDepth: configuration.storageBitDepth,
                    planes: decodedPlanes,
                    downmixCoefficientsPresent: configuration.downmixCoefficientsPresent,
                    downmixEmbedded: configuration.downmixEmbedded,
                    downmixScaleCodes: configuration.downmixScaleCodes,
                    downmixCoefficientCodes: configuration.downmixCoefficientCodes,
                    decorrelationEnabled: configuration.band.decorrelationEnabled,
                    originalOrder: configuration.band.originalOrder,
                    decorrelationCoefficients: configuration.band.decorrelationCoefficients,
                    adaptivePredictionOrders: configuration.band.adaptivePredictionOrders,
                    fixedPredictionOrders: configuration.band.fixedPredictionOrders,
                    scalableLSBWidths: configuration.band.scalableLSBWidths,
                    bitWidthAdjustments: configuration.band.bitWidthAdjustments
                )
            }
        )
    }

    mutating func parseCommonHeader() throws {
        guard try reader.read(32, field: "SYNCXLL") == XLLSyntax.syncWord else {
            throw DTSError.malformed("XLL sync word is missing")
        }
        let version = Int(try reader.read(4, field: "nVersion")) + 1
        guard version == XLLSyntax.streamVersion else {
            throw DTSError.unsupported("XLL syntax version \(version)")
        }
        let commonHeaderByteCount = Int(try reader.read(8, field: "nHeaderSize")) + 1
        let frameSizeBitCount = Int(try reader.read(5, field: "nBits4FrameFsize")) + 1
        frameByteCount = Int(try reader.read(frameSizeBitCount, field: "nLLFrameSize")) + 1
        guard frameByteCount == data.count else {
            throw DTSError.malformed("XLL frame size does not equal supplied data")
        }
        channelSetCount = Int(try reader.read(4, field: "nNumChSetsInFrame")) + 1
        segmentCount = 1 << Int(try reader.read(4, field: "nSegmentsInFrame"))
        segmentSampleCountLog2 = Int(try reader.read(4, field: "nSmplInSeg"))
        segmentSampleCount = 1 << segmentSampleCountLog2
        segmentSizeBitCount = Int(try reader.read(5, field: "nBits4SSize")) + 1
        bandCRCMode = Int(try reader.read(2, field: "nBandDataCRCEn"))
        scalableLSBs = try reader.read(1, field: "bScalableLSBs") == 1
        channelMaskBitCount = Int(try reader.read(5, field: "nBits4ChMask")) + 1
        fixedLSBWidth = scalableLSBs ? Int(try reader.read(4, field: "nFixedLSBWidth")) : 0
        guard channelSetCount <= 3, segmentCount <= 1_024,
              segmentSampleCountLog2 > 0, segmentSampleCount <= 512 else {
            throw DTSError.unsupported("XLL common-header dimensions")
        }
        guard commonHeaderByteCount >= 6, commonHeaderByteCount <= frameByteCount else {
            throw DTSError.malformed("XLL common header exceeds frame")
        }
        try DTSCRC16.validate(bytes[4..<commonHeaderByteCount], component: "XLL common header")
        try reader.seek(to: commonHeaderByteCount * 8, field: "XLL common-header end")
    }

    mutating func parseChannelSetHeaders() throws -> [XLLChannelSetConfiguration] {
        var output: [XLLChannelSetConfiguration] = []
        output.reserveCapacity(channelSetCount)
        var lowerHierarchyChannelCount = 0
        for channelSetIndex in 0..<channelSetCount {
            let headerStart = reader.bitOffset / 8
            let headerByteCount = Int(try reader.read(10, field: "nChSetHeaderSize[\(channelSetIndex)]")) + 1
            let headerEnd = headerStart + headerByteCount
            guard headerEnd <= frameByteCount else {
                throw DTSError.malformed("XLL channel-set header exceeds frame")
            }
            try DTSCRC16.validate(bytes[headerStart..<headerEnd], component: "XLL channel-set header")
            let channelCount = Int(try reader.read(4, field: "nChSetLLChannel[\(channelSetIndex)]")) + 1
            guard channelCount <= 8 else { throw DTSError.unsupported("XLL channel-set channel count \(channelCount)") }
            let residualMask = try reader.read(channelCount, field: "nResidualChEncode[\(channelSetIndex)]")
            let pcmBitDepth = Int(try reader.read(5, field: "nBitResolution[\(channelSetIndex)]")) + 1
            let storageBitDepth = Int(try reader.read(5, field: "nBitWidth[\(channelSetIndex)]")) + 1
            let frequencyIndex = Int(try reader.read(4, field: "sFreqIndex[\(channelSetIndex)]"))
            let frequencyModifier = try reader.read(2, field: "nFsInterpolate[\(channelSetIndex)]")
            let replacementSet = try reader.read(2, field: "nReplacementSet[\(channelSetIndex)]")
            if replacementSet != 0 { _ = try reader.read(1, field: "bActiveReplaceSet[\(channelSetIndex)]") }
            guard pcmBitDepth <= storageBitDepth, storageBitDepth == 24,
                  frequencyIndex == XLLSyntax.samplingFrequencyIndex48k,
                  frequencyModifier == 0, replacementSet == 0 else {
                throw DTSError.unsupported("XLL channel-set audio characteristics")
            }
            let primary = try reader.read(1, field: "bPrimaryChSet[\(channelSetIndex)]") == 1
            guard primary == (channelSetIndex == 0) else {
                throw DTSError.malformed("XLL primary channel-set ordering is invalid")
            }
            let downmixCoefficientsPresent = try reader.read(1, field: "bDownmixCoeffCodeEmbedded[\(channelSetIndex)]") == 1
            var downmixEmbedded = false
            if downmixCoefficientsPresent {
                downmixEmbedded = try reader.read(1, field: "bDownmixEmbedded[\(channelSetIndex)]") == 1
                if primary { _ = try reader.read(3, field: "nLLDownmixType[\(channelSetIndex)]") }
            }
            let hierarchical = try reader.read(1, field: "bHierChSet[\(channelSetIndex)]") == 1
            guard hierarchical || channelSetCount == 1 else {
                throw DTSError.unsupported("XLL channel set outside hierarchy")
            }
            var downmixScaleCodes: [Int] = []
            var downmixCoefficientCodes: [Int] = []
            if downmixCoefficientsPresent {
                let downmixInputCount = primary ? 2 : lowerHierarchyChannelCount
                guard downmixInputCount > 0 else {
                    throw DTSError.malformed("XLL downmix matrix has no input channels")
                }
                for input in 0..<downmixInputCount {
                    if !primary {
                        downmixScaleCodes.append(Int(try reader.read(
                            9,
                            field: "DownmixScale[\(channelSetIndex)][\(input)]"
                        )))
                    }
                    for output in 0..<channelCount {
                        downmixCoefficientCodes.append(Int(try reader.read(
                            9,
                            field: "DownmixCoefficient[\(channelSetIndex)][\(input)][\(output)]"
                        )))
                    }
                }
            }
            guard try reader.read(1, field: "bChMaskEnabled[\(channelSetIndex)]") == 1 else {
                throw DTSError.unsupported("XLL channel mask is disabled")
            }
            let speakerMask = try reader.read(channelMaskBitCount, field: "nChMask[\(channelSetIndex)]")
            guard speakerMask.nonzeroBitCount == channelCount else {
                throw DTSError.malformed("XLL channel mask does not match channel count")
            }
            let bitAllocationWidth = storageBitDepth > 16 ? 5 : (storageBitDepth > 8 ? 4 : 3)
            let band = try parseBandConfiguration(
                channelSetIndex: channelSetIndex,
                channelCount: channelCount
            )
            try reader.seek(to: headerEnd * 8, field: "XLL channel-set-header end")
            output.append(XLLChannelSetConfiguration(
                index: channelSetIndex,
                channelCount: channelCount,
                residualChannelMask: residualMask,
                pcmBitDepth: pcmBitDepth,
                storageBitDepth: storageBitDepth,
                speakerMask: speakerMask,
                downmixCoefficientsPresent: downmixCoefficientsPresent,
                downmixEmbedded: downmixEmbedded,
                downmixScaleCodes: downmixScaleCodes,
                downmixCoefficientCodes: downmixCoefficientCodes,
                bitAllocationWidth: bitAllocationWidth,
                band: band
            ))
            lowerHierarchyChannelCount += channelCount
        }
        return output
    }

    mutating func parseBandConfiguration(
        channelSetIndex: Int,
        channelCount: Int
    ) throws -> XLLBandConfiguration {
        let decorrelationEnabled = try reader.read(1, field: "bPWChDecorEnabled[\(channelSetIndex)]") == 1
        var originalOrder = Array(0..<channelCount)
        var decorrelationCoefficients = Array(repeating: Int32(0), count: channelCount / 2)
        if decorrelationEnabled, channelCount > 1 {
            let orderBitCount = max(1, Int.ceilLog2(channelCount))
            for channel in 0..<channelCount {
                originalOrder[channel] = Int(try reader.read(
                    orderBitCount,
                    field: "nOrigChOrder[\(channelSetIndex)][\(channel)]"
                ))
            }
            guard Set(originalOrder) == Set(0..<channelCount) else {
                throw DTSError.malformed("XLL original channel order is not a permutation")
            }
            for pair in decorrelationCoefficients.indices {
                if try reader.read(1, field: "bPWChDecorrCoeff[\(channelSetIndex)][\(pair)]") == 1 {
                    decorrelationCoefficients[pair] = try readLinear(
                        width: 7,
                        field: "nPWChDecorrCoeff[\(channelSetIndex)][\(pair)]"
                    )
                }
            }
        }
        var adaptiveOrders: [Int] = []
        adaptiveOrders.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            adaptiveOrders.append(Int(try reader.read(4, field: "nAdaptPredOrder[\(channelSetIndex)][\(channel)]")))
        }
        guard adaptiveOrders.allSatisfy({ $0 <= segmentSampleCount }) else {
            throw DTSError.malformed("XLL adaptive prediction order exceeds segment size")
        }
        var fixedOrders = Array(repeating: 0, count: channelCount)
        for channel in 0..<channelCount where adaptiveOrders[channel] == 0 {
            fixedOrders[channel] = Int(try reader.read(2, field: "nFixedPredOrder[\(channelSetIndex)][\(channel)]"))
        }
        var reflectionCoefficients = Array(repeating: [Int32](), count: channelCount)
        for channel in 0..<channelCount {
            reflectionCoefficients[channel].reserveCapacity(adaptiveOrders[channel])
            for coefficient in 0..<adaptiveOrders[channel] {
                let index = try readLinear(
                    width: 8,
                    field: "nAdaptReflCoeff[\(channelSetIndex)][\(channel)][\(coefficient)]"
                )
                guard index != -128 else { throw DTSError.malformed("XLL reflection coefficient index is invalid") }
                let magnitude = Int(abs(index))
                let value = Int32(XLLSyntax.reflectionCoefficients[magnitude])
                reflectionCoefficients[channel].append(index < 0 ? -value : value)
            }
        }
        var lsbSectionByteCount = 0
        var lsbWidths = Array(repeating: 0, count: channelCount)
        var widthAdjustments = Array(repeating: 0, count: channelCount)
        if scalableLSBs {
            lsbSectionByteCount = Int(try reader.read(segmentSizeBitCount, field: "nLSBSectionSize[\(channelSetIndex)]"))
            if lsbSectionByteCount > 0, bandCRCMode > 1 { lsbSectionByteCount += 2 }
            for channel in 0..<channelCount {
                lsbWidths[channel] = Int(try reader.read(4, field: "nScalableLSBs[\(channelSetIndex)][\(channel)]"))
            }
            guard lsbSectionByteCount > 0 || lsbWidths.allSatisfy({ $0 == 0 }) else {
                throw DTSError.malformed("XLL scalable LSB width has no LSB section")
            }
            for channel in 0..<channelCount {
                widthAdjustments[channel] = Int(try reader.read(4, field: "nBitWidthAdj[\(channelSetIndex)][\(channel)]"))
            }
        }
        return XLLBandConfiguration(
            decorrelationEnabled: decorrelationEnabled,
            originalOrder: originalOrder,
            decorrelationCoefficients: decorrelationCoefficients,
            adaptivePredictionOrders: adaptiveOrders,
            fixedPredictionOrders: fixedOrders,
            adaptiveReflectionCoefficients: reflectionCoefficients,
            lsbSectionByteCount: lsbSectionByteCount,
            scalableLSBWidths: lsbWidths,
            bitWidthAdjustments: widthAdjustments
        )
    }

    mutating func parseNavigation(channelSets: [XLLChannelSetConfiguration]) throws -> [[Int]] {
        let navigationStart = reader.bitOffset / 8
        var result = Array(repeating: Array(repeating: 0, count: channelSets.count), count: segmentCount)
        for segment in 0..<segmentCount {
            for channelSet in channelSets.indices {
                result[segment][channelSet] = Int(try reader.read(
                    segmentSizeBitCount,
                    field: "NAVI[\(segment)][\(channelSet)]"
                )) + 1
            }
        }
        try reader.alignToByte(field: "XLL NAVI alignment")
        try reader.skip(16, field: "XLL NAVI CRC16")
        let navigationEnd = reader.bitOffset / 8
        try DTSCRC16.validate(bytes[navigationStart..<navigationEnd], component: "XLL NAVI")
        return result
    }

    mutating func decodeBandData(
        channelSets: [XLLChannelSetConfiguration],
        navigation: [[Int]]
    ) throws -> [[[Int32]]] {
        let sampleCount = segmentCount * segmentSampleCount
        var output = channelSets.map {
            Array(repeating: Array(repeating: Int32(0), count: sampleCount), count: $0.channelCount)
        }
        var lsbOutput = channelSets.map {
            Array(repeating: Array(repeating: Int32(0), count: sampleCount), count: $0.channelCount)
        }
        var entropyStates = channelSets.map { XLLEntropyState(channelCount: $0.channelCount) }
        for segment in 0..<segmentCount {
            for channelSetIndex in channelSets.indices {
                let segmentEnd = reader.bitOffset + navigation[segment][channelSetIndex] * 8
                guard segmentEnd <= frameByteCount * 8 else {
                    throw DTSError.truncated(field: "XLL band data", bitOffset: reader.bitOffset)
                }
                try decodeSegment(
                    configuration: channelSets[channelSetIndex],
                    segment: segment,
                    segmentEnd: segmentEnd,
                    state: &entropyStates[channelSetIndex],
                    msbPlanes: &output[channelSetIndex],
                    lsbPlanes: &lsbOutput[channelSetIndex]
                )
                try reader.seek(to: segmentEnd, field: "XLL band-data segment end")
            }
        }
        for channelSetIndex in channelSets.indices {
            inversePredictionAndDecorrelation(
                configuration: channelSets[channelSetIndex],
                planes: &output[channelSetIndex]
            )
            assembleScalableLSBs(
                configuration: channelSets[channelSetIndex],
                msbPlanes: &output[channelSetIndex],
                lsbPlanes: lsbOutput[channelSetIndex]
            )
        }
        return output
    }

    mutating func decodeSegment(
        configuration: XLLChannelSetConfiguration,
        segment: Int,
        segmentEnd: Int,
        state: inout XLLEntropyState,
        msbPlanes: inout [[Int32]],
        lsbPlanes: inout [[Int32]]
    ) throws {
        let reuseParameters = segment > 0
            ? try reader.read(1, field: "bUseSegStateCodeParm[\(configuration.index)][\(segment)]") == 1
            : false
        if !reuseParameters {
            state.commonParameters = try reader.read(1, field: "ncSegType[\(configuration.index)][\(segment)]") == 1
            let parameterCount = state.commonParameters ? 1 : configuration.channelCount
            for parameter in 0..<parameterCount {
                state.riceCoding[parameter] = try reader.read(
                    1,
                    field: "bRiceCodeFlag[\(configuration.index)][\(segment)][\(parameter)]"
                ) == 1
                if !state.commonParameters, state.riceCoding[parameter],
                   try reader.read(1, field: "bHybridRiceCode[\(configuration.index)][\(segment)][\(parameter)]") == 1 {
                    state.hybridLinearWidths[parameter] = Int(try reader.read(
                        configuration.bitAllocationWidth,
                        field: "nHybridLinearWidth[\(configuration.index)][\(segment)][\(parameter)]"
                    )) + 1
                    hybridRiceParameterCount += 1
                } else {
                    state.hybridLinearWidths[parameter] = 0
                }
            }
            for parameter in 0..<parameterCount {
                if segment == 0 {
                    var allocation = Int(try reader.read(
                        configuration.bitAllocationWidth,
                        field: "ABIT0[\(configuration.index)][\(parameter)]"
                    ))
                    if !state.riceCoding[parameter], allocation != 0 { allocation += 1 }
                    state.partABitAllocations[parameter] = allocation
                    state.partASampleCounts[parameter] = state.commonParameters
                        ? configuration.band.adaptivePredictionOrders.max() ?? 0
                        : configuration.band.adaptivePredictionOrders[parameter]
                } else {
                    state.partABitAllocations[parameter] = 0
                    state.partASampleCounts[parameter] = 0
                }
                var allocation = Int(try reader.read(
                    configuration.bitAllocationWidth,
                    field: "ABIT[\(configuration.index)][\(segment)][\(parameter)]"
                ))
                if !state.riceCoding[parameter], allocation != 0 { allocation += 1 }
                state.partBBitAllocations[parameter] = allocation
            }
        }
        let segmentOffset = segment * segmentSampleCount
        for channel in 0..<configuration.channelCount {
            let parameter = state.commonParameters ? 0 : channel
            let partASamples = state.partASampleCounts[parameter]
            let partBSamples = segmentSampleCount - partASamples
            guard partASamples >= 0, partBSamples >= 0 else {
                throw DTSError.malformed("XLL entropy partition exceeds segment")
            }
            if state.riceCoding[parameter] {
                for sample in 0..<partASamples {
                    msbPlanes[channel][segmentOffset + sample] = try readRice(
                        parameter: state.partABitAllocations[parameter],
                        limit: segmentEnd,
                        field: "XLL part A Rice sample"
                    )
                }
                if state.hybridLinearWidths[parameter] > 0 {
                    let isolatedCount = Int(try reader.read(segmentSampleCountLog2, field: "nIsolatedSamples"))
                    hybridIsolatedSampleCount += isolatedCount
                    var isolated = Set<Int>()
                    isolated.reserveCapacity(isolatedCount)
                    for _ in 0..<isolatedCount {
                        let location = Int(try reader.read(segmentSampleCountLog2, field: "nIsolatedSampleLocation"))
                        guard location < partBSamples else {
                            throw DTSError.malformed("XLL isolated sample location exceeds part B")
                        }
                        isolated.insert(location)
                    }
                    for sample in 0..<partBSamples {
                        msbPlanes[channel][segmentOffset + partASamples + sample] = isolated.contains(sample)
                            ? try readLinear(width: state.hybridLinearWidths[parameter], field: "XLL hybrid sample")
                            : try readRice(
                                parameter: state.partBBitAllocations[parameter],
                                limit: segmentEnd,
                                field: "XLL part B Rice sample"
                            )
                    }
                } else {
                    for sample in 0..<partBSamples {
                        msbPlanes[channel][segmentOffset + partASamples + sample] = try readRice(
                            parameter: state.partBBitAllocations[parameter],
                            limit: segmentEnd,
                            field: "XLL part B Rice sample"
                        )
                    }
                }
            } else {
                for sample in 0..<partASamples {
                    msbPlanes[channel][segmentOffset + sample] = try readLinear(
                        width: state.partABitAllocations[parameter],
                        field: "XLL part A linear sample"
                    )
                }
                for sample in 0..<partBSamples {
                    msbPlanes[channel][segmentOffset + partASamples + sample] = try readLinear(
                        width: state.partBBitAllocations[parameter],
                        field: "XLL part B linear sample"
                    )
                }
            }
        }
        let lsbSectionByteCount = configuration.band.lsbSectionByteCount
        if lsbSectionByteCount > 0 {
            let lsbStart = segmentEnd - lsbSectionByteCount * 8
            guard lsbStart >= reader.bitOffset else {
                throw DTSError.malformed("XLL MSB data overlaps scalable LSB section")
            }
            try reader.seek(to: lsbStart, field: "XLL scalable LSB section")
            for channel in 0..<configuration.channelCount {
                let width = configuration.band.scalableLSBWidths[channel]
                for sample in 0..<segmentSampleCount where width > 0 {
                    lsbPlanes[channel][segmentOffset + sample] = Int32(try reader.read(width, field: "XLL scalable LSB sample"))
                }
            }
        }
    }

    mutating func readLinear(width: Int, field: String) throws -> Int32 {
        guard width >= 0, width <= 32 else {
            throw DTSError.valueOutOfRange(field: "\(field).width", value: String(width))
        }
        if width == 0 { return 0 }
        let value = try reader.read(width, field: field)
        let magnitude = Int64(value >> 1)
        return Int32((value & 1) == 0 ? magnitude : -magnitude - 1)
    }

    mutating func readRice(parameter: Int, limit: Int, field: String) throws -> Int32 {
        guard parameter >= 0, parameter <= 31 else {
            throw DTSError.valueOutOfRange(field: "\(field).parameter", value: String(parameter))
        }
        let maximumQuotient = max(0, limit - reader.bitOffset - parameter - 1)
        let quotient = try reader.readUnary(maximumZeroBitCount: maximumQuotient, field: field)
        let remainder = parameter > 0 ? try reader.read(parameter, field: "\(field).remainder") : 0
        let mapped = (UInt64(quotient) << UInt64(parameter)) | remainder
        let magnitude = Int64(mapped >> 1)
        let value = (mapped & 1) == 0 ? magnitude : -magnitude - 1
        guard value >= Int64(Int32.min), value <= Int64(Int32.max) else {
            throw DTSError.valueOutOfRange(field: field, value: String(value))
        }
        return Int32(value)
    }

    func inversePredictionAndDecorrelation(
        configuration: XLLChannelSetConfiguration,
        planes: inout [[Int32]]
    ) {
        for channel in planes.indices {
            let adaptiveOrder = configuration.band.adaptivePredictionOrders[channel]
            if adaptiveOrder > 0 {
                let reflection = configuration.band.adaptiveReflectionCoefficients[channel]
                var direct = Array(repeating: Int32(0), count: adaptiveOrder)
                for index in 0..<adaptiveOrder {
                    let coefficient = reflection[index]
                    for pairIndex in 0..<((index + 1) / 2) {
                        let opposite = index - pairIndex - 1
                        let first = direct[pairIndex]
                        let second = direct[opposite]
                        direct[pairIndex] = first &+ multiplyQ16(coefficient, second)
                        direct[opposite] = second &+ multiplyQ16(coefficient, first)
                    }
                    direct[index] = coefficient
                }
                if planes[channel].count > adaptiveOrder {
                    for sample in 0..<(planes[channel].count - adaptiveOrder) {
                        var error: Int64 = 0
                        for coefficient in 0..<adaptiveOrder {
                            error += Int64(planes[channel][sample + coefficient])
                                * Int64(direct[adaptiveOrder - coefficient - 1])
                        }
                        let prediction = clip24(roundShift(error, by: 16))
                        planes[channel][sample + adaptiveOrder] = planes[channel][sample + adaptiveOrder] &- prediction
                    }
                }
            } else {
                for _ in 0..<configuration.band.fixedPredictionOrders[channel] {
                    for sample in 1..<planes[channel].count {
                        planes[channel][sample] = planes[channel][sample] &+ planes[channel][sample - 1]
                    }
                }
            }
        }
        if configuration.band.decorrelationEnabled {
            for pair in configuration.band.decorrelationCoefficients.indices {
                let coefficient = configuration.band.decorrelationCoefficients[pair]
                guard coefficient != 0 else { continue }
                let source = pair * 2
                let destination = source + 1
                for sample in planes[destination].indices {
                    let delta = Int32((Int64(planes[source][sample]) * Int64(coefficient) + 4) >> 3)
                    planes[destination][sample] = planes[destination][sample] &+ delta
                }
            }
            let codedPlanes = planes
            for codedChannel in codedPlanes.indices {
                planes[configuration.band.originalOrder[codedChannel]] = codedPlanes[codedChannel]
            }
        }
    }

    func assembleScalableLSBs(
        configuration: XLLChannelSetConfiguration,
        msbPlanes: inout [[Int32]],
        lsbPlanes: [[Int32]]
    ) {
        for channel in msbPlanes.indices {
            let scalableWidth = configuration.band.scalableLSBWidths[channel]
            let adjustment = configuration.band.bitWidthAdjustments[channel]
            let shift: Int
            if fixedLSBWidth > 0 {
                shift = fixedLSBWidth
            } else if scalableWidth > 0, adjustment > 0 {
                shift = scalableWidth + adjustment - 1
            } else {
                shift = scalableWidth + adjustment
            }
            guard shift > 0 else { continue }
            for sample in msbPlanes[channel].indices {
                let shiftedMSB = Int32(truncatingIfNeeded: Int64(msbPlanes[channel][sample]) << shift)
                let shiftedLSB = scalableWidth > 0
                    ? Int32(truncatingIfNeeded: Int64(lsbPlanes[channel][sample]) << adjustment)
                    : 0
                msbPlanes[channel][sample] = shiftedMSB &+ shiftedLSB
            }
        }
    }

    func multiplyQ16(_ first: Int32, _ second: Int32) -> Int32 {
        Int32(truncatingIfNeeded: roundShift(Int64(first) * Int64(second), by: 16))
    }

    func roundShift(_ value: Int64, by shift: Int) -> Int64 {
        shift > 0 ? (value + (Int64(1) << (shift - 1))) >> shift : value
    }

    func clip24(_ value: Int64) -> Int32 {
        Int32(min(Int64(8_388_607), max(Int64(-8_388_608), value)))
    }
}

private extension UInt64 {
    static func lowBitMask(width: Int) -> UInt64 {
        width == 64 ? .max : ((UInt64(1) << UInt64(width)) - 1)
    }

    var setBitIndices: [Int] {
        (0..<64).filter { self & (UInt64(1) << UInt64($0)) != 0 }
    }
}

private extension Int {
    static func ceilLog2(_ value: Int) -> Int {
        guard value > 1 else { return 0 }
        return Int.bitWidth - (value - 1).leadingZeroBitCount
    }
}
