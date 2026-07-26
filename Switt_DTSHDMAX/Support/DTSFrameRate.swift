import Foundation

/// Exact non-drop SMPTE authoring frame rate carried by the DTSHD `TIMECODE`
/// chunk and delivery sidecars. Audio access units remain 512 samples; this
/// value is the picture/object-metadata timebase and is never inferred from
/// an audio access-unit duration.
public struct DTSFrameRate: Sendable, Hashable, Codable, CustomStringConvertible {
    public let numerator: Int
    public let denominator: Int

    public static let fps23976 = DTSFrameRate(uncheckedNumerator: 24_000, denominator: 1_001)
    public static let fps24 = DTSFrameRate(uncheckedNumerator: 24, denominator: 1)
    public static let fps47952 = DTSFrameRate(uncheckedNumerator: 48_000, denominator: 1_001)
    public static let fps25 = DTSFrameRate(uncheckedNumerator: 25, denominator: 1)
    public static let fps2997 = DTSFrameRate(uncheckedNumerator: 30_000, denominator: 1_001)
    public static let fps30 = DTSFrameRate(uncheckedNumerator: 30, denominator: 1)
    public static let fps48 = DTSFrameRate(uncheckedNumerator: 48, denominator: 1)
    public static let fps50 = DTSFrameRate(uncheckedNumerator: 50, denominator: 1)
    public static let fps5994 = DTSFrameRate(uncheckedNumerator: 60_000, denominator: 1_001)
    public static let fps60 = DTSFrameRate(uncheckedNumerator: 60, denominator: 1)

    /// Accepted `--frame-rate` values. Each value is non-drop; `df` and
    /// drop-frame authoring are deliberately rejected.
    public static let supportedArgumentValues = definitions.map(\.argument)

    public init(numerator: Int, denominator: Int) throws {
        guard numerator > 0, denominator > 0 else {
            throw DTSError.invalidArgument("frame rate numerator and denominator must be positive")
        }
        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        let reducedNumerator = numerator / divisor
        let reducedDenominator = denominator / divisor
        guard Self.definition(numerator: reducedNumerator, denominator: reducedDenominator) != nil else {
            throw DTSError.unsupported(
                "DTSHD authoring frame rate \(numerator)/\(denominator); supported non-drop SMPTE rates are \(Self.supportedArgumentValues.joined(separator: ", "))"
            )
        }
        self.numerator = reducedNumerator
        self.denominator = reducedDenominator
    }

    public init(argument: String) throws {
        let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.lowercased()
        guard !normalized.contains("drop") && !normalized.contains("df") else {
            throw DTSError.unsupported("drop-frame timecode is not supported; use a non-drop SMPTE rate")
        }
        if value.contains("/") {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let numerator = Int(parts[0]),
                  let denominator = Int(parts[1]) else {
                throw DTSError.invalidArgument(Self.argumentHelp)
            }
            try self.init(numerator: numerator, denominator: denominator)
            return
        }
        guard let parsed = Double(value) else {
            throw DTSError.invalidArgument(Self.argumentHelp)
        }
        try self.init(framesPerSecond: parsed)
    }

    public init(framesPerSecond: Double) throws {
        guard framesPerSecond.isFinite, framesPerSecond > 0 else {
            throw DTSError.invalidArgument("frame rate metadata is not a positive finite value")
        }
        guard let definition = Self.definitions.first(where: {
            abs(framesPerSecond - $0.framesPerSecond) < 0.001
        }) else {
            throw DTSError.unsupported(
                "DTSHD authoring frame rate \(framesPerSecond); supported non-drop SMPTE rates are \(Self.supportedArgumentValues.joined(separator: ", "))"
            )
        }
        self.init(uncheckedNumerator: definition.numerator, denominator: definition.denominator)
    }

    private enum CodingKeys: String, CodingKey {
        case numerator
        case denominator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try container.decode(Int.self, forKey: .numerator)
        let denominator = try container.decode(Int.self, forKey: .denominator)
        do {
            try self.init(numerator: numerator, denominator: denominator)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .numerator,
                in: container,
                debugDescription: "unsupported DTSHD authoring frame rate \(numerator)/\(denominator): \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numerator, forKey: .numerator)
        try container.encode(denominator, forKey: .denominator)
    }

    /// Byte 4 of the 32-byte DTSHD `TIMECODE` payload. The codepoints retain
    /// the existing 23.976/24 values and extend in ascending SMPTE rate order.
    var containerCode: UInt8 {
        Self.definition(numerator: numerator, denominator: denominator)!.containerCode
    }

    init(containerCode: UInt8) throws {
        guard let definition = Self.definitions.first(where: { $0.containerCode == containerCode }) else {
            throw DTSError.unsupported(
                "DTSHD TIMECODE frame-rate code 0x\(String(containerCode, radix: 16))"
            )
        }
        self.init(uncheckedNumerator: definition.numerator, denominator: definition.denominator)
    }

    /// Non-drop SMPTE timecode counts fractional rates on their nominal clock:
    /// 23.976 maps to 24, 29.97 to 30, 47.952 to 48, and 59.94 to 60.
    public var nominalFramesPerSecond: Int {
        Self.definition(numerator: numerator, denominator: denominator)!.nominalFramesPerSecond
    }

    public var framesPerSecond: Double {
        Double(numerator) / Double(denominator)
    }

    public var description: String {
        Self.definition(numerator: numerator, denominator: denominator)!.argument
    }

    public func frameCount(
        forSampleCount sampleCount: Int,
        sampleRate: Int,
        roundingUp: Bool
    ) throws -> Int {
        guard sampleCount >= 0, sampleRate > 0 else {
            throw DTSError.invalidArgument("frame-rate sample conversion requires non-negative samples")
        }
        let (scaledSamples, firstOverflow) = sampleCount.multipliedReportingOverflow(by: numerator)
        let (scale, secondOverflow) = sampleRate.multipliedReportingOverflow(by: denominator)
        guard !firstOverflow, !secondOverflow, scale > 0 else {
            throw DTSError.valueOutOfRange(
                field: "frame-rate sample conversion",
                value: "\(sampleCount) samples at \(sampleRate) Hz"
            )
        }
        if roundingUp {
            let (adjusted, overflow) = scaledSamples.addingReportingOverflow(scale - 1)
            guard !overflow else {
                throw DTSError.valueOutOfRange(
                    field: "frame-rate rounded frame count",
                    value: String(sampleCount)
                )
            }
            return adjusted / scale
        }
        return scaledSamples / scale
    }

    public static func resolve(
        metadataFramesPerSecond: Double?,
        override: DTSFrameRate?,
        sourceDescription: String
    ) throws -> DTSFrameRate {
        let metadata = try metadataFramesPerSecond.map(DTSFrameRate.init(framesPerSecond:))
        if let metadata, let override, metadata != override {
            throw DTSError.invalidArgument(
                "--frame-rate \(override) differs from \(sourceDescription) metadata \(metadata)"
            )
        }
        if let metadata { return metadata }
        if let override { return override }
        throw DTSError.invalidArgument(
            "\(sourceDescription) has no frame-rate metadata; specify --frame-rate \(supportedArgumentValues.joined(separator: "|"))"
        )
    }

    private struct Definition: Sendable {
        let numerator: Int
        let denominator: Int
        let argument: String
        let containerCode: UInt8
        let nominalFramesPerSecond: Int

        var framesPerSecond: Double {
            Double(numerator) / Double(denominator)
        }
    }

    private static let definitions: [Definition] = [
        Definition(numerator: 24_000, denominator: 1_001, argument: "23.976", containerCode: 0x01, nominalFramesPerSecond: 24),
        Definition(numerator: 24, denominator: 1, argument: "24", containerCode: 0x02, nominalFramesPerSecond: 24),
        Definition(numerator: 48_000, denominator: 1_001, argument: "47.952", containerCode: 0x03, nominalFramesPerSecond: 48),
        Definition(numerator: 25, denominator: 1, argument: "25", containerCode: 0x04, nominalFramesPerSecond: 25),
        Definition(numerator: 30_000, denominator: 1_001, argument: "29.97", containerCode: 0x05, nominalFramesPerSecond: 30),
        Definition(numerator: 30, denominator: 1, argument: "30", containerCode: 0x06, nominalFramesPerSecond: 30),
        Definition(numerator: 48, denominator: 1, argument: "48", containerCode: 0x07, nominalFramesPerSecond: 48),
        Definition(numerator: 50, denominator: 1, argument: "50", containerCode: 0x08, nominalFramesPerSecond: 50),
        Definition(numerator: 60_000, denominator: 1_001, argument: "59.94", containerCode: 0x09, nominalFramesPerSecond: 60),
        Definition(numerator: 60, denominator: 1, argument: "60", containerCode: 0x0A, nominalFramesPerSecond: 60),
    ]

    private static let argumentHelp =
        "--frame-rate must be one of \(supportedArgumentValues.joined(separator: ", ")), or an equivalent exact numerator/denominator"

    private static func definition(numerator: Int, denominator: Int) -> Definition? {
        definitions.first { $0.numerator == numerator && $0.denominator == denominator }
    }

    private init(uncheckedNumerator: Int, denominator: Int) {
        numerator = uncheckedNumerator
        self.denominator = denominator
    }

    private static func greatestCommonDivisor(_ first: Int, _ second: Int) -> Int {
        var a = first
        var b = second
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return a
    }
}
