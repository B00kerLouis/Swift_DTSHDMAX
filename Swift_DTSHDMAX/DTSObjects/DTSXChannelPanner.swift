import Foundation

/// Layout-native extension of the established rectangular authoring panner.
/// Floor and height rows are normalized together before the existing per-source
/// sample-continuous gain state is applied. Cfh and Crh have independent feeds.
enum DTSXChannelPanner {
    static func gains(for state: AtmosObjectState,format: DTSXChannelFormat) -> [(outputIndex: Int,q30: Int64)] {
        guard state.active, let position = state.position else { return [] }
        let x = min(1,max(-1,Float(position.x))), y = min(1,max(-1,Float(position.y)))
        let z: Float = state.elevation ? min(1,max(0,Float(position.z))) : 0
        let canonicalFloor = DTS714VBAPPanner.diagnosticGains(x: Double(x),y: Double(y),z: 0)
        var floor = Array(repeating: Float(0),count: format.channelNames.count)
        for channel in 0..<min(8,format.bedChannelCount) { floor[channel] = Float(canonicalFloor[channel]) }
        if format.bedChannelCount == 6 {
            floor[4] = Float(canonicalFloor[4]+canonicalFloor[6])
            floor[5] = Float(canonicalFloor[5]+canonicalFloor[7])
            normalize(&floor)
        }
        let horizontal = min(1,max(0,x+0.5)) * Float.pi/2
        let left = cos(horizontal), right = sin(horizontal)
        let longitudinal = min(1,max(0,y+0.5)) * Float.pi/2
        let front = sin(longitudinal), rear = cos(longitudinal)
        let height: [Float]
        switch format {
        case .sevenOneTwoFront, .sevenOneTwoSide: height = [left,right]
        case .sevenOneThree, .fiveOneThree: height = [front*left,front*right,rear]
        case .fiveOneFive:
            // Three independent front-height anchors: left, centre, right.
            let a = min(1,abs(x)*2) * Float.pi/2
            let l = x <= 0 ? sin(a) : 0, r = x >= 0 ? sin(a) : 0
            height = [front*l,front*r,front*cos(a),rear*left,rear*right]
        case .sevenOneFour, .fiveOneFour: height = [front*left,front*right,rear*left,rear*right]
        }
        var values = floor.map { $0*(1-z) }
        for index in height.indices { values[format.bedChannelCount+index] = height[index]*z }
        normalize(&values)
        let gain = Float(pow(10,state.gain/20))*Float(DTS714ChannelMapper.renderHeadroomQ30)/Float(1 << 30)
        if state.snap,let strongest = values.indices.max(by: { values[$0] < values[$1] }) {
            values = values.indices.map { $0 == strongest ? 1 : 0 }
        }
        return values.enumerated().compactMap { index,value in
            let coefficient = Int64((Double(value*gain)*Double(1 << 30)).rounded())
            return coefficient == 0 ? nil : (index,coefficient)
        }
    }
    private static func normalize(_ values: inout [Float]) {
        let norm = sqrt(values.reduce(0) { $0+$1*$1 })
        if norm > 8*Float.ulpOfOne { for index in values.indices { values[index] /= norm } }
    }
    static func bedRoutes(for speaker: DTSSpeakerPosition,format: DTSXChannelFormat) -> [(outputIndex: Int,q30: Int64)] {
        let name = speaker == .lfe1 ? "LFE" : speaker.rawValue
        if let index = format.channelNames.firstIndex(of: name) { return [(index,DTS714ChannelMapper.renderHeadroomQ30)] }
        if format.bedChannelCount == 6 {
            if [.leftSideSurround,.leftRearSurround].contains(speaker) { return [(4,DTS714ChannelMapper.renderHeadroomQ30)] }
            if [.rightSideSurround,.rightRearSurround].contains(speaker) { return [(5,DTS714ChannelMapper.renderHeadroomQ30)] }
        }
        if speaker == .leftHeightSide || speaker == .rightHeightSide {
            var state = AtmosObjectState(elementID: 0)
            state.active = true
            state.position = AtmosPosition(x: speaker == .leftHeightSide ? -1 : 1,y: 0,z: 1)
            return gains(for: state,format: format)
        }
        // Preserve the canonical speaker mapping for legacy bed identities,
        // merging only floor destinations absent from the selected layout.
        var routes: [Int:Int64] = [:]
        for route in DTS714ChannelMapper.routes(for: speaker) {
            let source = DTS714Channel.allCases.firstIndex(of: route.channel)!
            let target = format.bedChannelCount == 6 && source >= 6 && source < 8 ? source-2 : source
            if target < format.bedChannelCount { routes[target,default: 0] += route.gainQ30 }
        }
        return routes.keys.sorted().map { ($0,routes[$0]!) }
    }
}
