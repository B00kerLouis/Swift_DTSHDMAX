// Copyright (c) B00kerLouis.
import Foundation

public struct DTSXSpatialAggregationReport: Sendable, Equatable, Codable {
    public let sourceObjectCount: Int
    public let analysedFrameCount: Int
    public let energyWeightedNearestImageError: Double
    public let energyWeightedFittedImageError: Double
    public let maximumAngularQuantizationErrorDegrees: Double
    public let maximumDistanceQuantizationError: Double
    public let reservedTFCNonzeroSamples: Int
    public let reservedTFCExcludedFromDynamicAggregation: Bool
    public let fixedBedCarriesSpatialResidual: Bool
}

/// Measured native 7.1.4 presentation transition. First declarations install
/// directly; subsequent targets use a sample-continuous one-pole transition.
/// The fixed bed carries the image outside the four moving columns, including
/// their transition, so quiet centre/height sources cannot disappear.
struct DTSXDynamicPresentationState {
    private(set) var gains: [[Double]] = []
    private var targets: [[Double]] = []
    static let transitionCoefficient = 0.001098198738079148

    mutating func retarget(_ columns: [[Double]]) {
        if gains.isEmpty { gains = columns }
        targets = columns
    }

    mutating func advance() {
        for slot in gains.indices {
            for channel in gains[slot].indices {
                gains[slot][channel] += (targets[slot][channel]-gains[slot][channel])*Self.transitionCoefficient
            }
        }
    }
}

/// Enumerates all sixteen active subsets of four speaker-image columns,
/// rejects negative solutions and selects the smallest residual. An audible
/// source outside that span remains on the fixed residual.
enum DTSXDynamicSpatialModel {
    static let vectors: [(Double,Double,Double)] = {
        let angles: [(Double,Double)] = [(-30,0),(30,0),(0,0),(0,0),(-90,0),(90,0),(-150,0),(150,0),
                                       (-45,45),(45,45),(-135,45),(135,45),(0,25.5)]
        return angles.map { azimuth,elevation in
            let a = azimuth * .pi/180, e = elevation * .pi/180
            return (sin(a)*cos(e),cos(a)*cos(e),sin(e))
        }
    }()

    static func direction(image: [Double], radius: Double) -> AtmosPosition {
        var x = 0.0, y = 0.0, z = 0.0
        for channel in image.indices where channel != 3 {
            x += image[channel]*vectors[channel].0; y += image[channel]*vectors[channel].1
            z += image[channel]*vectors[channel].2
        }
        let norm = sqrt(x*x+y*y+z*z)
        guard norm > 1e-12 else { return AtmosPosition(x: 0,y: radius,z: 0) }
        return AtmosPosition(x: x/norm*radius,y: y/norm*radius,z: z/norm*radius)
    }

    static func image(room: AtmosPosition, layout: DTSXDynamicLayout) -> [Double] {
        var state = AtmosObjectState(elementID: 0); state.active = true; state.position = room
        var image = Array(repeating: 0.0,count: layout.fixedPlaneCount)
        let gains = layout == .sevenOneFour ? DTS714VBAPPanner.gains(for: state) : DTSIMAXPanner.gains(for: state)
        for (channel,gain) in gains { image[channel] = Double(gain)/Double(1 << 30) }
        return image
    }

    static func image(position: DTSXObjectPosition, layout: DTSXDynamicLayout) -> [Double] {
        let field = DTS714VBAPPanner.transportGains(azimuth: position.azimuth,elevation: position.elevation,
                                                  distance: position.distance)
        return field + (layout == .sevenOneFive ? [0] : [])
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }
    static func rendered(_ weights: [Double], columns: [[Double]]) -> [Double] {
        (0..<columns[0].count).map { row in columns.indices.reduce(0) { $0+weights[$1]*columns[$1][row] } }
    }
    static func error(target: [Double], weights: [Double], columns: [[Double]]) -> Double {
        zip(target,rendered(weights,columns: columns)).reduce(0) { $0+pow($1.0-$1.1,2) }
    }

    static func fit(target: [Double], columns: [[Double]]) -> [Double] {
        let power = dot(target,target)
        guard power > 1e-20 else { return Array(repeating: 0,count: 4) }
        let gram = columns.map { a in columns.map { dot(a,$0) } }
        let rhs = columns.map { dot($0,target) }
        var best = Array(repeating: 0.0,count: 4), bestError = power
        for mask in 1..<16 {
            let active = (0..<4).filter { mask & (1 << $0) != 0 }
            var matrix = active.map { i in active.map { gram[i][$0] } + [rhs[i]] }
            var valid = true
            for column in active.indices {
                let pivot = (column..<active.count).max { abs(matrix[$0][column]) < abs(matrix[$1][column]) }!
                matrix.swapAt(column,pivot)
                let divisor = matrix[column][column]
                if abs(divisor) < 1e-10 { valid = false; break }
                for j in column...active.count { matrix[column][j] /= divisor }
                for row in active.indices where row != column {
                    let multiplier = matrix[row][column]
                    for j in column...active.count { matrix[row][j] -= multiplier*matrix[column][j] }
                }
            }
            guard valid else { continue }
            var candidate = Array(repeating: 0.0,count: 4)
            for (row,index) in active.enumerated() {
                let value = matrix[row][active.count]
                if value < -1e-9 || !value.isFinite { valid = false; break }
                candidate[index] = max(0,value)
            }
            if valid {
                let cost = error(target: target,weights: candidate,columns: columns)
                if cost < bestError { best = candidate; bestError = cost }
            }
        }
        // Unspanned energy belongs to the fixed residual. Normalizing a weak
        // projection to full power (or forcing an orthogonal source onto its
        // nearest carrier) invents an audible object at the wrong position.
        return best
    }
}
