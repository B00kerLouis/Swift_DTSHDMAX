import Foundation

/// Delivery profiles observed in the supplied official reference sets.
/// Unlike the internal `xllStandalone` diagnostic profile, every official HDMA
/// access unit carries a backward-compatible Core and a scalable XLL asset.
public enum DTSOfficialHDMAProfile: String, Sendable, Equatable, Codable {
    case hdmaFiveOne = "HDMA-5.1"
    case hdmaSevenOne = "HDMA-7.1"
    case dtsxSevenOneFour = "DTS:X-HDMA-7.1.4"

    public var requiresBackwardCompatibleCore: Bool { true }
    public var requiresScalableXLL: Bool { true }
    public var requiresPrivateXLLX: Bool { self == .dtsxSevenOneFour }

    public var losslessChannelCount: Int {
        switch self {
        case .hdmaFiveOne: 6
        case .hdmaSevenOne, .dtsxSevenOneFour: 8
        }
    }

    public var immersiveInputChannelCount: Int? {
        self == .dtsxSevenOneFour ? DTS714Channel.allCases.count : nil
    }
}

public struct DTSOfficialHDMAProfileContract: Sendable, Equatable, Codable {
    public let profile: DTSOfficialHDMAProfile
    public let sampleRate: Int
    public let bitDepth: Int
    public let corePresent: Bool
    public let scalableXLL: Bool
    public let minimumXLLChannelSetCount: Int
    public let privateXLLXPresent: Bool

    public init(profile: DTSOfficialHDMAProfile) {
        self.profile = profile
        sampleRate = 48_000
        bitDepth = 24
        corePresent = profile.requiresBackwardCompatibleCore
        scalableXLL = profile.requiresScalableXLL
        minimumXLLChannelSetCount = profile == .hdmaFiveOne ? 1 : 2
        privateXLLXPresent = profile.requiresPrivateXLLX
    }
}
