import Foundation
import AVFAudio
import Observation

@Observable
@MainActor
final class AudioLevelMonitor {
    var levelHistory: [Float] = Array(repeating: 0, count: 15)

    func update(from buffer: AVAudioPCMBuffer) {
        let rms = Self.calculateRMS(buffer)
        let normalized = min(1.0, Float(log10(1 + rms * 100) / 2))
        levelHistory.removeFirst()
        levelHistory.append(normalized)
    }

    func reset() {
        levelHistory = Array(repeating: 0, count: 15)
    }

    static func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return sqrt(sum / Float(count))
    }
}
