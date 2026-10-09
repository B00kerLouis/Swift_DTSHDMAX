import Foundation

/// Shared product policy for the command-line and Framework entry points.
/// Auto searches 2/4/8 partitions with frame-local prediction; standard keeps
/// direct samples on the qualified delivery partition and Rice grammar.
public enum DTSEncodeMode: String, Sendable, Equatable, Codable, CaseIterable {
    case auto
    case standard

    public init(argument: String) throws {
        guard let mode = Self(rawValue: argument.lowercased()) else {
            throw DTSError.invalidArgument("--encode-mode must be auto or standard")
        }
        self = mode
    }

    var publicXLLCodingMode: XLLCodingMode {
        switch self {
        case .auto: .terminalAutomaticPredictive
        case .standard: .terminalOfficialRice
        }
    }

    var privateXLLXCodingMode: DTSXPrivateCodingMode {
        switch self {
        case .auto: .terminalPredictiveOfficial
        case .standard: .terminalRiceOfficial
        }
    }
}
