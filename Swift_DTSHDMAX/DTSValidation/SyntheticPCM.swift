import Foundation

enum SyntheticPCM {
    static func deterministic(layout: DTSChannelLayout, frameCount: Int) throws -> PCMBuffer {
        guard frameCount > 0 else { throw DTSError.invalidArgument("frame count must be positive") }
        let sampleCount = frameCount * XLLSyntax.frameSampleCount
        let format = try PCMFormat(sampleRate: 48_000, bitDepth: 24, layout: layout)
        var planes = Array(repeating: [Int32](), count: layout.channelCount)
        for channel in planes.indices {
            planes[channel].reserveCapacity(sampleCount)
            var state = UInt32(0x243f_6a88) &+ UInt32(channel &* 0x9e37)
            for sample in 0..<sampleCount {
                state = state &* 1_664_525 &+ 1_013_904_223
                var value = Int32(bitPattern: state & 0x00ff_ffff)
                if (value & 0x0080_0000) != 0 { value -= 0x0100_0000 }
                switch sample {
                case 0: value = -8_388_608 + Int32(channel)
                case 1: value = 8_388_607 - Int32(channel)
                case 2: value = 0
                case 3: value = Int32(1 << (channel % 20))
                default: break
                }
                planes[channel].append(value)
            }
        }
        return try PCMBuffer(format: format, planes: planes)
    }
}
