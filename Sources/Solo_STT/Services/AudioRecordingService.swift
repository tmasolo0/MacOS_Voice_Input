import Foundation
import AVFoundation
import Accelerate
import AppKit
import os

private let audioLog = Logger(subsystem: "com.solo.stt", category: "Audio")

class AudioRecordingService {
    private var audioEngine: AVAudioEngine?
    private var audioSamples: [Float] = []
    private var recordingStartTime: Date?
    private var isCollecting = false
    private var engineReady = false
    private var isRecreating = false

    /// UID выбранного аудиоустройства (nil = системное по умолчанию)
    var selectedDeviceUID: String?

    /// Нормализовать громкость перед транскрипцией
    var normalizeAudio: Bool = true

    /// Minimum recording duration to avoid empty transcriptions
    static let minimumDuration: TimeInterval = 0.3  // 300ms

    /// Maximum recording duration to prevent memory issues
    static let maximumDuration: TimeInterval = 120.0  // 2 minutes

    /// Target format: 16kHz mono Float (required by whisper.cpp)
    private static let targetSampleRate: Double = 16000.0

    /// Grace period after key release to capture trailing audio
    static let stopDelay: TimeInterval = 0.2  // 200ms

    /// Pre-buffer duration to capture audio before hotkey press
    private static let preBufferDuration: TimeInterval = 0.3  // 300ms
    private static var preBufferSamples: Int {
        Int(targetSampleRate * preBufferDuration)
    }
    private var preBuffer: [Float] = []

    func prepareEngine() throws {
        guard !engineReady else { return }

        let engine = AVAudioEngine()

        if let uid = selectedDeviceUID {
            do {
                try AudioDeviceService.setInputDevice(uid: uid, on: engine)
            } catch {
                print("[Solo_STT] BT device unavailable (\(uid)), using default mic")
                audioLog.warning("Device \(uid) not found, using system default")
            }
        }

        let inputNode = engine.inputNode
        let outputFormat = inputNode.outputFormat(forBus: 0)

        let tapFormat = outputFormat.sampleRate > 0 ? outputFormat : nil
        let actualSampleRate = tapFormat?.sampleRate ?? Self.targetSampleRate

        guard actualSampleRate > 0 else {
            audioLog.error("Input sampleRate is 0")
            throw AudioRecordingError.noAudioCaptured
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecordingError.noAudioCaptured
        }

        let needsConversion = actualSampleRate != Self.targetSampleRate || (tapFormat?.channelCount ?? 1) != 1
        var converter: AVAudioConverter?
        if needsConversion, let tf = tapFormat {
            converter = AVAudioConverter(from: tf, to: targetFormat)
            if converter == nil {
                audioLog.error("Failed to create converter from \(tf.sampleRate)Hz to \(Self.targetSampleRate)Hz")
                throw AudioRecordingError.noAudioCaptured
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let samples: [Float]

            if let converter = converter {
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * Self.targetSampleRate / actualSampleRate
                )
                guard frameCount > 0 else { return }

                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                    return
                }

                var convError: NSError?
                let status = converter.convert(to: convertedBuffer, error: &convError) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .error || convError != nil {
                    return
                }

                guard let channelData = convertedBuffer.floatChannelData else { return }
                let outFrames = Int(convertedBuffer.frameLength)
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: outFrames))
            } else {
                guard let channelData = buffer.floatChannelData else { return }
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            }

            if self.isCollecting {
                self.audioSamples.append(contentsOf: samples)
            } else {
                self.preBuffer.append(contentsOf: samples)
                if self.preBuffer.count > Self.preBufferSamples {
                    self.preBuffer.removeFirst(self.preBuffer.count - Self.preBufferSamples)
                }
            }
        }

        try engine.start()
        audioEngine = engine
        engineReady = true
        audioLog.info("Audio engine started (\(outputFormat.sampleRate)Hz/\(outputFormat.channelCount)ch)")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    enum EngineError: LocalizedError {
        case prepareFailed(String)
        var errorDescription: String? {
            switch self {
            case .prepareFailed(let msg): return "Audio engine: \(msg)"
            }
        }
    }

    @discardableResult
    func ensureEngineRunning() -> Error? {
        if engineReady && audioEngine?.isRunning == true { return nil }
        audioLog.warning("Engine not running, recreating")
        return recreateEngine()
    }

    func startRecording() throws {
        if !engineReady || audioEngine?.isRunning != true {
            audioLog.warning("Engine not running at startRecording, recreating")
            if let err = recreateEngine() { throw err }
        }

        audioSamples = preBuffer
        preBuffer = []
        isCollecting = true
        recordingStartTime = Date()
    }

    func stopRecording() -> AudioRecordingResult {
        guard engineReady else {
            return .error(.noAudioCaptured)
        }

        isCollecting = false

        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        if duration < Self.minimumDuration {
            audioSamples = []
            return .tooShort(duration: duration)
        }

        var samples = audioSamples
        audioSamples = []

        if samples.isEmpty {
            audioLog.error("No audio samples after \(String(format: "%.1f", duration))s")
            return .error(.noAudioCaptured)
        }

        if normalizeAudio {
            samples = Self.normalize(samples)
        }

        return .success(samples: samples, duration: duration)
    }

    // MARK: - Audio Normalization

    /// RMS-нормализация: подтягивает тихий сигнал до целевого уровня
    private static func normalize(_ samples: [Float], targetRMS: Float = 0.1) -> [Float] {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        guard rms > 1e-6 else { return samples }  // тишина — не трогать
        let gain = min(targetRMS / rms, 10.0)      // макс. усиление 10x (20dB)
        guard gain > 1.05 else { return samples }   // уже нормально — не трогать
        var result = [Float](repeating: 0, count: samples.count)
        var g = gain
        vDSP_vsmul(samples, 1, &g, &result, 1, vDSP_Length(samples.count))
        // клиппинг защита
        var lo: Float = -1.0, hi: Float = 1.0
        vDSP_vclip(result, 1, &lo, &hi, &result, 1, vDSP_Length(samples.count))
        audioLog.info("Audio normalized: RMS \(String(format: "%.4f", rms)) → gain \(String(format: "%.1f", gain))x")
        return result
    }

    // MARK: - Route Change & Wake Handling

    @objc private func handleConfigurationChange(_ notification: Notification) {
        guard !isRecreating, !isCollecting else { return }

        // Only recreate if the engine actually stopped
        if audioEngine?.isRunning == true {
            audioLog.info("Audio config changed but engine still running, ignoring")
            return
        }

        audioLog.warning("Audio config changed, engine stopped — recreating")
        recreateEngine()
    }

    @objc private func handleSystemWake(_ notification: Notification) {
        audioLog.info("System woke up, checking engine")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.isCollecting else { return }
            if self.engineReady && self.audioEngine?.isRunning == true {
                audioLog.info("Engine still running after wake, no action needed")
                return
            }
            audioLog.warning("Engine not running after wake, recreating")
            self.recreateEngine()
        }
    }

    @discardableResult
    func recreateEngine() -> Error? {
        guard !isCollecting else { return nil }
        isRecreating = true
        shutdown()
        do {
            try prepareEngine()
            isRecreating = false
            audioLog.info("Engine recreated successfully")
            return nil
        } catch {
            isRecreating = false
            audioLog.error("Failed to recreate engine: \(error.localizedDescription)")
            return error
        }
    }

    func shutdown() {
        isCollecting = false
        if let engine = audioEngine {
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        audioEngine = nil
        engineReady = false
        audioSamples = []
        preBuffer = []
        audioLog.info("Audio engine stopped")
    }

    enum AudioRecordingResult {
        case success(samples: [Float], duration: TimeInterval)
        case tooShort(duration: TimeInterval)
        case error(AudioRecordingError)
    }

    enum AudioRecordingError: LocalizedError {
        case noAudioCaptured

        var errorDescription: String? {
            switch self {
            case .noAudioCaptured: return "Аудио не записано"
            }
        }
    }
}
