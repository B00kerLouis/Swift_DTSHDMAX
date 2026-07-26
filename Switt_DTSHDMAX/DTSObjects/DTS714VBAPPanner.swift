import Foundation

/// Pure Swift point-source renderer for the 7.1.4 authoring layout.
///
/// Atmos/IAB positions are room coordinates, not loudspeaker angles. The
/// production path below uses deterministic equal-power floor rows, a linear
/// floor/height blend, and fixed-point quantization so that the render can be compared against
/// supplied PCM oracles without an installed Atmos framework. The Pyra/Mesa
/// geometry tables are retained as offline research material while the
/// certified authoring mapping is still being fitted.
enum DTS714VBAPPanner {
    private struct Vector {
        var x: Float
        var y: Float
        var z: Float

        static let zero = Vector(x: 0, y: 0, z: 0)

        var norm: Float { sqrt(x * x + y * y + z * z) }

        func normalized() -> Vector {
            let length = norm
            return length > 1.0e-7 ? Vector(x: x / length, y: y / length, z: z / length) : self
        }
    }

    private struct Matrix {
        var rows: [Vector]

        init(_ rows: [Vector]) { self.rows = rows }

        func inverse() -> Matrix? {
            let a = rows
            let det = a[0].x * (a[1].y * a[2].z - a[1].z * a[2].y)
                - a[0].y * (a[1].x * a[2].z - a[1].z * a[2].x)
                + a[0].z * (a[1].x * a[2].y - a[1].y * a[2].x)
            guard abs(det) > 8.0 * Float.ulpOfOne else { return nil }
            let inv = 1.0 / det
            return Matrix([
                Vector(
                    x: inv * (a[1].y * a[2].z - a[1].z * a[2].y),
                    y: inv * (a[0].z * a[2].y - a[0].y * a[2].z),
                    z: inv * (a[0].y * a[1].z - a[0].z * a[1].y)
                ),
                Vector(
                    x: inv * (a[1].z * a[2].x - a[1].x * a[2].z),
                    y: inv * (a[0].x * a[2].z - a[0].z * a[2].x),
                    z: inv * (a[0].z * a[1].x - a[0].x * a[1].z)
                ),
                Vector(
                    x: inv * (a[1].x * a[2].y - a[1].y * a[2].x),
                    y: inv * (a[0].y * a[2].x - a[0].x * a[2].y),
                    z: inv * (a[0].x * a[1].y - a[0].y * a[1].x)
                )
            ])
        }
    }

    private struct Patch {
        let indices: (Int, Int, Int)
        let inverse: Matrix
        let mdaRows: [Vector]
    }

    private struct RoomModel {
        let speakers: [Vector]
        let midPlaneSpeakers: [Vector]
    }

    private static let roomModel: RoomModel = {
        let cornerAngles: [(Float, Float)] = [
            (-37.5, 0), (37.5, 0), (-142.5, 0), (142.5, 0),
            (-37.5, 25.97), (37.5, 25.97), (-142.5, 25.97), (142.5, 25.97)
        ]
        let speakerAngles: [(Float, Float)] = [
            (-30, 0), (30, 0), (-150, 0), (150, 0),
            (-45, 0), (45, 0), (-135, 0), (135, 0),
            (-24.79, 35.99), (24.79, 35.99), (-155.21, 35.99), (155.21, 35.99),
            (-24.79, 35.99), (24.79, 35.99), (-155.21, 35.99), (155.21, 35.99)
        ]
        let midPlaneAngles: [(Float, Float)] = [
            (-30, 0), (30, 0), (-150, 0), (150, 0),
            (-45, 0), (45, 0), (-135, 0), (135, 0),
            (-30, 21), (30, 21), (-150, 21), (150, 21),
            (-45, 22.2), (45, 22.2), (-135, 22.2), (135, 22.2)
        ]
        func wallCoordinate(azimuth: Float, elevation: Float) -> Vector {
            let radians = azimuth * Float.pi / 180
            let y: Float = (-90...90).contains(azimuth) ? 1 : -1
            let x = y * tan(radians)
            let horizontal = sqrt(x * x + y * y)
            return Vector(x: x, y: y, z: horizontal * tan(elevation * Float.pi / 180))
        }
        let corners = cornerAngles.map { wallCoordinate(azimuth: $0.0, elevation: $0.1) }
        let ceilingHeight = corners[4].z
        var speakers = speakerAngles.map { wallCoordinate(azimuth: $0.0, elevation: $0.1) }
        for index in speakers.indices where speakerAngles[index].1 > 0 {
            let scale = ceilingHeight / speakers[index].z
            speakers[index] = Vector(
                x: speakers[index].x * scale,
                y: speakers[index].y * scale,
                z: speakers[index].z * scale
            )
        }
        let midPlane = midPlaneAngles.map { wallCoordinate(azimuth: $0.0, elevation: $0.1) }
        for index in 8..<16 { speakers[index - 8] = midPlane[index] }
        return RoomModel(speakers: speakers, midPlaneSpeakers: midPlane)
    }()

    private static let iabVertices: [Vector] = [
        Vector(x: 1, y: -1, z: 1), Vector(x: 1, y: -1, z: 0.5), Vector(x: 1, y: -0.75, z: 0.5),
        Vector(x: 1, y: -1, z: 0), Vector(x: 1, y: -0.75, z: 0), Vector(x: 1, y: 0, z: 1),
        Vector(x: 1, y: 0, z: 0.5), Vector(x: 1, y: 0, z: 0), Vector(x: 1, y: 1, z: 1),
        Vector(x: 1, y: 0.75, z: 0.5), Vector(x: 1, y: 0.75, z: 0), Vector(x: 1, y: 1, z: 0.5),
        Vector(x: 1, y: 1, z: 0), Vector(x: 0, y: 1, z: 1), Vector(x: 0, y: 1, z: 0.5),
        Vector(x: 0, y: 1, z: 0), Vector(x: -1, y: -1, z: 1), Vector(x: -1, y: -1, z: 0.5),
        Vector(x: -1, y: -0.75, z: 0.5), Vector(x: -1, y: -1, z: 0), Vector(x: -1, y: -0.75, z: 0),
        Vector(x: -1, y: 0, z: 1), Vector(x: -1, y: 0, z: 0.5), Vector(x: -1, y: 0, z: 0),
        Vector(x: -1, y: 1, z: 1), Vector(x: -1, y: 0.75, z: 0.5), Vector(x: -1, y: 0.75, z: 0),
        Vector(x: -1, y: 1, z: 0.5), Vector(x: -1, y: 1, z: 0)
    ]

    private static let mdaVertices: [Vector] = [
        Vector(x: 0.33927557, y: -0.73455316, z: 0.58764253), Vector(x: 0.46682153, y: -0.80855860, z: 0.35820476),
        Vector(x: 0.65465367, y: -0.65465367, z: 0.37796447), Vector(x: 0.5, y: -0.86602540, z: 0),
        Vector(x: 0.70710678, y: -0.70710678, z: 0), Vector(x: 0.5, y: 0, z: 0.86602540),
        Vector(x: 0.86602540, y: 0, z: 0.5), Vector(x: 1, y: 0, z: 0),
        Vector(x: 0.33927557, y: 0.73455316, z: 0.58764253), Vector(x: 0.65465367, y: 0.65465367, z: 0.37796447),
        Vector(x: 0.70710678, y: 0.70710678, z: 0), Vector(x: 0.46682153, y: 0.80855860, z: 0.35820476),
        Vector(x: 0.5, y: 0.86602540, z: 0), Vector(x: 0, y: 0.78086881, z: 0.62469505),
        Vector(x: 0, y: 0.91429546, z: 0.40504792), Vector(x: 0, y: 1, z: 0),
        Vector(x: -0.33927557, y: -0.73455316, z: 0.58764253), Vector(x: -0.46682153, y: -0.80855860, z: 0.35820476),
        Vector(x: -0.65465367, y: -0.65465367, z: 0.37796447), Vector(x: -0.5, y: -0.86602540, z: 0),
        Vector(x: -0.70710678, y: -0.70710678, z: 0), Vector(x: -0.5, y: 0, z: 0.86602540),
        Vector(x: -0.86602540, y: 0, z: 0.5), Vector(x: -1, y: 0, z: 0),
        Vector(x: -0.33927557, y: 0.73455316, z: 0.58764253), Vector(x: -0.65465367, y: 0.65465367, z: 0.37796447),
        Vector(x: -0.70710678, y: 0.70710678, z: 0), Vector(x: -0.46682153, y: 0.80855860, z: 0.35820476),
        Vector(x: -0.5, y: 0.86602540, z: 0)
    ]

    private static let authoringProfile = DTS714AuthoringProfile.official

    private static let patchIndices: [(Int, Int, Int)] = authoringProfile.patches.map { patch in
        guard let first = authoringProfile.configurationIndex(for: patch.first),
              let second = authoringProfile.configurationIndex(for: patch.second),
              let third = authoringProfile.configurationIndex(for: patch.third) else {
            preconditionFailure("DTS:X authoring patch references an unmapped speaker")
        }
        return (first, second, third)
    }

    private static let pyraPatches: [(Int, Int, Int)] = [
        (1, 2, 3), (1, 2, 17), (1, 2, 18), (1, 3, 6), (1, 6, 17), (1, 6, 22),
        (1, 17, 18), (1, 17, 22), (2, 3, 5), (2, 4, 5), (2, 4, 18), (2, 4, 20),
        (2, 17, 18), (2, 18, 20), (3, 5, 8), (3, 6, 7), (3, 7, 8), (4, 18, 20),
        (6, 7, 10), (6, 9, 10), (6, 9, 14), (6, 14, 22), (6, 17, 22), (7, 8, 10),
        (8, 10, 11), (9, 10, 12), (9, 12, 15), (9, 14, 15), (10, 11, 12), (11, 12, 13),
        (12, 13, 16), (12, 15, 16), (14, 15, 25), (14, 22, 25), (15, 16, 28),
        (15, 25, 28), (16, 28, 29), (17, 18, 19), (17, 19, 22), (18, 19, 21),
        (18, 20, 21), (19, 21, 24), (19, 22, 23), (19, 23, 24), (22, 23, 26),
        (22, 25, 26), (23, 24, 26), (24, 26, 27), (25, 26, 28), (26, 27, 28), (27, 28, 29)
    ]

    private static let outputIndexByConfig = authoringProfile.configurationToPCMIndices
    private static let speakerVectors: [Vector] = authoringProfile.speakers.map {
        speaker(theta: Float($0.azimuthDegrees), elevation: Float($0.elevationDegrees))
    }

    private static let patches: [Patch] = {
        patchIndices.compactMap { a, b, c in
            guard let inverse = Matrix([speakerVectors[a], speakerVectors[b], speakerVectors[c]]).inverse() else { return nil }
            return Patch(indices: (a, b, c), inverse: inverse, mdaRows: [speakerVectors[a], speakerVectors[b], speakerVectors[c]])
        }
    }()

    static func gains(for state: AtmosObjectState) -> [(outputIndex: Int, q30: Int64)] {
        guard state.active, let position = state.position else { return [] }
        let x = min(1.0, max(-1.0, Float(position.x)))
        let y = min(1.0, max(-1.0, Float(position.y)))
        // A non-elevated object is constrained to the floor even when a
        // container carries a stale/non-zero height coordinate.
        let z = state.elevation
            ? min(1.0, max(0.0, Float(position.z)))
            : 0
        // The supplied DTS:X authoring vectors fit a rectangular room model:
        // floor rows are front/side/rear, while the height layer is a four-way
        // bilinear patch with x/y speaker boundaries at +/-0.5. It also keeps
        // the exact DTS:X contract deterministic at boundary points.
        let floor = floorGains(x: x, y: y)
        let height = heightGains(x: x, y: y)
        // The supplied authoring vectors use a linear room-height blend. The
        // combined vector is normalized below before object gain is applied.
        let floorWeight = 1 - z
        let heightWeight = z
        var channelGains = zip(floor, height).map { $0.0 * floorWeight + $0.1 * heightWeight }
        let norm = sqrt(channelGains.reduce(0) { $0 + $1 * $1 })
        if norm > 8.0 * Float.ulpOfOne {
            for index in channelGains.indices { channelGains[index] /= norm }
        }
        let objectGain = Float(pow(10.0, state.gain / 20.0))
        let headroom = Float(DTS714ChannelMapper.renderHeadroomQ30) / Float(DTS714ChannelMapper.unityQ30)
        for index in channelGains.indices { channelGains[index] *= objectGain * headroom }
        if state.snap, let strongest = channelGains.indices.max(by: { channelGains[$0] < channelGains[$1] }) {
            for index in channelGains.indices { channelGains[index] = index == strongest ? objectGain * headroom : 0 }
        }
        return channelGains.enumerated().compactMap { index, value in
            let q = Int64((Double(value) * Double(1 << 30)).rounded())
            return q == 0 ? nil : (index, q)
        }
    }

    private static func floorGains(x: Float, y: Float) -> [Float] {
        var output = Array(repeating: Float(0), count: DTS714Channel.allCases.count)
        let longitudinal = min(1, max(0, abs(y))) * .pi * 0.5
        let front = y >= 0 ? sin(longitudinal) : 0
        let side = cos(longitudinal)
        let rear = y < 0 ? sin(longitudinal) : 0
        if x <= 0 {
            let horizontal = min(1, max(0, x + 1)) * .pi * 0.5
            output[0] += front * cos(horizontal)
            output[2] += front * sin(horizontal)
        } else {
            let horizontal = min(1, max(0, x)) * .pi * 0.5
            output[2] += front * cos(horizontal)
            output[1] += front * sin(horizontal)
        }
        let horizontal = min(1, max(0, (x + 1) * 0.5)) * .pi * 0.5
        let left = cos(horizontal)
        let right = sin(horizontal)
        output[4] += side * left
        output[5] += side * right
        output[6] += rear * left
        output[7] += rear * right
        return output
    }

    private static func heightGains(x: Float, y: Float) -> [Float] {
        var output = Array(repeating: Float(0), count: DTS714Channel.allCases.count)
        let horizontal = min(1, max(0, x + 0.5))
        let vertical = min(1, max(0, 0.5 - y))
        let left = cos(horizontal * .pi * 0.5)
        let right = sin(horizontal * .pi * 0.5)
        let front = cos(vertical * .pi * 0.5)
        let rear = sin(vertical * .pi * 0.5)
        output[8] = left * front
        output[9] = right * front
        output[10] = left * rear
        output[11] = right * rear
        return output
    }

    /// Diagnostic hook used by the CLI/QC harness to inspect the deterministic
    /// room-to-bed transfer without exposing the implementation details in the
    /// public API.  Keeping this as a pure function makes it useful for fitting
    /// supplied 7.1.4 reference vectors as well as for regression tests.
    static func diagnosticGains(x: Double, y: Double, z: Double) -> [Double] {
        var state = AtmosObjectState(elementID: 0)
        state.active = true
        state.position = AtmosPosition(x: x, y: y, z: z)
        var result = Array(repeating: 0.0, count: DTS714Channel.allCases.count)
        for (index, gain) in gains(for: state) {
            result[index] = Double(gain) / Double(1 << 30)
        }
        return result
    }

    private static func speaker(theta: Float, elevation: Float) -> Vector {
        let t = theta * .pi / 180
        let e = elevation * .pi / 180
        return Vector(x: sin(t) * cos(e), y: cos(t) * cos(e), z: sin(e))
    }

    private static func rowMultiply(_ vector: Vector, _ matrix: Matrix) -> Vector {
        Vector(
            x: vector.x * matrix.rows[0].x + vector.y * matrix.rows[1].x + vector.z * matrix.rows[2].x,
            y: vector.x * matrix.rows[0].y + vector.y * matrix.rows[1].y + vector.z * matrix.rows[2].y,
            z: vector.x * matrix.rows[0].z + vector.y * matrix.rows[1].z + vector.z * matrix.rows[2].z
        )
    }

    private static func transformedDirection(x: Float, y: Float, z: Float) -> (azimuth: Float, elevation: Float, radius: Float) {
        var scaled = Array(repeating: Vector.zero, count: 16)
        for index in scaled.indices {
            if index < 8 {
                scaled[index] = z <= 0.5 ? roomModel.midPlaneSpeakers[index] : roomModel.speakers[index]
            } else if z <= 0.5 {
                let amount = (0.5 - z) / 0.5
                scaled[index] = Vector(
                    x: roomModel.midPlaneSpeakers[index].x
                        + amount * (roomModel.midPlaneSpeakers[index - 8].x - roomModel.midPlaneSpeakers[index].x),
                    y: roomModel.midPlaneSpeakers[index].y
                        + amount * (roomModel.midPlaneSpeakers[index - 8].y - roomModel.midPlaneSpeakers[index].y),
                    z: roomModel.midPlaneSpeakers[index].z * (z / 0.5)
                )
            } else {
                let amount = (1 - z) / 0.5
                scaled[index] = Vector(
                    x: roomModel.speakers[index].x + amount * (roomModel.speakers[index - 8].x - roomModel.speakers[index].x),
                    y: roomModel.speakers[index].y + amount * (roomModel.speakers[index - 8].y - roomModel.speakers[index].y),
                    z: roomModel.speakers[index - 8].z
                        + (roomModel.speakers[index].z - roomModel.speakers[index - 8].z) * ((z - 0.5) / 0.5)
                )
            }
        }

        let xAbs = abs(x)
        let front = y >= 0
        let slope = xAbs > 8.0 * Float.ulpOfOne ? abs(y) / xAbs : Float.greatestFiniteMagnitude
        var ySide: Float = 0.75
        if z > 0.5 { ySide += (1 - ySide) * ((z - 0.5) * 2) }
        let sideIndex = front ? 13 : 15
        let cornerIndex = front ? 9 : 11
        let ys1 = front ? scaled[sideIndex].y : -scaled[sideIndex].y
        let ys2 = front ? scaled[cornerIndex].y : -scaled[cornerIndex].y
        let xs1 = scaled[sideIndex].x
        let xs2 = scaled[cornerIndex].x
        let transformed: Vector
        if slope >= 1 {
            transformed = Vector(x: x * xs2, y: y * ys2, z: scaled[cornerIndex].z)
        } else if slope >= ySide {
            let blend = (slope - ySide) / (1 - ySide)
            transformed = Vector(
                x: x * xs2 + x * (1 - slope) * ((xs1 - xs2) / (1 - ySide)),
                y: xAbs * ys2 * (front ? 1 : -1),
                z: blend * scaled[cornerIndex].z + (1 - blend) * scaled[sideIndex].z
            )
        } else {
            transformed = Vector(
                x: x * xs1,
                y: (y / ySide) * ys1,
                z: scaled[sideIndex].z
            )
        }
        let length = transformed.norm
        let azimuth = length > 0 ? atan2(transformed.x, transformed.y) : 0
        let elevation = length > 0 ? max(0, asin(transformed.z / length)) : 0

        let x2 = abs(x)
        let y2 = abs(y)
        let intersection: Vector
        if z > 0, x2 / z < 1, y2 / z < 1 {
            intersection = Vector(x: x2 / z, y: y2 / z, z: 1)
        } else if x2 > y2 {
            intersection = x2 != 0
                ? Vector(x: 1, y: y2 / x2, z: z / x2)
                : Vector(x: 1, y: 0, z: 0)
        } else {
            intersection = y2 != 0
                ? Vector(x: x2 / y2, y: 1, z: z / y2)
                : Vector(x: 0, y: 1, z: 0)
        }
        let radius = intersection.norm > 0 ? Vector(x: x2, y: y2, z: z).norm / intersection.norm : 0
        return (azimuth, elevation, radius)
    }

    private static func interiorSources(azimuth: Float, elevation: Float, radius: Float) -> [(direction: Vector, gain: Float)] {
        guard radius < 1.0 - 8.0 * Float.ulpOfOne else {
            return [(Vector(x: cos(elevation) * sin(azimuth), y: cos(elevation) * cos(azimuth), z: sin(elevation)), 1)]
        }
        let height = radius * sin(elevation)
        let circle = sqrt(max(0, 1 - height * height))
        let objectRadius = radius * cos(elevation)
        let y1 = objectRadius * cos(azimuth)
        let x1 = max(-circle, min(circle, objectRadius * sin(azimuth)))
        let xRight = sqrt(max(0, circle * circle - min(circle, max(-circle, y1)) * min(circle, max(-circle, y1))))
        let rAzimuth = atan2(xRight, y1)
        let lAzimuth = -rAzimuth
        let lElevation = min(.pi / 2, max(0, atan2(height, circle)))
        let tableIndex = max(0, min(200, Int(((xRight + x1) / max(2 * xRight, 1.0e-7)) * 201)))
        let rGain0 = sin(Float(tableIndex) / 201 * .pi / 2)
        let lGain0 = sin(Float(200 - tableIndex) / 201 * .pi / 2)
        let sum = max(lGain0 + rGain0, 1.0e-7)
        var lGain = lGain0 / sum
        var rGain = rGain0 / sum
        var pGain = max(0, (100 * radius - 75) / 25)
        let frontRight = Float(45) * Float.pi / 180
        let rearRight = Float(135) * Float.pi / 180
        if rAzimuth < frontRight {
            let factor = rAzimuth / frontRight
            lGain *= factor; rGain *= factor
        } else if rAzimuth > rearRight {
            let factor = (.pi - rAzimuth) / (.pi - rearRight)
            lGain *= factor; rGain *= factor
        }
        let total = max(lGain + rGain + pGain, 1.0e-7)
        lGain /= total; rGain /= total; pGain /= total
        let projected = Vector(x: cos(elevation) * sin(azimuth), y: cos(elevation) * cos(azimuth), z: sin(elevation))
        let left = Vector(x: cos(lElevation) * sin(lAzimuth), y: cos(lElevation) * cos(lAzimuth), z: sin(lElevation))
        let right = Vector(x: cos(lElevation) * sin(rAzimuth), y: cos(lElevation) * cos(rAzimuth), z: sin(lElevation))
        return [(left, lGain), (right, rGain), (projected, pGain)].filter { $0.gain > 0 }
    }

    private static func renderPoint(_ source: Vector) -> [Float] {
        let normalized = source.normalized()
        var gains = Array(repeating: Float(0), count: DTS714Channel.allCases.count)
        var active: Float = 0
        for patch in patches {
            let coefficients = rowMultiply(normalized, patch.inverse)
            if coefficients.x < -8.0 * Float.ulpOfOne || coefficients.y < -8.0 * Float.ulpOfOne || coefficients.z < -8.0 * Float.ulpOfOne { continue }
            let significant = [coefficients.x, coefficients.y, coefficients.z].filter { $0 > 8.0 * Float.ulpOfOne }.count
            let weight: Float = significant == 2 ? 0.5 : 1
            let values = [coefficients.x, coefficients.y, coefficients.z]
            for (n, value) in values.enumerated() {
                let configIndex = [patch.indices.0, patch.indices.1, patch.indices.2][n]
                gains[outputIndexByConfig[configIndex]] += value * weight
            }
            active += weight
            if significant == 1 { break }
        }
        guard active > 0 else { return gains }
        for index in gains.indices { gains[index] /= active }
        return gains
    }
}
