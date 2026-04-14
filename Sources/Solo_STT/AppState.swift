import Foundation
import Observation

@Observable
class AppState {
    var accessibilityGranted: Bool = false
    var microphoneGranted: Bool = false
    var modelState: ModelState = .notLoaded
    var selectedModel: String = UserDefaults.standard.string(forKey: "selectedModel") ?? WhisperModel.default.rawValue {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    var transcriptionLanguage: String = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "ru" {
        didSet { UserDefaults.standard.set(transcriptionLanguage, forKey: "transcriptionLanguage") }
    }
    var selectedAudioDeviceUID: String? = UserDefaults.standard.string(forKey: "selectedAudioDeviceUID") {
        didSet { UserDefaults.standard.set(selectedAudioDeviceUID, forKey: "selectedAudioDeviceUID") }
    }
    var hotkeyKeyCode: Int = {
        let stored = UserDefaults.standard.object(forKey: "hotkeyKeyCode")
        return (stored as? Int) ?? 61  // Right Option
    }() {
        didSet { UserDefaults.standard.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }
    var hotkeyIsModifier: Bool = {
        let stored = UserDefaults.standard.object(forKey: "hotkeyIsModifier")
        return (stored as? Bool) ?? true
    }() {
        didSet { UserDefaults.standard.set(hotkeyIsModifier, forKey: "hotkeyIsModifier") }
    }
    var customVocabulary: String = {
        if let stored = UserDefaults.standard.string(forKey: "customVocabulary"),
           !stored.isEmpty {
            return stored
        }
        return AppState.defaultVocabulary
    }() {
        didSet { UserDefaults.standard.set(customVocabulary, forKey: "customVocabulary") }
    }

    static let defaultVocabulary = """
    React, TypeScript, SwiftUI, macOS, iOS, Claude, Anthropic, \
    MCP, API, JSON, useState, useEffect, async, await, actor, \
    WhisperKit, Foundation Models, ANE, CoreML
    """

    static func migrateProvider(from legacy: String) -> (provider: String, cloudService: String?) {
        switch legacy {
        case "openai": return ("cloud", "openai")
        case "groq":   return ("cloud", "groq")
        case "logosStt", "customLocal", "custom": return ("customServer", nil)
        default: return (legacy, nil)
        }
    }

    static let currentMigrationVersion = 2
    private static let migrationVersionKey = "appMigrationVersion"

    func performMigrationIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: Self.migrationVersionKey)
        guard stored < Self.currentMigrationVersion else { return }

        DiagnosticLogger.shared.info(
            "Running migration from v\(stored) to v\(Self.currentMigrationVersion)",
            category: "Migration"
        )

        let oldProvider = UserDefaults.standard.string(forKey: "transcriptionProvider") ?? "local"
        let (newProvider, newCloudService) = Self.migrateProvider(from: oldProvider)
        UserDefaults.standard.set(newProvider, forKey: "transcriptionProvider")
        if let cloudService = newCloudService {
            UserDefaults.standard.set(cloudService, forKey: "cloudService")
        }

        let oldModel = UserDefaults.standard.string(forKey: "selectedModel") ?? ""
        let newModel = WhisperModel.migrateFromLegacy(oldModel)
        UserDefaults.standard.set(newModel.rawValue, forKey: "selectedModel")

        if let presets = UserDefaults.standard.array(forKey: "selectedPresets") as? [String],
           !presets.isEmpty {
            let current = UserDefaults.standard.string(forKey: "customVocabulary") ?? ""
            let merged = Self.mergeVocabulary(current: current, presetWords: presets)
            UserDefaults.standard.set(merged, forKey: "customVocabulary")
            UserDefaults.standard.removeObject(forKey: "selectedPresets")
        }

        UserDefaults.standard.set(Self.currentMigrationVersion, forKey: Self.migrationVersionKey)
        DiagnosticLogger.shared.info(
            "Migration to v\(Self.currentMigrationVersion) complete",
            category: "Migration"
        )
    }

    static func mergeVocabulary(current: String, presetWords: [String]) -> String {
        let currentWords = current
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let effective: [String]
        if currentWords.isEmpty && presetWords.isEmpty {
            effective = Self.defaultVocabulary
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            effective = currentWords
        }
        let combined = effective + presetWords
        var seen = Set<String>()
        let unique = combined.filter { w in
            let lower = w.lowercased()
            return seen.insert(lower).inserted
        }
        return unique.joined(separator: ", ")
    }
    var transcriptionProvider: String = UserDefaults.standard.string(forKey: "transcriptionProvider") ?? "local" {
        didSet { UserDefaults.standard.set(transcriptionProvider, forKey: "transcriptionProvider") }
    }
    var customEndpointURL: String = UserDefaults.standard.string(forKey: "customEndpointURL") ?? "" {
        didSet { UserDefaults.standard.set(customEndpointURL, forKey: "customEndpointURL") }
    }
    var cloudService: String = UserDefaults.standard.string(forKey: "cloudService") ?? "openai" {
        didSet { UserDefaults.standard.set(cloudService, forKey: "cloudService") }
    }
    var audioNormalization: Bool = {
        let stored = UserDefaults.standard.object(forKey: "audioNormalization")
        return (stored as? Bool) ?? true
    }() {
        didSet { UserDefaults.standard.set(audioNormalization, forKey: "audioNormalization") }
    }
    var aiCleanupEnabled: Bool = {
        let stored = UserDefaults.standard.object(forKey: "aiCleanupEnabled")
        return (stored as? Bool) ?? true
    }() {
        didSet { UserDefaults.standard.set(aiCleanupEnabled, forKey: "aiCleanupEnabled") }
    }
    var useBeamSearch: Bool = UserDefaults.standard.bool(forKey: "useBeamSearch") {
        didSet { UserDefaults.standard.set(useBeamSearch, forKey: "useBeamSearch") }
    }
    var whisperTemperature: Double = {
        let stored = UserDefaults.standard.object(forKey: "whisperTemperature")
        return (stored as? Double) ?? 0.3
    }() {
        didSet { UserDefaults.standard.set(whisperTemperature, forKey: "whisperTemperature") }
    }
    var whisperEntropyThreshold: Double = {
        let stored = UserDefaults.standard.object(forKey: "whisperEntropyThreshold")
        return (stored as? Double) ?? 2.4
    }() {
        didSet { UserDefaults.standard.set(whisperEntropyThreshold, forKey: "whisperEntropyThreshold") }
    }
    var whisperLogprobThreshold: Double = {
        let stored = UserDefaults.standard.object(forKey: "whisperLogprobThreshold")
        return (stored as? Double) ?? -1.0
    }() {
        didSet { UserDefaults.standard.set(whisperLogprobThreshold, forKey: "whisperLogprobThreshold") }
    }
    var recordingState: RecordingState = .idle
    var lastTranscription: String?
    var isSecureInputActive: Bool = false
    var insertionState: InsertionState = .idle

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    var currentProvider: TranscriptionProvider {
        // Migration from old provider values
        switch transcriptionProvider {
        case "logosStt", "customLocal", "custom":
            transcriptionProvider = "customServer"
        case "openai":
            cloudService = "openai"
            transcriptionProvider = "cloud"
        case "groq":
            cloudService = "groq"
            transcriptionProvider = "cloud"
        default:
            break
        }
        return TranscriptionProvider(rawValue: transcriptionProvider) ?? .local
    }

    var isReadyToTranscribe: Bool {
        switch currentProvider {
        case .local:
            if case .ready = modelState { return true }
            return false
        case .appleSpeech:
            return true
        case .customServer:
            return !customEndpointURL.isEmpty
        case .cloud:
            return KeychainService.load(key: cloudKeychainKey) != nil
        }
    }

    var cloudKeychainKey: String {
        "apiKey-\(cloudService)"
    }

    var allPermissionsGranted: Bool {
        accessibilityGranted && microphoneGranted
    }

    enum ModelState {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case error(String)
    }

    enum RecordingState {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    enum InsertionState {
        case idle
        case inserting
        case clipboardOnly  // secure input fallback
    }
}
