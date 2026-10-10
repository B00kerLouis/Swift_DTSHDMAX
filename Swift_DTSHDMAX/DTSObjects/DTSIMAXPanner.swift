import Foundation

/// Fixed IMAX front-upper L/C/R row and rear-upper L/R row. This panner is
/// isolated from the established twelve-channel authoring arithmetic.
enum DTSIMAXPanner {
    static func gains(for state: AtmosObjectState) -> [(outputIndex: Int, q30: Int64)] {
        guard state.active, let position = state.position else { return [] }
        let x = min(1, max(-1, Float(position.x)))
        let y = min(1, max(-1, Float(position.y)))
        let z = state.elevation ? min(1, max(0, Float(position.z))) : 0
        let upper = sin(z * .pi / 2)
        let lower = max(0, cos(z * .pi / 2))
        var output = floorGains(x: x, y: y).map { $0 * lower }
        output.append(0)
        let front = sin((y + 1) * .pi / 4) * upper
        let rear = max(0, cos((y + 1) * .pi / 4)) * upper
        if x <= 0 {
            output[8] = front * max(0, cos((x + 1) * .pi / 2))
            output[12] = front * sin((x + 1) * .pi / 2)
        } else {
            output[12] = front * max(0, cos(x * .pi / 2))
            output[9] = front * sin(x * .pi / 2)
        }
        output[10] = rear * max(0, cos((x + 1) * .pi / 4))
        output[11] = rear * sin((x + 1) * .pi / 4)
        let norm = sqrt(output.reduce(Float(0)) { $0 + $1 * $1 })
        let gain = Float(pow(10, state.gain / 20)) * Float(DTS714ChannelMapper.renderHeadroomQ30) / Float(1 << 30)
        if norm > 0 { for index in output.indices { output[index] = output[index] / norm * gain } }
        if state.snap, let strongest = output.indices.max(by: { output[$0] < output[$1] }) {
            for index in output.indices { output[index] = index == strongest ? gain : 0 }
        }
        return output.enumerated().compactMap { index, value in
            let q = Int64((Double(value) * Double(1 << 30)).rounded())
            return q == 0 ? nil : (index, q)
        }
    }

    private static func floorGains(x: Float, y: Float) -> [Float] {
        var output = Array(repeating: Float(0), count: 12)
        let longitudinal = abs(y) * .pi / 2
        let front = y >= 0 ? sin(longitudinal) : 0
        let side = cos(longitudinal)
        let rear = y < 0 ? sin(longitudinal) : 0
        if x <= 0 {
            output[0] = front * cos((x + 1) * .pi / 2)
            output[2] = front * sin((x + 1) * .pi / 2)
        } else {
            output[2] = front * cos(x * .pi / 2)
            output[1] = front * sin(x * .pi / 2)
        }
        let left = cos((x + 1) * .pi / 4)
        let right = sin((x + 1) * .pi / 4)
        output[4] = side * left; output[5] = side * right
        output[6] = rear * left; output[7] = rear * right
        return output
    }
}

/// Composes the existing exact integer slew state without changing its
/// twelve-channel storage or the default authoring path. The extra state
/// carries TFC in lane zero; only its one gain is routed to lane thirteen.
struct DTSIMAXObjectGainSmoother: Sendable {
    static let defaultPanSubBlockSampleCount = DTS714ObjectGainSmoother.defaultPanSubBlockSampleCount
    private var bed = DTS714ObjectGainSmoother()
    private var center = DTS714ObjectGainSmoother()
    private(set) var currentGains = Array(repeating: Int64(0), count: 13)
    private(set) var activeIndices: [Int] = []

    mutating func setImmediately(_ gains: [(outputIndex: Int, q30: Int64)]) {
        bed.setImmediately(gains.filter { $0.outputIndex < 12 })
        center.setImmediately(gains.filter { $0.outputIndex == 12 }.map { (0, $0.q30) })
        synchronize(indices: true)
    }

    mutating func retarget(_ gains: [(outputIndex: Int, q30: Int64)], over samples: Int) {
        bed.retarget(gains.filter { $0.outputIndex < 12 }, over: samples)
        center.retarget(gains.filter { $0.outputIndex == 12 }.map { (0, $0.q30) }, over: samples)
        synchronize(indices: true)
    }

    mutating func advance() {
        guard bed.isTransitioning || center.isTransitioning else { return }
        bed.advance(); center.advance()
        synchronize(indices: !(bed.isTransitioning || center.isTransitioning))
    }

    private mutating func synchronize(indices: Bool) {
        for lane in 0..<12 { currentGains[lane] = bed.currentGains[lane] }
        currentGains[12] = center.currentGains[0]
        if indices { activeIndices = bed.activeIndices + (center.activeIndices.isEmpty ? [] : [12]) }
    }
}
