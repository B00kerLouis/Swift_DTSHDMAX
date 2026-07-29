import Foundation

public struct AtmosPositionDifference: Sendable, Equatable, Codable {
    public let elementID: Int
    public let samplePosition: Int64
    public let baseline: AtmosPosition
    public let variant: AtmosPosition
    public let maximumCoordinateDifference: Double
}

public struct AtmosMasterComparisonReport: Sendable, Equatable, Codable {
    public let baselinePath: String
    public let variantPath: String
    public let sampleRateMatches: Bool
    public let sampleCountMatches: Bool
    public let channelAssignmentsMatch: Bool
    public let baselineMetadataEventCount: Int
    public let variantMetadataEventCount: Int
    public let baselinePositionEventCount: Int
    public let variantPositionEventCount: Int
    public let commonPositionEventCount: Int
    public let baselineOnlyPositionEventCount: Int
    public let variantOnlyPositionEventCount: Int
    public let differingPositionEventCount: Int
    public let maximumCoordinateDifference: Double
    public let firstDifference: AtmosPositionDifference?
}

public enum AtmosMasterComparator {
    private struct EventKey: Hashable, Comparable {
        let samplePosition: Int64
        let elementID: Int

        static func < (lhs: EventKey, rhs: EventKey) -> Bool {
            if lhs.samplePosition != rhs.samplePosition { return lhs.samplePosition < rhs.samplePosition }
            return lhs.elementID < rhs.elementID
        }
    }

    public static func compare(
        baseline: AtmosMaster,
        variant: AtmosMaster
    ) throws -> AtmosMasterComparisonReport {
        let baselinePositions = try positionEvents(baseline)
        let variantPositions = try positionEvents(variant)
        let baselineKeys = Set(baselinePositions.keys)
        let variantKeys = Set(variantPositions.keys)
        let commonKeys = baselineKeys.intersection(variantKeys)
        var differingCount = 0
        var maximumDifference = 0.0
        var firstDifference: AtmosPositionDifference?
        for key in commonKeys.sorted() {
            let baselinePosition = baselinePositions[key]!
            let variantPosition = variantPositions[key]!
            let difference = max(
                abs(baselinePosition.x - variantPosition.x),
                max(
                    abs(baselinePosition.y - variantPosition.y),
                    abs(baselinePosition.z - variantPosition.z)
                )
            )
            maximumDifference = max(maximumDifference, difference)
            if difference > 0 {
                differingCount += 1
                if firstDifference == nil {
                    firstDifference = AtmosPositionDifference(
                        elementID: key.elementID,
                        samplePosition: key.samplePosition,
                        baseline: baselinePosition,
                        variant: variantPosition,
                        maximumCoordinateDifference: difference
                    )
                }
            }
        }
        return AtmosMasterComparisonReport(
            baselinePath: baseline.manifestURL.standardizedFileURL.path,
            variantPath: variant.manifestURL.standardizedFileURL.path,
            sampleRateMatches: baseline.audioFormat.sampleRate == variant.audioFormat.sampleRate,
            sampleCountMatches: baseline.audioFormat.sampleCount == variant.audioFormat.sampleCount,
            channelAssignmentsMatch: baseline.bedChannels == variant.bedChannels
                && baseline.objects == variant.objects,
            baselineMetadataEventCount: baseline.metadataEvents.count,
            variantMetadataEventCount: variant.metadataEvents.count,
            baselinePositionEventCount: baselinePositions.count,
            variantPositionEventCount: variantPositions.count,
            commonPositionEventCount: commonKeys.count,
            baselineOnlyPositionEventCount: baselineKeys.subtracting(variantKeys).count,
            variantOnlyPositionEventCount: variantKeys.subtracting(baselineKeys).count,
            differingPositionEventCount: differingCount,
            maximumCoordinateDifference: maximumDifference,
            firstDifference: firstDifference
        )
    }

    private static func positionEvents(_ master: AtmosMaster) throws -> [EventKey: AtmosPosition] {
        let objectIDs = Set(master.objects.map(\.elementID))
        var result: [EventKey: AtmosPosition] = [:]
        for event in master.metadataEvents where objectIDs.contains(event.elementID) {
            guard let position = event.position else { continue }
            let key = EventKey(samplePosition: event.samplePosition, elementID: event.elementID)
            guard result.updateValue(position, forKey: key) == nil else {
                throw DTSError.malformed(
                    "Atmos master has duplicate position events for object \(event.elementID) "
                    + "at sample \(event.samplePosition)"
                )
            }
        }
        return result
    }
}
