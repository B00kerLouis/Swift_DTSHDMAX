import Foundation

/// The ten-bit routing word that follows the private secondary sync.
///
/// The upper eight bits are four packed two-bit height indices in coded-plane
/// order. The low two bits select the private coding branch. Controlled
/// vectors prove that moving otherwise identical coded planes between height
/// speakers changes only this word and the CRC that covers it.
public struct DTSXPrivateRouting: Sendable, Equatable, Codable {
    public static let codedPlaneCount = 4

    public let codedPlaneToHeightPermutation: [Int]
    public let branchCode: Int

    public init(
        codedPlaneToHeightPermutation: [Int],
        branchCode: Int
    ) throws {
        guard Self.isPermutation(codedPlaneToHeightPermutation) else {
            throw DTSError.invalidArgument(
                "XLL-X routing must contain each height index 0...3 exactly once"
            )
        }
        guard (0...3).contains(branchCode) else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X private branch code",
                value: String(branchCode)
            )
        }
        self.codedPlaneToHeightPermutation = codedPlaneToHeightPermutation
        self.branchCode = branchCode
    }

    public init(packedTenBitCode: UInt16) throws {
        guard packedTenBitCode < 1_024 else {
            throw DTSError.valueOutOfRange(
                field: "XLL-X private routing word",
                value: String(packedTenBitCode)
            )
        }
        try self.init(
            codedPlaneToHeightPermutation: [
                Int((packedTenBitCode >> 8) & 0x03),
                Int((packedTenBitCode >> 6) & 0x03),
                Int((packedTenBitCode >> 4) & 0x03),
                Int((packedTenBitCode >> 2) & 0x03)
            ],
            branchCode: Int(packedTenBitCode & 0x03)
        )
    }

    public var packedTenBitCode: UInt16 {
        var value = UInt16(branchCode)
        for (codedPlane, height) in codedPlaneToHeightPermutation.enumerated() {
            let shift = 8 - codedPlane * 2
            value |= UInt16(height) << UInt16(shift)
        }
        return value
    }

    /// Reorders semantic Lfh/Rfh/Lrh/Rrh planes into the coded-plane order
    /// declared by this routing word.
    public func codedPlanes(fromHeightPlanes heightPlanes: [[Int32]]) throws -> [[Int32]] {
        guard heightPlanes.count == Self.codedPlaneCount else {
            throw DTSError.invalidArgument(
                "XLL-X height-plane input must contain Lfh/Rfh/Lrh/Rrh"
            )
        }
        return codedPlaneToHeightPermutation.map { heightPlanes[$0] }
    }

    /// Restores coded planes to semantic Lfh/Rfh/Lrh/Rrh speaker order.
    public func heightPlanes(fromCodedPlanes codedPlanes: [[Int32]]) throws -> [[Int32]] {
        guard codedPlanes.count == Self.codedPlaneCount else {
            throw DTSError.invalidArgument(
                "XLL-X coded-plane input must contain four planes"
            )
        }
        var heightPlanes = Array(repeating: [Int32](), count: Self.codedPlaneCount)
        for (codedPlane, height) in codedPlaneToHeightPermutation.enumerated() {
            heightPlanes[height] = codedPlanes[codedPlane]
        }
        return heightPlanes
    }

    /// Applies an old-height-index to new-height-index permutation while
    /// preserving coded-plane order and the private coding branch.
    public func remappingHeights(oldToNew: [Int]) throws -> DTSXPrivateRouting {
        guard Self.isPermutation(oldToNew) else {
            throw DTSError.invalidArgument(
                "XLL-X height remap must contain each index 0...3 exactly once"
            )
        }
        return try DTSXPrivateRouting(
            codedPlaneToHeightPermutation: codedPlaneToHeightPermutation.map {
                oldToNew[$0]
            },
            branchCode: branchCode
        )
    }

    private static func isPermutation(_ values: [Int]) -> Bool {
        values.count == codedPlaneCount
            && values.allSatisfy { (0..<codedPlaneCount).contains($0) }
            && Set(values).count == codedPlaneCount
    }
}

public extension DTSXPrivateFrameAST {
    var routing: DTSXPrivateRouting {
        get throws {
            try DTSXPrivateRouting(packedTenBitCode: secondaryTenBitCode)
        }
    }

    func replacingRouting(_ routing: DTSXPrivateRouting) -> DTSXPrivateFrameAST {
        DTSXPrivateFrameAST(
            fixedHeaderBytes: fixedHeaderBytes,
            headerCRC16: headerCRC16,
            packetType: packetType,
            reservedHighFourBits: reservedHighFourBits,
            primarySixBitCode: primarySixBitCode,
            separatorSixBits: separatorSixBits,
            secondarySyncWord: secondarySyncWord,
            secondaryPrefixSixBits: secondaryPrefixSixBits,
            secondaryTenBitCode: routing.packedTenBitCode,
            body: body
        )
    }

    /// Replaces the semantic routing word and regenerates the prediction-block
    /// CRC that covers frame bytes 22 through the prediction payload.
    func serializeReplacingRoutingAndRebuildingCRC(
        _ routing: DTSXPrivateRouting
    ) throws -> Data {
        try replacingRouting(routing).serializeRebuildingPredictionCRC()
    }
}
