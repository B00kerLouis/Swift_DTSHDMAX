import Foundation

/// Fixed-channel DTS:X presentation policy shared by CLI and Framework.
/// The spelling of --dtsx-vision is retained as the public command contract.
public enum DTSXVision: String, Sendable, Equatable, Codable, CaseIterable {
    case sevenOneFour = "1"
    case imax = "2"

    public init(argument: String) throws {
        guard let value = Self(rawValue: argument) else {
            throw DTSError.invalidArgument("--dtsx-vision must be 1 (7.1.4) or 2 (IMAX 12.1)")
        }
        self = value
    }
}
