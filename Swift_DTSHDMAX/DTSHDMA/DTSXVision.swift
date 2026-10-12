import Foundation

/// DTS:X height/IMAX profile policy shared by CLI and Framework. Object mode
/// independently selects dynamic aggregation or a fixed-channel presentation.
/// The spelling of --dtsx-vision is retained as the public command contract.
public enum DTSXVision: String, Sendable, Equatable, Codable, CaseIterable {
    case sevenOneFour = "1"
    case imax = "2"

    public init(argument: String) throws {
        guard let value = Self(rawValue: argument) else {
            throw DTSError.invalidArgument("--dtsx-vision must be 1 (standard height profile) or 2 (IMAX TFC profile)")
        }
        self = value
    }
}
