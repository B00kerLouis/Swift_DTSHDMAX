import Foundation

/// Sample partition and navigation-width contract for one XLL frame.
/// DTS:X private XLL-X data must use the same sample partition in the enclosing
/// access unit. Entropy byte counts are independent, but private NAVI entries
/// use max(8, the enclosing XLL segment-size field width).
/// The private provider receives a provisional public width; the returned
/// frame's plan records the final width after both layers have contributed.
public struct XLLSegmentationPlan: Sendable, Equatable, Codable {
    public let segmentCount: Int
    public let segmentSampleCount: Int
    public let segmentSizeBitCount: Int?
    public let navigationByteCount: Int?
    /// Segment-major public XLL entropy byte counts. Each inner array contains
    /// one entry per channel set. Layout-only plans intentionally leave these
    /// arrays empty.
    public let segmentEntropyByteCounts: [[Int]]

    public init(segmentCount: Int, segmentSampleCount: Int) throws {
        try self.init(
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            segmentSizeBitCount: nil,
            navigationByteCount: nil,
            segmentEntropyByteCounts: Array(repeating: [], count: segmentCount)
        )
    }

    init(
        segmentCount: Int,
        segmentSampleCount: Int,
        segmentSizeBitCount: Int,
        navigationByteCount: Int,
        segmentEntropyByteCounts: [[Int]]
    ) throws {
        try self.init(
            segmentCount: segmentCount,
            segmentSampleCount: segmentSampleCount,
            segmentSizeBitCount: Optional(segmentSizeBitCount),
            navigationByteCount: Optional(navigationByteCount),
            segmentEntropyByteCounts: segmentEntropyByteCounts
        )
    }

    private init(
        segmentCount: Int,
        segmentSampleCount: Int,
        segmentSizeBitCount: Int?,
        navigationByteCount: Int?,
        segmentEntropyByteCounts: [[Int]]
    ) throws {
        guard [2, 4, 8].contains(segmentCount),
              segmentSampleCount > 0,
              segmentCount * segmentSampleCount == XLLSyntax.frameSampleCount,
              segmentEntropyByteCounts.count == segmentCount else {
            throw DTSError.valueOutOfRange(
                field: "XLL segmentation plan",
                value: "\(segmentCount)x\(segmentSampleCount)"
            )
        }
        if let segmentSizeBitCount {
            guard (1...XLLSyntax.segmentSizeBitCount).contains(segmentSizeBitCount),
                  let navigationByteCount,
                  navigationByteCount >= 2,
                  let channelSetCount = segmentEntropyByteCounts.first?.count,
                  channelSetCount > 0,
                  segmentEntropyByteCounts.allSatisfy({
                      $0.count == channelSetCount && $0.allSatisfy { $0 > 0 }
                  }) else {
                throw DTSError.malformed("XLL finalized segmentation plan is incomplete")
            }
        } else if navigationByteCount != nil
                    || segmentEntropyByteCounts.contains(where: { !$0.isEmpty }) {
            throw DTSError.malformed("XLL layout-only segmentation plan contains entropy metadata")
        }
        self.segmentCount = segmentCount
        self.segmentSampleCount = segmentSampleCount
        self.segmentSizeBitCount = segmentSizeBitCount
        self.navigationByteCount = navigationByteCount
        self.segmentEntropyByteCounts = segmentEntropyByteCounts
    }
}

enum XLLSyntax {
    static let syncWord: UInt64 = 0x41a2_9547
    static let streamVersion = 1
    static let frameSampleCount = 512
    static let segmentCount = 2
    static let segmentSampleCount = 256
    static let frameSizeBitCount = 16
    static let segmentSizeBitCount = 14
    static let linearSampleBitCount = 24
    static let samplingFrequencyIndex48k = 12
    /// The 48 kHz DTS Core analysis/synthesis loop primes two 512-sample
    /// access units before the source timeline. XLL full-channel sets share
    /// that timeline in Core-compatible DTS-HD MA and DTS:X streams.
    static let coreCompatiblePrimingSampleCount = 1_024

    static let reflectionCoefficients: [UInt16] = [
        0, 3070, 5110, 7140, 9156, 11154, 13132, 15085,
        17010, 18904, 20764, 22588, 24373, 26117, 27818, 29474,
        31085, 32648, 34164, 35631, 37049, 38418, 39738, 41008,
        42230, 43404, 44530, 45609, 46642, 47630, 48575, 49477,
        50337, 51157, 51937, 52681, 53387, 54059, 54697, 55302,
        55876, 56421, 56937, 57426, 57888, 58326, 58741, 59132,
        59502, 59852, 60182, 60494, 60789, 61066, 61328, 61576,
        61809, 62029, 62236, 62431, 62615, 62788, 62951, 63105,
        63250, 63386, 63514, 63635, 63749, 63855, 63956, 64051,
        64140, 64224, 64302, 64376, 64446, 64512, 64573, 64631,
        64686, 64737, 64785, 64830, 64873, 64913, 64950, 64986,
        65019, 65050, 65079, 65107, 65133, 65157, 65180, 65202,
        65222, 65241, 65259, 65275, 65291, 65306, 65320, 65333,
        65345, 65357, 65368, 65378, 65387, 65396, 65405, 65413,
        65420, 65427, 65434, 65440, 65446, 65451, 65456, 65461,
        65466, 65470, 65474, 65478, 65481, 65485, 65488, 65491,
    ]

    static let inverseDownmixScalesQ16: [UInt32] = [
        6_553_600, 6_186_997, 5_840_902, 5_514_167, 5_205_710, 4_914_507, 4_639_593, 4_380_059,
        4_135_042, 3_903_731, 3_685_360, 3_479_204, 3_284_581, 3_100_844, 2_927_386, 2_763_630,
        2_609_035, 2_463_088, 2_325_305, 2_195_230, 2_072_430, 2_013_631, 1_956_500, 1_900_990,
        1_847_055, 1_794_651, 1_743_733, 1_694_260, 1_646_190, 1_599_484, 1_554_103, 1_510_010,
        1_467_168, 1_425_542, 1_385_096, 1_345_798, 1_307_615, 1_270_515, 1_234_468, 1_199_444,
        1_165_413, 1_132_348, 1_100_221, 1_069_005, 1_038_676, 1_009_206, 980_573, 952_752,
        925_721, 899_456, 873_937, 849_141, 825_049, 801_641, 778_897, 756_798,
        735_326, 714_463, 694_193, 674_497, 655_360, 636_766, 618_700, 601_146,
        584_090, 567_518, 551_417, 535_772, 520_571, 505_801, 491_451, 477_507,
        463_959, 450_796, 438_006, 425_579, 413_504, 401_772, 390_373, 379_297,
        368_536, 363_270, 358_080, 352_964, 347_920, 342_949, 338_049, 333_219,
        328_458, 323_765, 319_139, 314_579, 310_084, 305_654, 301_287, 296_982,
        292_739, 288_556, 284_433, 280_369, 276_363, 272_414, 268_522, 264_685,
        260_904, 257_176, 253_501, 249_879, 246_309, 242_790, 239_321, 235_901,
        232_531, 229_208, 225_933, 222_705, 219_523, 216_386, 213_295, 210_247,
        207_243, 204_282, 201_363, 198_486, 195_650, 192_855, 190_099, 187_383,
        184_706, 182_066, 179_465, 176_901, 174_373, 171_882, 169_426, 167_005,
        164_619, 162_267, 159_948, 157_663, 155_410, 153_190, 151_001, 148_844,
        146_717, 144_621, 142_554, 140_517, 138_510, 136_531, 134_580, 132_657,
        130_762, 128_893, 127_052, 125_236, 123_447, 121_683, 119_944, 118_231,
        116_541, 114_876, 113_235, 111_617, 110_022, 108_450, 106_901, 105_373,
        103_868, 102_383, 100_921, 99_479, 98_057, 96_656, 95_275, 93_914,
        92_682, 91_249, 89_946, 88_660, 87_394, 86_145, 84_914, 83_701,
        82_505, 81_326, 80_164, 79_019, 77_890, 76_777, 75_680, 74_598,
        73_533, 72_482, 71_446, 70_425, 69_419, 68_427, 67_450, 66_486,
        65_536,
    ]

    static let downmixCoefficientsQ15: [UInt16] = [
        0, 33, 35, 37, 39, 41, 44, 46,
        49, 52, 55, 58, 62, 65, 69, 73,
        78, 82, 87, 92, 98, 104, 110, 116,
        123, 130, 138, 146, 155, 164, 174, 184,
        195, 207, 219, 232, 246, 260, 276, 292,
        309, 328, 347, 368, 389, 413, 437, 463,
        490, 519, 550, 583, 617, 654, 693, 734,
        777, 823, 872, 924, 978, 1_036, 1_066, 1_098,
        1_130, 1_163, 1_197, 1_232, 1_268, 1_305, 1_343, 1_382,
        1_422, 1_464, 1_506, 1_550, 1_596, 1_642, 1_690, 1_740,
        1_790, 1_843, 1_896, 1_952, 2_009, 2_068, 2_128, 2_190,
        2_254, 2_320, 2_388, 2_457, 2_529, 2_603, 2_679, 2_757,
        2_838, 2_920, 3_006, 3_093, 3_184, 3_277, 3_372, 3_471,
        3_572, 3_677, 3_784, 3_894, 4_008, 4_125, 4_246, 4_370,
        4_497, 4_629, 4_764, 4_903, 5_046, 5_193, 5_345, 5_501,
        5_662, 5_827, 5_912, 5_997, 6_084, 6_172, 6_262, 6_353,
        6_445, 6_538, 6_633, 6_729, 6_827, 6_925, 7_026, 7_128,
        7_231, 7_336, 7_442, 7_550, 7_659, 7_771, 7_883, 7_997,
        8_113, 8_231, 8_350, 8_471, 8_594, 8_719, 8_845, 8_973,
        9_103, 9_235, 9_369, 9_505, 9_643, 9_783, 9_924, 10_068,
        10_214, 10_362, 10_512, 10_665, 10_819, 10_976, 11_135, 11_297,
        11_460, 11_627, 11_795, 11_966, 12_139, 12_315, 12_494, 12_675,
        12_859, 13_045, 13_234, 13_426, 13_621, 13_818, 14_018, 14_222,
        14_428, 14_637, 14_849, 15_064, 15_283, 15_504, 15_729, 15_957,
        16_188, 16_423, 16_661, 16_902, 17_147, 17_396, 17_648, 17_904,
        18_164, 18_427, 18_694, 18_965, 19_240, 19_519, 19_802, 20_089,
        20_380, 20_675, 20_975, 21_279, 21_587, 21_900, 22_218, 22_540,
        22_867, 23_170, 23_534, 23_875, 24_221, 24_573, 24_929, 25_290,
        25_657, 26_029, 26_406, 26_789, 27_177, 27_571, 27_970, 28_376,
        28_787, 29_205, 29_628, 30_057, 30_493, 30_935, 31_383, 31_838,
        32_300, 32_768,
    ]

    static func inverseDownmixScaleQ16(code: Int) throws -> Int32 {
        let sign = (code >> 8) - 1
        let index = (code & 0xff) - 41
        guard inverseDownmixScalesQ16.indices.contains(index) else {
            throw DTSError.valueOutOfRange(field: "XLL downmix scale code", value: String(code))
        }
        let magnitude = Int32(inverseDownmixScalesQ16[index])
        return (magnitude ^ Int32(sign)) - Int32(sign)
    }

    static func undoDownmixCoefficientQ15(scaleCode: Int, coefficientCode: Int) throws -> Int32 {
        let coefficientIndex = coefficientCode & 0xff
        guard downmixCoefficientsQ15.indices.contains(coefficientIndex) else {
            throw DTSError.valueOutOfRange(field: "XLL downmix coefficient code", value: String(coefficientCode))
        }
        let inverseScale = try inverseDownmixScaleQ16(code: scaleCode)
        let coefficient = Int32(downmixCoefficientsQ15[coefficientIndex])
        let scaled = Int32((Int64(inverseScale) * Int64(coefficient) + 32_768) >> 16)
        let sign = (coefficientCode >> 8) - 1
        return (scaled ^ Int32(sign)) - Int32(sign)
    }
}

struct XLLFrameInfo: Sendable, Equatable, Codable {
    let byteCount: Int
    let sampleCount: Int
    let segmentCount: Int
    let segmentByteCounts: [Int]
    let format: PCMFormat
    let segmentationPlan: XLLSegmentationPlan?
}

struct XLLEncodedFrame: Sendable, Equatable {
    let data: Data
    let info: XLLFrameInfo
}
