import XCTest
import AVFAudio
@testable import Solo_STT

final class AudioLevelMonitorTests: XCTestCase {
    @MainActor
    func testSilentBufferGivesZeroLevel() {
        let monitor = AudioLevelMonitor()
        let buffer = makeBuffer(samples: Array(repeating: Float(0), count: 1024))
        monitor.update(from: buffer)
        XCTAssertEqual(monitor.levelHistory.last ?? -1, 0, accuracy: 0.001)
    }

    @MainActor
    func testLoudBufferGivesHighLevel() {
        let monitor = AudioLevelMonitor()
        let samples = Array(repeating: Float(0.9), count: 1024)
        let buffer = makeBuffer(samples: samples)
        monitor.update(from: buffer)
        let last = monitor.levelHistory.last ?? 0
        XCTAssertGreaterThan(last, 0.5)
        XCTAssertLessThanOrEqual(last, 1.0)
    }

    @MainActor
    func testHistoryKeepsLast15() {
        let monitor = AudioLevelMonitor()
        let buffer = makeBuffer(samples: Array(repeating: Float(0.5), count: 1024))
        for _ in 0..<20 {
            monitor.update(from: buffer)
        }
        XCTAssertEqual(monitor.levelHistory.count, 15)
    }

    private func makeBuffer(samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for (i, v) in samples.enumerated() { channelData[i] = v }
        return buffer
    }
}
