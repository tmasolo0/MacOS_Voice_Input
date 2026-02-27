import Foundation
import os

final class DiagnosticLogger {
    static let shared = DiagnosticLogger()

    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    struct Entry {
        let timestamp: Date
        let level: Level
        let category: String
        let message: String
    }

    private let lock = NSLock()
    private var buffer: [Entry] = []
    private static let bufferLimit = 500
    private static let maxSessionFiles = 5

    private let osLog = Logger(subsystem: "com.solo.stt", category: "App")
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var sessionFileURL: URL?

    private init() {
        sessionFileURL = createSessionFile()
        rotateLogs()
    }

    // MARK: - Public API

    func info(_ message: String, category: String = "General") {
        log(level: .info, category: category, message: message)
    }

    func warning(_ message: String, category: String = "General") {
        log(level: .warning, category: category, message: message)
    }

    func error(_ message: String, category: String = "General") {
        log(level: .error, category: category, message: message)
    }

    // MARK: - Diagnostic Summary

    func diagnosticSummary(appState: AppState) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let provider = appState.currentProvider.displayName

        var lines: [String] = []
        lines.append("=== Solo STT Diagnostic Report ===")
        lines.append("Version: \(version) (\(build))")
        lines.append("macOS: \(osVersion)")
        lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("--- Permissions ---")
        lines.append("Accessibility: \(appState.accessibilityGranted ? "granted" : "NOT granted")")
        lines.append("Microphone: \(appState.microphoneGranted ? "granted" : "NOT granted")")
        lines.append("")
        lines.append("--- Configuration ---")
        lines.append("Provider: \(provider)")
        lines.append("Language: \(appState.transcriptionLanguage)")
        if appState.currentProvider == .local {
            lines.append("Model: \(appState.selectedModel)")
            lines.append("Model state: \(modelStateString(appState.modelState))")
            lines.append("Beam search: \(appState.useBeamSearch)")
        }
        lines.append("Audio device: \(appState.selectedAudioDeviceUID ?? "system default")")
        lines.append("Normalization: \(appState.audioNormalization)")
        lines.append("Hotkey: \(HotkeyService.keyName(for: appState.hotkeyKeyCode, isModifier: appState.hotkeyIsModifier))")
        lines.append("")
        lines.append("--- Recent Log (last 30 entries) ---")

        lock.lock()
        let recent = buffer.suffix(30)
        lock.unlock()

        for entry in recent {
            lines.append("[\(dateFormatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Paths

    static var logsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Solo_STT/logs")
    }

    // MARK: - Private

    private func log(level: Level, category: String, message: String) {
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)

        lock.lock()
        buffer.append(entry)
        if buffer.count > Self.bufferLimit {
            buffer.removeFirst(buffer.count - Self.bufferLimit)
        }
        lock.unlock()

        // Write to file
        let line = "[\(dateFormatter.string(from: entry.timestamp))] [\(level.rawValue)] [\(category)] \(message)\n"
        if let url = sessionFileURL, let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }

        // Duplicate to os_log
        switch level {
        case .info:
            osLog.info("[\(category)] \(message)")
        case .warning:
            osLog.warning("[\(category)] \(message)")
        case .error:
            osLog.error("[\(category)] \(message)")
        }
    }

    private func createSessionFile() -> URL? {
        let dir = Self.logsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "session-\(formatter.string(from: Date())).log"
        let url = dir.appendingPathComponent(name)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func rotateLogs() {
        let dir = Self.logsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])
            .filter({ $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "log" })
            .sorted(by: { ($0.lastPathComponent) > ($1.lastPathComponent) })
        else { return }

        if files.count > Self.maxSessionFiles {
            for file in files.dropFirst(Self.maxSessionFiles) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func modelStateString(_ state: AppState.ModelState) -> String {
        switch state {
        case .notLoaded: return "not loaded"
        case .downloading(let p): return "downloading \(Int(p * 100))%"
        case .loading: return "loading"
        case .ready: return "ready"
        case .error(let msg): return "error: \(msg)"
        }
    }
}
