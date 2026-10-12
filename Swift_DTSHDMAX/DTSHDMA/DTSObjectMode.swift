// Copyright (c) B00kerLouis.
import Foundation

/// Atmos presentation policy. It is independent of prediction and vision;
/// ordinary channel PCM has no object mode to apply.
public enum DTSObjectMode: String, Sendable, Equatable, Codable, CaseIterable {
    case dynamic
    case channelbase

    /// Default policy for each presentation. Explicit mode selection is
    /// independent of vision and continues to support both object paths.
    public static func defaultMode(for vision: DTSXVision) -> Self {
        vision == .imax ? .channelbase : .dynamic
    }

    public init(argument: String) throws {
        guard let mode = Self(rawValue: argument.lowercased()) else {
            throw DTSError.invalidArgument("--object-mode must be dynamic or channelbase")
        }
        self = mode
    }
}
