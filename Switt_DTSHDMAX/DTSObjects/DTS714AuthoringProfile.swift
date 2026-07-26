import Foundation

public struct DTS714AuthoringSpeaker: Sendable, Equatable, Codable {
    public let configurationIndex: Int
    public let name: String
    public let channel: DTS714Channel
    public let azimuthDegrees: Int
    public let elevationDegrees: Int
    public let exceptionURI: String
}

public struct DTS714AuthoringPatch: Sendable, Equatable, Codable {
    public let first: DTS714Channel
    public let second: DTS714Channel
    public let third: DTS714Channel

    public var channels: [DTS714Channel] { [first, second, third] }
}

public enum DTSNearFieldLayout: String, Sendable, Codable, Hashable {
    case fiveOne = "5.1"
    case sevenOne = "7.1"
}

public enum DTSNearFieldSpeaker: String, Sendable, Codable, Hashable {
    case left = "L"
    case right = "R"
    case leftSurround = "LS"
    case rightSurround = "RS"
    case leftSideSurround = "LSS"
    case rightSideSurround = "RSS"
    case leftRearSurround = "LSR"
    case rightRearSurround = "RSR"
}

public struct DTSNearFieldDestination: Sendable, Equatable, Codable {
    public let speaker: DTSNearFieldSpeaker
    public let gainThousandths: Int
}

public struct DTSNearFieldRoute: Sendable, Equatable, Codable {
    public let source: DTS714Channel
    public let destinations: [DTSNearFieldDestination]
}

public struct DTSNearFieldDownmix: Sendable, Equatable, Codable {
    public let targetLayout: DTSNearFieldLayout
    public let routes: [DTSNearFieldRoute]
}

public struct DTS714AuthoringProfile: Sendable, Equatable, Codable {
    public let configurationVersion: Int
    public let authoringToolURI: String
    public let authoringToolVersion: String
    public let rendererSmoothingEnabled: Bool
    public let soundfieldURI: String
    public let sourceConfigurations: [String]
    public let speakers: [DTS714AuthoringSpeaker]
    public let lfeChannel: DTS714Channel
    public let patches: [DTS714AuthoringPatch]
    public let pcmChannelOrder: [DTS714Channel]
    public let configurationToPCMIndices: [Int]
    public let nearFieldDownmixes: [DTSNearFieldDownmix]

    public static let official = DTS714AuthoringProfile(
        configurationVersion: 3,
        authoringToolURI: "tag:dts.com,2016:mda:authtool:dtsx",
        authoringToolVersion: "1.5",
        rendererSmoothingEnabled: true,
        soundfieldURI: "tag:dts.com,2015:dtsx:channel-layout:7.1.4",
        sourceConfigurations: [
            "c7.1.4.dtsxnf.cfg",
            "smpte/c7.1.4.dtsxnf.cfg",
            "c7.1.dtsxnf.cfg",
            "c5.1.dtsxnf.cfg"
        ],
        speakers: [
            DTS714AuthoringSpeaker(
                configurationIndex: 0,
                name: "L",
                channel: .left,
                azimuthDegrees: -30,
                elevationDegrees: 0,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:L"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 1,
                name: "C",
                channel: .center,
                azimuthDegrees: 0,
                elevationDegrees: 0,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:C"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 2,
                name: "R",
                channel: .right,
                azimuthDegrees: 30,
                elevationDegrees: 0,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:R"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 3,
                name: "LSS",
                channel: .leftSideSurround,
                azimuthDegrees: -90,
                elevationDegrees: 0,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:LSS"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 4,
                name: "RSS",
                channel: .rightSideSurround,
                azimuthDegrees: 90,
                elevationDegrees: 0,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:RSS"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 5,
                name: "LSR",
                channel: .leftRearSurround,
                azimuthDegrees: -150,
                elevationDegrees: 0,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:LSR"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 6,
                name: "RSR",
                channel: .rightRearSurround,
                azimuthDegrees: 150,
                elevationDegrees: 0,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:RSR"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 7,
                name: "LFE1",
                channel: .lfe,
                azimuthDegrees: 0,
                elevationDegrees: 0,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:LFE1"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 8,
                name: "LFH",
                channel: .leftFrontHeight,
                azimuthDegrees: -45,
                elevationDegrees: 45,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:LFH"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 9,
                name: "RFH",
                channel: .rightFrontHeight,
                azimuthDegrees: 45,
                elevationDegrees: 45,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:RFH"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 10,
                name: "LRH",
                channel: .leftRearHeight,
                azimuthDegrees: -135,
                elevationDegrees: 45,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:LRH"
            ),
            DTS714AuthoringSpeaker(
                configurationIndex: 11,
                name: "RRH",
                channel: .rightRearHeight,
                azimuthDegrees: 135,
                elevationDegrees: 45,
                exceptionURI: "tag:dts.com,2015:dtsx:channel:RRH"
            )
        ],
        lfeChannel: .lfe,
        patches: [
            DTS714AuthoringPatch(first: .left, second: .center, third: .leftFrontHeight),
            DTS714AuthoringPatch(first: .left, second: .leftSideSurround, third: .leftFrontHeight),
            DTS714AuthoringPatch(first: .center, second: .right, third: .rightFrontHeight),
            DTS714AuthoringPatch(first: .center, second: .leftFrontHeight, third: .rightFrontHeight),
            DTS714AuthoringPatch(first: .right, second: .rightSideSurround, third: .rightFrontHeight),
            DTS714AuthoringPatch(first: .leftSideSurround, second: .leftRearSurround, third: .leftRearHeight),
            DTS714AuthoringPatch(first: .leftSideSurround, second: .leftFrontHeight, third: .leftRearHeight),
            DTS714AuthoringPatch(first: .rightSideSurround, second: .rightRearSurround, third: .rightRearHeight),
            DTS714AuthoringPatch(first: .rightSideSurround, second: .rightFrontHeight, third: .rightRearHeight),
            DTS714AuthoringPatch(first: .leftRearSurround, second: .rightRearSurround, third: .leftRearHeight),
            DTS714AuthoringPatch(first: .leftRearSurround, second: .rightRearSurround, third: .rightRearHeight),
            DTS714AuthoringPatch(first: .leftRearSurround, second: .leftRearHeight, third: .rightRearHeight),
            DTS714AuthoringPatch(first: .rightRearSurround, second: .leftRearHeight, third: .rightRearHeight),
            DTS714AuthoringPatch(first: .leftFrontHeight, second: .rightFrontHeight, third: .leftRearHeight),
            DTS714AuthoringPatch(first: .leftFrontHeight, second: .rightFrontHeight, third: .rightRearHeight),
            DTS714AuthoringPatch(first: .leftFrontHeight, second: .leftRearHeight, third: .rightRearHeight),
            DTS714AuthoringPatch(first: .rightFrontHeight, second: .leftRearHeight, third: .rightRearHeight)
        ],
        nearFieldDownmixes: [
            DTSNearFieldDownmix(
                targetLayout: .sevenOne,
                routes: [
                    DTSNearFieldRoute(
                        source: .leftFrontHeight,
                        destinations: [
                            DTSNearFieldDestination(speaker: .left, gainThousandths: 650),
                            DTSNearFieldDestination(speaker: .leftSideSurround, gainThousandths: 393)
                        ]
                    ),
                    DTSNearFieldRoute(
                        source: .rightFrontHeight,
                        destinations: [
                            DTSNearFieldDestination(speaker: .right, gainThousandths: 650),
                            DTSNearFieldDestination(speaker: .rightSideSurround, gainThousandths: 393)
                        ]
                    ),
                    DTSNearFieldRoute(
                        source: .leftRearHeight,
                        destinations: [
                            DTSNearFieldDestination(speaker: .leftRearSurround, gainThousandths: 650),
                            DTSNearFieldDestination(speaker: .leftSideSurround, gainThousandths: 393)
                        ]
                    ),
                    DTSNearFieldRoute(
                        source: .rightRearHeight,
                        destinations: [
                            DTSNearFieldDestination(speaker: .rightRearSurround, gainThousandths: 650),
                            DTSNearFieldDestination(speaker: .rightSideSurround, gainThousandths: 393)
                        ]
                    )
                ]
            ),
            DTSNearFieldDownmix(
                targetLayout: .fiveOne,
                routes: [
                    DTSNearFieldRoute(
                        source: .leftFrontHeight,
                        destinations: [
                            DTSNearFieldDestination(speaker: .left, gainThousandths: 592),
                            DTSNearFieldDestination(speaker: .leftSurround, gainThousandths: 316)
                        ]
                    ),
                    DTSNearFieldRoute(
                        source: .rightFrontHeight,
                        destinations: [
                            DTSNearFieldDestination(speaker: .right, gainThousandths: 592),
                            DTSNearFieldDestination(speaker: .rightSurround, gainThousandths: 316)
                        ]
                    ),
                    DTSNearFieldRoute(
                        source: .leftRearHeight,
                        destinations: [
                            DTSNearFieldDestination(speaker: .leftSurround, gainThousandths: 554),
                            DTSNearFieldDestination(speaker: .rightSurround, gainThousandths: 378)
                        ]
                    ),
                    DTSNearFieldRoute(
                        source: .rightRearHeight,
                        destinations: [
                            DTSNearFieldDestination(speaker: .leftSurround, gainThousandths: 378),
                            DTSNearFieldDestination(speaker: .rightSurround, gainThousandths: 554)
                        ]
                    )
                ]
            )
        ]
    )

    public init(
        configurationVersion: Int,
        authoringToolURI: String,
        authoringToolVersion: String,
        rendererSmoothingEnabled: Bool,
        soundfieldURI: String,
        sourceConfigurations: [String],
        speakers: [DTS714AuthoringSpeaker],
        lfeChannel: DTS714Channel,
        patches: [DTS714AuthoringPatch],
        nearFieldDownmixes: [DTSNearFieldDownmix]
    ) {
        self.configurationVersion = configurationVersion
        self.authoringToolURI = authoringToolURI
        self.authoringToolVersion = authoringToolVersion
        self.rendererSmoothingEnabled = rendererSmoothingEnabled
        self.soundfieldURI = soundfieldURI
        self.sourceConfigurations = sourceConfigurations
        self.speakers = speakers.sorted { $0.configurationIndex < $1.configurationIndex }
        self.lfeChannel = lfeChannel
        self.patches = patches
        pcmChannelOrder = DTS714Channel.allCases
        configurationToPCMIndices = self.speakers.map { speaker in
            DTS714Channel.allCases.firstIndex(of: speaker.channel) ?? -1
        }
        self.nearFieldDownmixes = nearFieldDownmixes
    }

    public func configurationIndex(for channel: DTS714Channel) -> Int? {
        speakers.first { $0.channel == channel }?.configurationIndex
    }

    public func validated() throws -> DTS714AuthoringProfile {
        guard configurationVersion == 3 else {
            throw DTSError.malformed("DTS:X authoring configuration version must be 3")
        }
        guard speakers.count == DTS714Channel.allCases.count else {
            throw DTSError.malformed("DTS:X 7.1.4 authoring profile must contain 12 speakers")
        }
        guard Set(speakers.map(\.configurationIndex)) == Set(0..<speakers.count) else {
            throw DTSError.malformed("DTS:X 7.1.4 configuration speaker indices are not contiguous")
        }
        guard Set(speakers.map(\.channel)) == Set(DTS714Channel.allCases) else {
            throw DTSError.malformed("DTS:X 7.1.4 authoring profile does not map every PCM channel exactly once")
        }
        guard configurationToPCMIndices == [0, 2, 1, 4, 5, 6, 7, 3, 8, 9, 10, 11] else {
            throw DTSError.malformed("DTS:X 7.1.4 configuration-to-PCM mapping differs from the authorized profile")
        }
        guard patches.count == 17,
              patches.allSatisfy({ Set($0.channels).count == 3 && !$0.channels.contains(.lfe) }) else {
            throw DTSError.malformed("DTS:X 7.1.4 authoring profile must contain 17 valid non-LFE patches")
        }
        let heightChannels: Set<DTS714Channel> = [
            .leftFrontHeight, .rightFrontHeight, .leftRearHeight, .rightRearHeight
        ]
        guard Set(nearFieldDownmixes.map(\.targetLayout)) == Set(DTSNearFieldLayout.allCases),
              nearFieldDownmixes.allSatisfy({ downmix in
                  Set(downmix.routes.map(\.source)) == heightChannels
                      && downmix.routes.allSatisfy { route in
                          route.destinations.count == 2
                              && route.destinations.allSatisfy { $0.gainThousandths > 0 }
                      }
              }) else {
            throw DTSError.malformed("DTS:X NearField downmix maps are incomplete")
        }
        return self
    }
}

extension DTSNearFieldLayout: CaseIterable {}
