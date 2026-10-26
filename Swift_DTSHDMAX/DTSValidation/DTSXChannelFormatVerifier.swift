import Foundation

public struct DTSXChannelFormatVerificationReport: Codable, Sendable {
    public let formats: Int
    public let privatePartitionWidthCases: Int
    public let integratedCases: Int
    public let rejectedCorruptionCases: Int
    public let layoutAnchorCases: Int
    public let optionCases: Int
    public let reservedHDMAPaddingCases: Int
}

/// Width contributions are tested with a narrow public bed and wide private
/// entropy. Independent official decoding/playback remains separate evidence.
public enum DTSXChannelFormatVerifier {
    public static func verify() throws -> DTSXChannelFormatVerificationReport {
        var partitions = 0, integrated = 0, corruptions = 0, anchors = 0
        func require(_ condition: Bool,_ message: String) throws {
            guard condition else { throw DTSError.malformed("Channel-format regression: \(message)") }
        }
        let formats = DTSXChannelFormat.allCases.filter { $0 != .sevenOneFour }
        for format in formats {
            let channels = format.heightChannelNames.count
            let values = (0..<channels).map { channel in
                (0..<512).map { sample -> Int32 in
                    let mixed = UInt64(sample+1)*1_664_525 + UInt64(channel+1)*1_013_904_223
                    return Int32(Int(mixed%2_000_001)-1_000_000)
                }
            }
            for segments in [2,4,8] {
                for width in [7,8,9,12,14] {
                    for mode in [DTSEncodeMode.auto,.standard] {
                        let plan = try XLLSegmentationPlan(segmentCount: segments,segmentSampleCount: 512/segments,
                            segmentSizeBitCount: width,navigationByteCount: 2+(width*segments+7)/8,
                            segmentEntropyByteCounts: Array(repeating: [1],count: segments))
                        let frame = try DTSXFixedPrivateFrame.encode(format: format,planes: values,plan: plan,mode: mode)
                        let parsed = try DTSXFixedPrivateFrame.parse(frame.data,segmentCount: segments,publicNavigationWidth: frame.navigationWidth)
                        try require(try parsed.decode(segmentCount: segments) == values,"private sample reconstruction")
                        try require(frame.navigationWidth >= max(8,width),"private provider narrowed the enclosing width")
                        var damaged = frame.data; damaged[format.metadata.count+2] ^= 1
                        do {
                            _ = try DTSXFixedPrivateFrame.parse(damaged,groupByteCount: frame.groupByteCount,navigationWidth: frame.navigationWidth)
                            throw DTSError.malformed("Channel-format regression accepted a corrupt group CRC")
                        } catch DTSError.checksumMismatch { corruptions += 1 }
                        catch DTSError.malformed(let message) {
                            guard !message.contains("regression accepted") else { throw DTSError.malformed(message) }
                            corruptions += 1
                        }
                        partitions += 1
                    }
                }
            }
            for mode in [DTSEncodeMode.auto,.standard] {
                let count = 513
                var planes = Array(repeating: [Int32](repeating: 0,count: count),count: format.channelNames.count)
                for channel in values.indices {
                    planes[format.bedChannelCount+channel] = values[channel]+[Int32(channel+1)]
                }
                let source = try DTSXChannelPCMBuffer(channelFormat: format,planes: planes)
                let bed = try source.compatibilityBed()
                let session = DTSXChannelStreamSession(source: source,mode: mode)
                var accessUnits: [Data] = []
                try DTSHDMAEncoder(configuration: .init(format: bed.format,tailPolicy: .zeroPad,xllCodingMode: mode.publicXLLCodingMode))
                    .encodeChannels(bed,session: session,writingAccessUnitsTo: { accessUnits.append($0) })
                try session.verifyComplete()
                try require(accessUnits.count == 4,"priming/tail access-unit accounting")
                let decoded = try DTSHDMADecoder().decode(accessUnits.reduce(into: Data()) { $0.append($1) })
                let comparison = try PCMComparator.compareWithZeroPadding(expected: bed,paddedActual: decoded)
                try require(comparison.isBitExact,"public bed PCM changed")
                integrated += 1
            }
            for (name,position) in [("Lfh",AtmosPosition(x: -0.5,y: 0.5,z: 1)),
                                    ("Crh",AtmosPosition(x: 0,y: -1,z: 1)),
                                    ("Cfh",AtmosPosition(x: 0,y: 1,z: 1)),
                                    ("Lhs",AtmosPosition(x: -1,y: 0,z: 1))] {
                guard let target = format.channelNames.firstIndex(of: name) else { continue }
                var state = AtmosObjectState(elementID: 1); state.active = true; state.position = position
                let gains = DTSXChannelPanner.gains(for: state,format: format)
                try require(gains.first(where: { $0.outputIndex == target })?.q30 == DTS714ChannelMapper.renderHeadroomQ30,"\(name) has no independent layout anchor")
                anchors += 1
            }
        }
        // A legal 64-bit reserved HDMA tail must stay ordinary HDMA. Its
        // length alone must not be mistaken for fixed DTS:X navigation.
        let ordinaryFormat = try PCMFormat(sampleRate: 48_000,bitDepth: 24,layout: .fiveOneSide)
        let ordinaryPCM = try PCMBuffer(format: ordinaryFormat,planes: Array(repeating: Array(repeating: 0,count: 512),count: 6))
        let ordinaryXLL = try XLLEncoder(codingMode: .terminalOfficialRice).encode(frame: ordinaryPCM)
        let ordinary = try ExSSWriter().wrap(xllFrame: ordinaryXLL,backwardCompatibleCore: true)
        var ordinaryReader = try BitReader(data: ordinary)
        try ordinaryReader.seek(to: 43,field: "Regression header size")
        let oldHeaderBytes = Int(try ordinaryReader.read(8,field: "Regression header size"))+1
        try ordinaryReader.seek(to: 106,field: "Regression descriptor size")
        let oldDescriptorBytes = Int(try ordinaryReader.read(9,field: "Regression descriptor size"))+1
        let descriptorEnd = 106+oldDescriptorBytes*8
        var extended = BitWriter()
        for bit in 0..<(oldHeaderBytes-2)*8 {
            if bit == descriptorEnd { try extended.write(0,bitCount: 48,field: "Extended HDMA reserved zeros") }
            try extended.write(UInt64((ordinary[bit/8] >> (7-bit%8)) & 1),bitCount: 1,field: "Original ExSS header")
        }
        try extended.write(0,bitCount: 16,field: "Extended ExSS alignment")
        try extended.patch(at: 43,value: UInt64(oldHeaderBytes+7),bitCount: 8,field: "Extended header size")
        try extended.patch(at: 51,value: UInt64(ordinary.count+7),bitCount: 16,field: "Extended frame size")
        try extended.patch(at: 106,value: UInt64(oldDescriptorBytes+5),bitCount: 9,field: "Extended descriptor size")
        try DTSCRC16.appendChecksum(to: &extended,protectedByteOffset: 5,component: "Extended ExSS regression")
        try extended.write(bytes: ordinaryXLL.data,field: "Unchanged XLL")
        let parsedOrdinary = try ExSSParser().parse(frame: extended.data())
        try require(parsedOrdinary.info.dtsxAssetDescriptorSignal == nil && parsedOrdinary.xllData == ordinaryXLL.data,
                    "zero reserved HDMA padding was reclassified as DTS:X")
        let base = ["-i","unused.atmos","-o","unused.dtshd"]
        for format in DTSXChannelFormat.allCases {
            let options = try DTSHDMACommandLine.parseAutomaticOptions(base+["--set-channel-format",format.rawValue])
            try require(options.channelFormat == format && options.dtsxVision == .sevenOneFour,"CLI format/vision selection")
            try require(options.objectMode == (format == .sevenOneFour ? .dynamic : .channelbase),"CLI object-mode defaults")
        }
        for invalid in [["--set-channel-format","7.1.2"],["--set-channel-format","5.1.5","--dtsx-vision","2"],
                        ["--set-channel-format","7.1.3","--object-mode","dynamic"],
                        ["--set-channel-format","7.1.3","--set-channel-format","7.1.4"]] {
            do { _ = try DTSHDMACommandLine.parseAutomaticOptions(base+invalid); throw DTSError.malformed("Invalid channel-format CLI options were accepted") }
            catch DTSError.invalidArgument { }
        }
        return .init(formats: formats.count,privatePartitionWidthCases: partitions,integratedCases: integrated,
                     rejectedCorruptionCases: corruptions,layoutAnchorCases: anchors,optionCases: 11,reservedHDMAPaddingCases: 1)
    }
}
