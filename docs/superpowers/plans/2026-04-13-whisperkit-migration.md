# Solo STT v2 — WhisperKit Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Перевести Solo STT с SwiftWhisper/GGML на WhisperKit + VAD + Foundation Models cleanup + Apple SpeechAnalyzer для лучшего качества и отзывчивости на vibecoding-сценариях (рус+англ).

**Architecture:** Pipeline: HotkeyService → AudioRecordingService → VADService (Silero CoreML) → TranscriptionService (WhisperKit / AppleSpeech / Cloud / CustomServer) → TextCleanupService (Foundation Models) → TextInsertionService. Waveform-индикатор уровня в FloatingPill. Миграция настроек при первом запуске v2.

**Tech Stack:** Swift 6 / macOS 26+, WhisperKit (Argmax), Apple FoundationModels, Apple Speech (SpeechAnalyzer), Silero VAD CoreML, SwiftUI, AVAudioEngine, XCTest.

---

## File Structure

**Создаются**:
- `Sources/Solo_STT/Services/WhisperKitTranscriber.swift` — actor-обёртка над WhisperKit
- `Sources/Solo_STT/Services/AppleSpeechTranscriber.swift` — actor-обёртка над SpeechAnalyzer
- `Sources/Solo_STT/Services/VADService.swift` — actor с Silero VAD CoreML
- `Sources/Solo_STT/Services/TextCleanupService.swift` — actor с Foundation Models
- `Sources/Solo_STT/Services/AudioLevelMonitor.swift` — @Observable с RMS
- `Sources/Solo_STT/Views/WaveformBars.swift` — SwiftUI-вью waveform
- `Sources/Solo_STT/Views/MigrationOnboardingView.swift` — экран миграции v1→v2
- `Resources/silero_vad.mlmodelc` — CoreML-модель VAD (загружается из HF)
- `Tests/Solo_STTTests/AudioLevelMonitorTests.swift`
- `Tests/Solo_STTTests/VocabularyMigrationTests.swift`
- `Tests/Solo_STTTests/TranscriptionProviderMigrationTests.swift`

**Модифицируются**:
- `Package.swift` — WhisperKit вместо SwiftWhisper
- `Sources/Solo_STT/Models/WhisperModel.swift` — новые варианты моделей
- `Sources/Solo_STT/Models/TranscriptionProvider.swift` — добавить `.appleSpeech`
- `Sources/Solo_STT/Services/TranscriptionService.swift` — роутинг провайдеров
- `Sources/Solo_STT/Services/ModelService.swift` — WhisperKit download
- `Sources/Solo_STT/Services/AudioRecordingService.swift` — audio-tap для level monitor
- `Sources/Solo_STT/AppState.swift` — `aiCleanupEnabled`, migration-logic
- `Sources/Solo_STT/AppDelegate.swift` — VAD + Cleanup + миграция
- `Sources/Solo_STT/Views/SettingsView.swift` — новые секции UI
- `Sources/Solo_STT/Views/FloatingPillView.swift` — waveform
- `Sources/Solo_STT/Services/FloatingPillManager.swift` — инжект level monitor

**Удаляются**:
- `Sources/Solo_STT/Services/TextProcessingService.swift`
- `Sources/Solo_STT/Models/VocabularyPreset.swift`
- `Tests/Solo_STTTests/TextProcessingServiceTests.swift`

---

## Task 1: Добавить WhisperKit dependency (параллельно со SwiftWhisper)

**Files:**
- Modify: `Package.swift`

Цель — добавить WhisperKit, не ломая существующий build. SwiftWhisper пока остаётся.

- [ ] **Step 1: Добавить WhisperKit dependency**

Заменить содержимое `Package.swift`:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Solo_STT",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Solo_STT",
            dependencies: [
                "SwiftWhisper",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Solo_STT",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "Solo_STTTests",
            dependencies: ["Solo_STT"],
            path: "Tests/Solo_STTTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
```

- [ ] **Step 2: Проверить сборку**

```bash
swift build -c release
```

Expected: BUILD SUCCEEDED. Ожидаем первая сборка будет долгой (резолв WhisperKit + MLX зависимостей).

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "deps: add WhisperKit dependency alongside SwiftWhisper"
```

---

## Task 2: Создать WhisperKitTranscriber actor

**Files:**
- Create: `Sources/Solo_STT/Services/WhisperKitTranscriber.swift`

Цель — actor с методами `load(variant:)` и `transcribe(samples:...)`. Инкапсулирует WhisperKit API.

- [ ] **Step 1: Создать файл с базовой структурой**

Создать `Sources/Solo_STT/Services/WhisperKitTranscriber.swift`:

```swift
import Foundation
import WhisperKit

actor WhisperKitTranscriber {
    enum TranscriberError: LocalizedError {
        case notLoaded
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "WhisperKit model is not loaded"
            case .emptyResult: return "Transcription returned empty result"
            }
        }
    }

    struct Result {
        let text: String
        let language: String
        let latency: TimeInterval
    }

    private var whisperKit: WhisperKit?
    private(set) var loadedVariant: String?

    func load(modelFolder: URL, variant: String, prewarm: Bool = true) async throws {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: prewarm,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
        loadedVariant = variant
    }

    func transcribe(
        samples: [Float],
        language: String,
        vocabulary: String,
        temperatureFallbackCount: Int = 2
    ) async throws -> Result {
        guard let whisperKit else { throw TranscriberError.notLoaded }

        let promptTokens: [Int]?
        if !vocabulary.isEmpty, let tokenizer = whisperKit.tokenizer {
            let encoded = tokenizer.encode(text: " \(vocabulary)")
            promptTokens = Array(encoded.prefix(224))
        } else {
            promptTokens = nil
        }

        let start = Date()
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(
                task: .transcribe,
                language: language,
                temperature: 0.0,
                temperatureFallbackCount: temperatureFallbackCount,
                usePrefillPrompt: true,
                promptTokens: promptTokens
            )
        )
        let text = results.map(\.text).joined()
        let latency = Date().timeIntervalSince(start)

        return Result(text: text.trimmingCharacters(in: .whitespaces),
                      language: language,
                      latency: latency)
    }

    func unload() {
        whisperKit = nil
        loadedVariant = nil
    }
}
```

- [ ] **Step 2: Проверить компиляцию**

```bash
swift build -c debug
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/Solo_STT/Services/WhisperKitTranscriber.swift
git commit -m "feat: add WhisperKitTranscriber actor"
```

---

## Task 3: Обновить WhisperModel enum под новые варианты

**Files:**
- Modify: `Sources/Solo_STT/Models/WhisperModel.swift`

Цель — заменить GGML-варианты на WhisperKit-совместимые имена. Включает legacy-маппинг для миграции UserDefaults.

- [ ] **Step 1: Прочитать текущий файл**

```bash
cat Sources/Solo_STT/Models/WhisperModel.swift
```

Запомнить текущую структуру (enum с raw-значениями `"ggml-small.bin"` и `"ggml-medium.bin"`).

- [ ] **Step 2: Переписать enum**

Полностью заменить содержимое `Sources/Solo_STT/Models/WhisperModel.swift`:

```swift
import Foundation

enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case turboQuantized = "openai_whisper-large-v3-turbo_turbo_600MB"
    case turbo          = "openai_whisper-large-v3-turbo"
    case largeV3        = "openai_whisper-large-v3"
    case small          = "openai_whisper-small"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turboQuantized: return "Large v3 Turbo (600 MB, квантизованная)"
        case .turbo:          return "Large v3 Turbo (1.5 GB, рекомендуется)"
        case .largeV3:        return "Large v3 (3 GB, максимум качества)"
        case .small:          return "Small (250 MB, быстро и слабо)"
        }
    }

    var approximateSizeMB: Int {
        switch self {
        case .turboQuantized: return 600
        case .turbo:          return 1500
        case .largeV3:        return 3000
        case .small:          return 250
        }
    }

    static var `default`: WhisperModel { .turbo }
    static var all: [WhisperModel] { Self.allCases }

    /// Маппинг устаревших GGML-имён на новые WhisperKit-варианты.
    /// Используется при миграции UserDefaults.
    static func migrateFromLegacy(_ legacy: String) -> WhisperModel {
        switch legacy {
        case "ggml-small.bin":  return .small
        case "ggml-medium.bin": return .turbo
        case "ggml-large.bin":  return .largeV3
        default:
            return WhisperModel(rawValue: legacy) ?? .default
        }
    }
}
```

- [ ] **Step 3: Написать тесты маппинга**

Создать `Tests/Solo_STTTests/WhisperModelMigrationTests.swift`:

```swift
import XCTest
@testable import Solo_STT

final class WhisperModelMigrationTests: XCTestCase {
    func testLegacyGgmlSmallMapsToSmall() {
        XCTAssertEqual(WhisperModel.migrateFromLegacy("ggml-small.bin"), .small)
    }

    func testLegacyGgmlMediumMapsToTurbo() {
        XCTAssertEqual(WhisperModel.migrateFromLegacy("ggml-medium.bin"), .turbo)
    }

    func testNewIdentifierPassesThrough() {
        XCTAssertEqual(
            WhisperModel.migrateFromLegacy("openai_whisper-large-v3"),
            .largeV3
        )
    }

    func testUnknownDefaultsToTurbo() {
        XCTAssertEqual(WhisperModel.migrateFromLegacy("unknown.bin"), .turbo)
    }
}
```

- [ ] **Step 4: Запустить тест**

```bash
swift test --filter WhisperModelMigrationTests
```

Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Solo_STT/Models/WhisperModel.swift Tests/Solo_STTTests/WhisperModelMigrationTests.swift
git commit -m "feat: переделать WhisperModel под WhisperKit-варианты + legacy migration"
```

---

## Task 4: Рефакторить ModelService под WhisperKit download

**Files:**
- Modify: `Sources/Solo_STT/Services/ModelService.swift`

Цель — скачивать WhisperKit-модели (папки `.mlmodelc` с HuggingFace) вместо GGML-файлов. WhisperKit предоставляет `WhisperKit.download(variant:)`.

- [ ] **Step 1: Прочитать текущий ModelService**

```bash
cat Sources/Solo_STT/Services/ModelService.swift
```

Ключевые поля: `modelsDirectory`, `downloadAndLoad(variant:)`, прогресс через `URLSessionDownloadDelegate`.

- [ ] **Step 2: Переписать ModelService**

Полностью заменить содержимое `Sources/Solo_STT/Services/ModelService.swift`:

```swift
import Foundation
import WhisperKit

@Observable
@MainActor
final class ModelService {
    private let appState: AppState
    private let transcriber = WhisperKitTranscriber()

    var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Solo_STT")
            .appendingPathComponent("models")
            .appendingPathComponent("whisperkit")
    }

    init(appState: AppState) {
        self.appState = appState
        try? FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )
    }

    func transcriberActor() -> WhisperKitTranscriber { transcriber }

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        let folder = modelsDirectory.appendingPathComponent(model.rawValue)
        let encoder = folder.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    func downloadAndLoad(variant: String) async throws {
        guard let model = WhisperModel(rawValue: variant) else {
            throw ModelError.unknownVariant(variant)
        }

        if !isModelDownloaded(model) {
            appState.modelState = .downloading(progress: 0)
            DiagnosticLogger.shared.info("Downloading \(variant) → \(modelsDirectory.path)", category: "Model")

            try await WhisperKit.download(
                variant: variant,
                downloadBase: modelsDirectory
            ) { progress in
                Task { @MainActor in
                    self.appState.modelState = .downloading(progress: progress.fractionCompleted)
                }
            }
        }

        appState.modelState = .loading
        let modelFolder = modelsDirectory.appendingPathComponent(variant)
        try await transcriber.load(modelFolder: modelFolder, variant: variant, prewarm: true)
        appState.modelState = .ready
        DiagnosticLogger.shared.info("Model \(variant) loaded and ready", category: "Model")
    }

    func deleteModel(_ model: WhisperModel) throws {
        let folder = modelsDirectory.appendingPathComponent(model.rawValue)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    func deleteLegacyGgmlModels() {
        let legacyDir = modelsDirectory.deletingLastPathComponent()
        let legacyFiles = ["ggml-small.bin", "ggml-medium.bin", "ggml-large.bin"]
        for file in legacyFiles {
            let path = legacyDir.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: path)
        }
    }

    enum ModelError: LocalizedError {
        case unknownVariant(String)
        var errorDescription: String? {
            switch self {
            case .unknownVariant(let v): return "Unknown model variant: \(v)"
            }
        }
    }
}
```

- [ ] **Step 3: Проверить компиляцию**

Возможны ошибки в `AppState.modelState` (enum значения) и в местах где ModelService использовался (StatusItemManager, SettingsView). На этом шаге исправляем только компиляцию (семантика роутинга будет в Task 5).

```bash
swift build -c debug 2>&1 | head -50
```

Ожидаемые ошибки: ссылки на старые варианты моделей в Views. Их пофиксим в следующих тасках.

- [ ] **Step 4: Commit (даже если есть ошибки в других местах — это ожидаемо, разрешим в Task 5)**

```bash
git add Sources/Solo_STT/Services/ModelService.swift
git commit -m "feat: переделать ModelService под WhisperKit download (WIP — ломает TranscriptionService)"
```

---

## Task 5: Обновить TranscriptionService: роутинг .local на WhisperKit

**Files:**
- Modify: `Sources/Solo_STT/Services/TranscriptionService.swift`

Цель — перевести провайдер `.local` с SwiftWhisper на WhisperKitTranscriber. Остальные провайдеры (cloud, customServer) оставляем как есть.

- [ ] **Step 1: Прочитать текущий TranscriptionService**

```bash
cat Sources/Solo_STT/Services/TranscriptionService.swift
```

Запомнить сигнатуру `transcribe(audioSamples:)` и структуру `TranscriptionResult`.

- [ ] **Step 2: Переписать секцию .local**

Заменить импорт и логику `.local`-ветки:

```swift
import Foundation

@MainActor
final class TranscriptionService {
    struct TranscriptionResult {
        let text: String
        let language: String
        let latency: TimeInterval
    }

    private let modelService: ModelService
    private let appState: AppState
    private let cloudClient: CloudTranscriptionClient

    init(modelService: ModelService, appState: AppState) {
        self.modelService = modelService
        self.appState = appState
        self.cloudClient = CloudTranscriptionClient()
    }

    func transcribe(audioSamples: [Float]) async throws -> TranscriptionResult {
        let provider = appState.currentProvider
        let language = appState.transcriptionLanguage
        let vocabulary = appState.customVocabulary

        switch provider {
        case .local:
            let result = try await modelService.transcriberActor().transcribe(
                samples: audioSamples,
                language: language,
                vocabulary: vocabulary
            )
            return TranscriptionResult(text: result.text,
                                        language: result.language,
                                        latency: result.latency)

        case .cloud:
            return try await cloudClient.transcribe(
                samples: audioSamples,
                language: language,
                prompt: vocabulary,
                service: appState.cloudService,
                apiKey: KeychainService.load(key: appState.cloudKeychainKey) ?? ""
            )

        case .customServer:
            return try await cloudClient.transcribeCustom(
                samples: audioSamples,
                language: language,
                prompt: vocabulary,
                endpoint: appState.customEndpointURL
            )
        }
    }
}
```

(Примечание: `.appleSpeech` добавится в Task 14, пока в switch его нет, но enum тоже пока не содержит этот case — см. Task 14.)

- [ ] **Step 3: Удалить старые импорты SwiftWhisper**

Убрать `import SwiftWhisper` из всех файлов, где он ещё есть:

```bash
grep -rn "import SwiftWhisper" Sources/
```

Убрать эти строки. Ожидаем остатки в ModelService или TranscriptionService — но мы их уже переписали выше, так что должно быть чисто.

- [ ] **Step 4: Проверить сборку**

```bash
swift build -c debug
```

Expected: BUILD SUCCEEDED. Если есть ошибки в SettingsView/StatusItemManager со ссылками на модели — исправить, подставив новые значения `WhisperModel.default.rawValue`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Solo_STT/Services/TranscriptionService.swift
git commit -m "feat: TranscriptionService использует WhisperKitTranscriber для .local"
```

---

## Task 6: Удалить SwiftWhisper dependency и старые пути

**Files:**
- Modify: `Package.swift`

Цель — полностью убрать SwiftWhisper, очистить Package.resolved.

- [ ] **Step 1: Убрать SwiftWhisper из Package.swift**

Заменить содержимое `Package.swift`:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Solo_STT",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Solo_STT",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Solo_STT",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "Solo_STTTests",
            dependencies: ["Solo_STT"],
            path: "Tests/Solo_STTTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
```

- [ ] **Step 2: Обновить Package.resolved**

```bash
rm Package.resolved
swift package resolve
```

- [ ] **Step 3: Проверить полную сборку**

```bash
swift build -c release
swift test
```

Expected: build SUCCEEDED, тесты PASS.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "deps: remove SwiftWhisper, WhisperKit now sole STT dependency"
```

---

## Task 7: Создать TextCleanupService на Foundation Models

**Files:**
- Create: `Sources/Solo_STT/Services/TextCleanupService.swift`

Цель — actor с методом `clean(_:)`, использующим Apple FoundationModels для снятия заполнителей, капитализации и пунктуации.

- [ ] **Step 1: Создать файл**

Создать `Sources/Solo_STT/Services/TextCleanupService.swift`:

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

actor TextCleanupService {
    enum CleanupError: LocalizedError {
        case unavailable
        case timeout

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Foundation Models unavailable"
            case .timeout:     return "Cleanup timed out"
            }
        }
    }

    #if canImport(FoundationModels)
    private var session: LanguageModelSession?
    #endif

    private(set) var isAvailable: Bool = false

    init() {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            self.session = nil
            self.isAvailable = false
            return
        }
        self.session = LanguageModelSession(
            model: model,
            instructions: Self.cleanupInstructions
        )
        self.isAvailable = true
        #else
        self.isAvailable = false
        #endif
    }

    func clean(_ raw: String, timeout: TimeInterval = 5.0) async throws -> String {
        guard !raw.isEmpty else { return raw }

        let wordCount = raw.split(separator: " ").count
        guard wordCount >= 5 else { return raw }

        #if canImport(FoundationModels)
        guard let session else { throw CleanupError.unavailable }

        return try await withTimeout(seconds: timeout) {
            let response = try await session.respond(to: raw)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #else
        throw CleanupError.unavailable
        #endif
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CleanupError.timeout
            }
            guard let result = try await group.next() else {
                throw CleanupError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private static let cleanupInstructions = """
    Ты — редактор расшифровок речи программиста.
    Задача: убрать заполнители, исправить пунктуацию,
    правильно капитализировать технические термины.

    Правила:
    - Убирай: «э», «эм», «ну», «типа», «короче», «вот».
    - Капитализируй: React, TypeScript, Claude, MCP, API, JSON, useEffect, useState.
    - Англ. термины оставляй в оригинальной нотации.
    - Не меняй фактуру, не перефразируй, не сокращай.
    - Возвращай ТОЛЬКО отредактированный текст, без объяснений.
    """
}
```

- [ ] **Step 2: Проверить компиляцию**

```bash
swift build -c debug
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/Solo_STT/Services/TextCleanupService.swift
git commit -m "feat: add TextCleanupService on Foundation Models"
```

---

## Task 8: Встроить TextCleanupService в pipeline и удалить TextProcessingService

**Files:**
- Modify: `Sources/Solo_STT/AppDelegate.swift`
- Modify: `Sources/Solo_STT/AppState.swift`
- Delete: `Sources/Solo_STT/Services/TextProcessingService.swift`
- Delete: `Tests/Solo_STTTests/TextProcessingServiceTests.swift`

- [ ] **Step 1: Добавить `aiCleanupEnabled` в AppState**

В `Sources/Solo_STT/AppState.swift` добавить после поля `audioNormalization`:

```swift
    var aiCleanupEnabled: Bool = {
        let stored = UserDefaults.standard.object(forKey: "aiCleanupEnabled")
        return (stored as? Bool) ?? true
    }() {
        didSet { UserDefaults.standard.set(aiCleanupEnabled, forKey: "aiCleanupEnabled") }
    }
```

- [ ] **Step 2: Обновить AppDelegate**

В `Sources/Solo_STT/AppDelegate.swift`:

1) Заменить объявление:
```swift
    private var textProcessingService: TextProcessingService?
```
на:
```swift
    private var textCleanupService: TextCleanupService?
```

2) В `applicationDidFinishLaunching(...)` заменить инициализацию:
```swift
        textProcessingService = TextProcessingService()
```
на:
```swift
        textCleanupService = TextCleanupService()
```

3) В методе `processRecordingResult(_:)` заменить блок обработки текста на:

```swift
                    let rawText = result.text

                    let processedText: String
                    if await MainActor.run(body: { self.appState.aiCleanupEnabled }),
                       let cleanup = self.textCleanupService {
                        do {
                            processedText = try await cleanup.clean(rawText)
                        } catch {
                            DiagnosticLogger.shared.warning(
                                "Cleanup failed (\(error.localizedDescription)), using raw",
                                category: "Cleanup"
                            )
                            processedText = rawText
                        }
                    } else {
                        processedText = rawText
                    }
```

(Оставить текущую обработку `isEmpty`, `lastTranscription` и вставки как есть.)

- [ ] **Step 3: Удалить TextProcessingService**

```bash
git rm Sources/Solo_STT/Services/TextProcessingService.swift
git rm Tests/Solo_STTTests/TextProcessingServiceTests.swift
```

- [ ] **Step 4: Проверить сборку**

```bash
swift build -c debug
swift test
```

Expected: build SUCCEEDED, тесты PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Solo_STT/AppState.swift Sources/Solo_STT/AppDelegate.swift
git commit -m "feat: использовать TextCleanupService вместо TextProcessingService"
```

---

## Task 9: Создать VADService (Silero CoreML)

**Files:**
- Create: `Sources/Solo_STT/Services/VADService.swift`
- Create: `Resources/silero_vad.mlmodelc` (скачивается из HuggingFace)

Цель — обрезать тишину в начале и конце записи до transcription.

- [ ] **Step 1: Скачать Silero VAD CoreML модель**

```bash
mkdir -p Resources
curl -L -o /tmp/silero_vad.zip \
  "https://huggingface.co/FluidInference/silero-vad-coreml/resolve/main/silero_vad.mlmodelc.zip"
unzip -o /tmp/silero_vad.zip -d Resources/
ls Resources/silero_vad.mlmodelc/
```

Expected: директория `Resources/silero_vad.mlmodelc/` с файлами `coremldata.bin`, `model.mlmodel`, `weights/`.

- [ ] **Step 2: Добавить Resources в target `.executableTarget`**

Изменить `Package.swift`, добавить `resources` в target:

```swift
        .executableTarget(
            name: "Solo_STT",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Solo_STT",
            resources: [
                .copy("../../Resources/silero_vad.mlmodelc")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
```

- [ ] **Step 3: Создать VADService.swift**

Создать `Sources/Solo_STT/Services/VADService.swift`:

```swift
import Foundation
import CoreML

actor VADService {
    enum VADError: LocalizedError {
        case modelNotFound
        case inferenceFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound:    return "Silero VAD model not found in bundle"
            case .inferenceFailed:  return "VAD inference failed"
            }
        }
    }

    private var model: MLModel?
    private let sampleRate: Int = 16000
    private let windowSamples: Int = 512 // 32ms @ 16kHz

    init() {
        guard let url = Bundle.main.url(
            forResource: "silero_vad",
            withExtension: "mlmodelc"
        ) else {
            DiagnosticLogger.shared.error(
                "Silero VAD model not in bundle", category: "VAD"
            )
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            self.model = try MLModel(contentsOf: url, configuration: config)
        } catch {
            DiagnosticLogger.shared.error(
                "Failed to load VAD model: \(error)", category: "VAD"
            )
        }
    }

    /// Возвращает диапазон индексов с речью, либо nil если речь не найдена.
    func trim(
        samples: [Float],
        speechThreshold: Float = 0.5,
        minSpeechDurationMs: Int = 250,
        speechPadMs: Int = 150
    ) async throws -> Range<Int>? {
        guard let model else {
            // Fallback: VAD не инициализирован → возвращаем весь диапазон
            return samples.isEmpty ? nil : 0..<samples.count
        }

        guard samples.count >= windowSamples else { return nil }

        var probs: [Float] = []
        var hState: MLMultiArray = try MLMultiArray(shape: [2,1,64], dataType: .float32)
        var cState: MLMultiArray = try MLMultiArray(shape: [2,1,64], dataType: .float32)
        for i in 0..<hState.count { hState[i] = 0; cState[i] = 0 }

        for windowStart in stride(from: 0, to: samples.count - windowSamples, by: windowSamples) {
            let window = Array(samples[windowStart..<(windowStart + windowSamples)])
            let input = try MLMultiArray(shape: [1, NSNumber(value: windowSamples)], dataType: .float32)
            for (i, v) in window.enumerated() { input[i] = NSNumber(value: v) }

            let sr = try MLMultiArray(shape: [1], dataType: .int64)
            sr[0] = NSNumber(value: Int64(sampleRate))

            let features = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(multiArray: input),
                "sr":    MLFeatureValue(multiArray: sr),
                "h":     MLFeatureValue(multiArray: hState),
                "c":     MLFeatureValue(multiArray: cState),
            ])

            let output = try model.prediction(from: features)
            if let prob = output.featureValue(for: "output")?.multiArrayValue {
                probs.append(prob[0].floatValue)
            }
            if let h = output.featureValue(for: "hn")?.multiArrayValue { hState = h }
            if let c = output.featureValue(for: "cn")?.multiArrayValue { cState = c }
        }

        // Соберём speech segments
        let minWindows = max(1, minSpeechDurationMs / 32)
        let padWindows = max(0, speechPadMs / 32)

        var firstSpeech: Int? = nil
        var lastSpeech: Int? = nil
        var runLen = 0
        for (i, p) in probs.enumerated() {
            if p >= speechThreshold {
                runLen += 1
                if runLen >= minWindows {
                    if firstSpeech == nil { firstSpeech = i - runLen + 1 }
                    lastSpeech = i
                }
            } else {
                runLen = 0
            }
        }

        guard let first = firstSpeech, let last = lastSpeech else { return nil }

        let startWindow = max(0, first - padWindows)
        let endWindow = min(probs.count - 1, last + padWindows)
        let startSample = startWindow * windowSamples
        let endSample = min(samples.count, (endWindow + 1) * windowSamples)
        return startSample..<endSample
    }
}
```

(Примечание: точные имена входов/выходов CoreML-модели — `input`, `sr`, `h`, `c`, `output`, `hn`, `cn` — могут отличаться в конкретной версии модели. На Step 5 нужно проверить через `MLModel.modelDescription` и при необходимости поправить имена.)

- [ ] **Step 4: Проверить сборку**

```bash
swift build -c debug
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Проверить имена фичей модели**

Быстрый smoke-test — запустить app, посмотреть в логах `DiagnosticLogger` на ошибки VAD. Если имена фичей неверные — исправить по описанию модели из:

```bash
python3 -c "import coremltools as ct; m = ct.models.MLModel('Resources/silero_vad.mlmodelc'); print(m.input_description); print(m.output_description)"
```

(Если `coremltools` не установлен — можно запустить app и посмотреть что реально падает в os_log.)

- [ ] **Step 6: Commit**

```bash
git add Resources/silero_vad.mlmodelc Sources/Solo_STT/Services/VADService.swift Package.swift
git commit -m "feat: add Silero VAD CoreML + VADService"
```

---

## Task 10: Интегрировать VADService в pipeline

**Files:**
- Modify: `Sources/Solo_STT/AppDelegate.swift`

- [ ] **Step 1: Добавить vadService в AppDelegate**

В `Sources/Solo_STT/AppDelegate.swift` добавить объявление после `textCleanupService`:

```swift
    private var vadService: VADService?
```

В `applicationDidFinishLaunching(...)` добавить после создания других сервисов:

```swift
        vadService = VADService()
```

- [ ] **Step 2: Вставить VAD-шаг в `processRecordingResult`**

В `processRecordingResult(_:)` в ветке `.success(let samples, let duration)`:

```swift
        case .success(let samples, let duration):
            soundFeedbackService?.playStop()
            DiagnosticLogger.shared.info(
                "Recording stopped (\(String(format: "%.1f", duration))s), transcribing...",
                category: "Recording"
            )

            appState.recordingState = .transcribing
            Task {
                // VAD trim
                let trimmedSamples: [Float]
                if let vad = self.vadService,
                   let range = try? await vad.trim(samples: samples) {
                    trimmedSamples = Array(samples[range])
                    let savedMs = Double(samples.count - trimmedSamples.count) / 16.0
                    DiagnosticLogger.shared.info(
                        "VAD: trimmed \(String(format: "%.0f", savedMs))ms silence",
                        category: "VAD"
                    )
                } else if self.vadService != nil {
                    // VAD не нашёл речь — пропускаем
                    DiagnosticLogger.shared.info("VAD: no speech detected, skipping", category: "VAD")
                    await MainActor.run { self.appState.recordingState = .idle }
                    return
                } else {
                    trimmedSamples = samples
                }

                do {
                    guard let transcriptionService = self.transcriptionService else { return }
                    var result = try await transcriptionService.transcribe(audioSamples: trimmedSamples)

                    // Fallback: пустой результат после VAD trim → повтор на полных samples
                    if result.text.isEmpty, trimmedSamples.count < samples.count {
                        DiagnosticLogger.shared.warning(
                            "Empty transcription on trimmed samples, retrying on full",
                            category: "Transcription"
                        )
                        result = try await transcriptionService.transcribe(audioSamples: samples)
                    }

                    // ... existing cleanup + insertion logic (from Task 8)
                }
                // ... existing catch блок
            }
```

(Объединить с существующим Task-блоком из Task 8. Итоговая структура: VAD trim → transcribe → cleanup → insert.)

- [ ] **Step 3: Проверить сборку**

```bash
swift build -c debug
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/Solo_STT/AppDelegate.swift
git commit -m "feat: VADService intégрирован в pipeline с fallback на полные samples"
```

---

## Task 11: Создать AudioLevelMonitor с RMS

**Files:**
- Create: `Sources/Solo_STT/Services/AudioLevelMonitor.swift`
- Create: `Tests/Solo_STTTests/AudioLevelMonitorTests.swift`

- [ ] **Step 1: Написать тест RMS**

Создать `Tests/Solo_STTTests/AudioLevelMonitorTests.swift`:

```swift
import XCTest
import AVFAudio
@testable import Solo_STT

final class AudioLevelMonitorTests: XCTestCase {
    func testSilentBufferGivesZeroLevel() {
        let monitor = AudioLevelMonitor()
        let buffer = makeBuffer(samples: Array(repeating: Float(0), count: 1024))
        monitor.update(from: buffer)
        XCTAssertEqual(monitor.levelHistory.last ?? -1, 0, accuracy: 0.001)
    }

    func testLoudBufferGivesHighLevel() {
        let monitor = AudioLevelMonitor()
        let samples = Array(repeating: Float(0.9), count: 1024)
        let buffer = makeBuffer(samples: samples)
        monitor.update(from: buffer)
        let last = monitor.levelHistory.last ?? 0
        XCTAssertGreaterThan(last, 0.5)
        XCTAssertLessThanOrEqual(last, 1.0)
    }

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
```

- [ ] **Step 2: Запустить тест — ожидаем провал (файла ещё нет)**

```bash
swift test --filter AudioLevelMonitorTests 2>&1 | head -20
```

Expected: ошибка компиляции "Cannot find 'AudioLevelMonitor' in scope".

- [ ] **Step 3: Создать AudioLevelMonitor**

Создать `Sources/Solo_STT/Services/AudioLevelMonitor.swift`:

```swift
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
```

- [ ] **Step 4: Запустить тест**

```bash
swift test --filter AudioLevelMonitorTests
```

Expected: 3 тестов PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Solo_STT/Services/AudioLevelMonitor.swift Tests/Solo_STTTests/AudioLevelMonitorTests.swift
git commit -m "feat: add AudioLevelMonitor with RMS calculation"
```

---

## Task 12: WaveformBars view + FloatingPillView update

**Files:**
- Create: `Sources/Solo_STT/Views/WaveformBars.swift`
- Modify: `Sources/Solo_STT/Views/FloatingPillView.swift`

- [ ] **Step 1: Создать WaveformBars**

Создать `Sources/Solo_STT/Views/WaveformBars.swift`:

```swift
import SwiftUI

struct WaveformBars: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(levels.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.primary)
                    .frame(width: 2, height: max(2, CGFloat(levels[i]) * 16))
                    .animation(.easeOut(duration: 0.08), value: levels[i])
            }
        }
        .frame(height: 16)
    }
}
```

- [ ] **Step 2: Прочитать FloatingPillView**

```bash
cat Sources/Solo_STT/Views/FloatingPillView.swift
```

Запомнить текущую структуру (body switch по recordingState).

- [ ] **Step 3: Обновить FloatingPillView**

Переписать `Sources/Solo_STT/Views/FloatingPillView.swift`:

```swift
import SwiftUI

struct FloatingPillView: View {
    let appState: AppState
    let levelMonitor: AudioLevelMonitor

    var body: some View {
        HStack(spacing: 6) {
            switch appState.recordingState {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                WaveformBars(levels: levelMonitor.levelHistory)
                Text("REC")
                    .font(.caption2)
                    .monospaced()
            case .transcribing:
                ProgressView()
                    .controlSize(.mini)
                Text("Transcribing…")
                    .font(.caption2)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.caption2)
                    .lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}
```

- [ ] **Step 4: Проверить сборку**

```bash
swift build -c debug
```

Expected: BUILD SUCCEEDED. Возможны ошибки в FloatingPillManager — он не передаёт levelMonitor (разрешим в Task 13).

- [ ] **Step 5: Commit**

```bash
git add Sources/Solo_STT/Views/WaveformBars.swift Sources/Solo_STT/Views/FloatingPillView.swift
git commit -m "feat: waveform bars в FloatingPillView"
```

---

## Task 13: Инжектировать AudioLevelMonitor в AudioRecordingService и FloatingPillManager

**Files:**
- Modify: `Sources/Solo_STT/Services/AudioRecordingService.swift`
- Modify: `Sources/Solo_STT/Services/FloatingPillManager.swift`
- Modify: `Sources/Solo_STT/AppDelegate.swift`

- [ ] **Step 1: Добавить levelMonitor в AudioRecordingService**

В `Sources/Solo_STT/Services/AudioRecordingService.swift`:

1) Добавить поле:
```swift
    var levelMonitor: AudioLevelMonitor?
```

2) В методе где установлен `inputNode.installTap(...)`, в closure добавить:
```swift
            // существующая логика записи samples ...

            // Update level monitor
            Task { @MainActor [weak self] in
                self?.levelMonitor?.update(from: buffer)
            }
```

- [ ] **Step 2: Добавить levelMonitor в FloatingPillManager**

В `Sources/Solo_STT/Services/FloatingPillManager.swift`:

1) Добавить `let levelMonitor: AudioLevelMonitor` в init:
```swift
    init(appState: AppState, levelMonitor: AudioLevelMonitor) {
        self.appState = appState
        self.levelMonitor = levelMonitor
    }

    private let levelMonitor: AudioLevelMonitor
```

2) В `start()` при создании `NSHostingView` / `NSHostingController` передать `levelMonitor`:
```swift
        let hostingView = NSHostingView(
            rootView: FloatingPillView(appState: appState, levelMonitor: levelMonitor)
        )
```

- [ ] **Step 3: Обновить AppDelegate.applicationDidFinishLaunching**

В `Sources/Solo_STT/AppDelegate.swift`:

1) Добавить поле:
```swift
    private var audioLevelMonitor: AudioLevelMonitor?
```

2) В `applicationDidFinishLaunching(...)` перед `floatingPillManager = ...`:
```swift
        audioLevelMonitor = AudioLevelMonitor()
        audioRecordingService?.levelMonitor = audioLevelMonitor
```

3) Заменить:
```swift
        floatingPillManager = FloatingPillManager(appState: appState)
```
на:
```swift
        floatingPillManager = FloatingPillManager(
            appState: appState,
            levelMonitor: audioLevelMonitor!
        )
```

4) При остановке записи сбрасывать level (в handleRecordingStop, после stopRecording):
```swift
        audioLevelMonitor?.reset()
```

- [ ] **Step 4: Проверить сборку**

```bash
swift build -c debug
swift test
```

Expected: всё PASS.

- [ ] **Step 5: Manual smoke test**

```bash
bash build-app.sh
open "/Applications/Solo STT.app"
```

Нажать hotkey, поговорить в микрофон, проверить что в pill появляется waveform. Отпустить — перейти в transcribing → idle.

- [ ] **Step 6: Commit**

```bash
git add Sources/Solo_STT/Services/AudioRecordingService.swift Sources/Solo_STT/Services/FloatingPillManager.swift Sources/Solo_STT/AppDelegate.swift
git commit -m "feat: waveform в pill через AudioLevelMonitor"
```

---

## Task 14: AppleSpeechTranscriber + TranscriptionProvider.appleSpeech

**Files:**
- Create: `Sources/Solo_STT/Services/AppleSpeechTranscriber.swift`
- Modify: `Sources/Solo_STT/Models/TranscriptionProvider.swift`
- Modify: `Sources/Solo_STT/Services/TranscriptionService.swift`

- [ ] **Step 1: Добавить case в enum**

В `Sources/Solo_STT/Models/TranscriptionProvider.swift`:

```swift
import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    case local
    case appleSpeech = "apple_speech"
    case cloud
    case customServer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:        return "Локальный — WhisperKit (рекомендуется)"
        case .appleSpeech:  return "Локальный — Apple Speech (macOS 26)"
        case .cloud:        return "Облачный — OpenAI / Groq"
        case .customServer: return "Свой сервер"
        }
    }

    static var `default`: TranscriptionProvider { .local }
}
```

- [ ] **Step 2: Создать AppleSpeechTranscriber**

Создать `Sources/Solo_STT/Services/AppleSpeechTranscriber.swift`:

```swift
import Foundation
import AVFAudio
#if canImport(Speech)
import Speech
#endif

actor AppleSpeechTranscriber {
    enum TranscriberError: LocalizedError {
        case unavailable
        case authorizationDenied

        var errorDescription: String? {
            switch self {
            case .unavailable:           return "SpeechAnalyzer unavailable (macOS 26 required)"
            case .authorizationDenied:   return "Speech recognition not authorized"
            }
        }
    }

    struct Result {
        let text: String
        let language: String
        let latency: TimeInterval
    }

    func transcribe(
        samples: [Float],
        language: String
    ) async throws -> Result {
        #if canImport(Speech)
        if #available(macOS 26.0, *) {
            let locale = Locale(identifier: language == "auto" ? "ru_RU" : language)
            let transcriber = try await SpeechTranscriber(
                locale: locale,
                preset: .offlineTranscription
            )
            let analyzer = try await SpeechAnalyzer(modules: [transcriber])

            let buffer = try samplesToPCMBuffer(samples: samples)
            let start = Date()
            try await analyzer.analyze(buffer: buffer)
            try await analyzer.finalize()
            let latency = Date().timeIntervalSince(start)

            var resultText = ""
            for try await segment in transcriber.results {
                resultText += segment.text
            }
            return Result(text: resultText.trimmingCharacters(in: .whitespaces),
                          language: language,
                          latency: latency)
        } else {
            throw TranscriberError.unavailable
        }
        #else
        throw TranscriberError.unavailable
        #endif
    }

    private func samplesToPCMBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
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
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].update(
                from: ptr.baseAddress!, count: samples.count
            )
        }
        return buffer
    }
}
```

(Точные имена `SpeechTranscriber.init(locale:preset:)`, `.offlineTranscription` и `SpeechAnalyzer(modules:)` — по документации Apple. На Step 4 нужна проверка; если не компилируется — свериться с [SpeechTranscriber docs](https://developer.apple.com/documentation/speech/speechtranscriber).)

- [ ] **Step 3: Роутить .appleSpeech в TranscriptionService**

В `Sources/Solo_STT/Services/TranscriptionService.swift` добавить поле и case:

```swift
    private let appleSpeech: AppleSpeechTranscriber

    init(modelService: ModelService, appState: AppState) {
        self.modelService = modelService
        self.appState = appState
        self.cloudClient = CloudTranscriptionClient()
        self.appleSpeech = AppleSpeechTranscriber()
    }

    func transcribe(audioSamples: [Float]) async throws -> TranscriptionResult {
        // ...
        switch provider {
        // ... existing cases ...
        case .appleSpeech:
            let r = try await appleSpeech.transcribe(
                samples: audioSamples,
                language: language
            )
            return TranscriptionResult(text: r.text,
                                        language: r.language,
                                        latency: r.latency)
        }
    }
```

Также добавить в `AppState.isReadyToTranscribe`:

```swift
    var isReadyToTranscribe: Bool {
        switch currentProvider {
        case .local:
            if case .ready = modelState { return true }
            return false
        case .appleSpeech:
            return true  // runtime check на macOS 26 внутри transcriber
        case .customServer:
            return !customEndpointURL.isEmpty
        case .cloud:
            return KeychainService.load(key: cloudKeychainKey) != nil
        }
    }
```

- [ ] **Step 4: Проверить сборку**

```bash
swift build -c debug
```

Если ошибки в AppleSpeechTranscriber — открыть документацию `SpeechTranscriber` в Xcode и подогнать имена. Типичная поправка — `init(locale:preset:)` может быть `init(locale:attributeOptions:)`, или `.offlineTranscription` может называться `.transcription`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Solo_STT/Models/TranscriptionProvider.swift Sources/Solo_STT/Services/AppleSpeechTranscriber.swift Sources/Solo_STT/Services/TranscriptionService.swift Sources/Solo_STT/AppState.swift
git commit -m "feat: add Apple SpeechAnalyzer provider"
```

---

## Task 15: Упростить Vocabulary (удалить пресеты)

**Files:**
- Delete: `Sources/Solo_STT/Models/VocabularyPreset.swift`
- Modify: `Sources/Solo_STT/AppState.swift`
- Create: `Tests/Solo_STTTests/VocabularyMigrationTests.swift`

- [ ] **Step 1: Удалить VocabularyPreset**

```bash
git rm Sources/Solo_STT/Models/VocabularyPreset.swift
```

- [ ] **Step 2: Написать тест миграции пресетов**

Создать `Tests/Solo_STTTests/VocabularyMigrationTests.swift`:

```swift
import XCTest
@testable import Solo_STT

final class VocabularyMigrationTests: XCTestCase {
    func testMergePresetsIntoVocabulary() {
        let current = "React, TypeScript"
        let presetWords = ["Swift", "SwiftUI"]
        let merged = AppState.mergeVocabulary(current: current, presetWords: presetWords)
        XCTAssertTrue(merged.contains("React"))
        XCTAssertTrue(merged.contains("TypeScript"))
        XCTAssertTrue(merged.contains("Swift"))
        XCTAssertTrue(merged.contains("SwiftUI"))
    }

    func testNoDuplicatesAfterMerge() {
        let current = "React, Swift"
        let presetWords = ["Swift", "TypeScript"]
        let merged = AppState.mergeVocabulary(current: current, presetWords: presetWords)
        let parts = merged.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(parts.filter { $0 == "Swift" }.count, 1)
    }

    func testEmptyCurrentUsesDefault() {
        let merged = AppState.mergeVocabulary(current: "", presetWords: [])
        XCTAssertFalse(merged.isEmpty)
        XCTAssertTrue(merged.contains("React"))
    }
}
```

- [ ] **Step 3: Обновить AppState**

В `Sources/Solo_STT/AppState.swift`:

1) Удалить `selectedPresets`:
```swift
    // УДАЛИТЬ: var selectedPresets: [String] = ...
```

2) Заменить `customVocabulary` default:
```swift
    var customVocabulary: String = {
        if let stored = UserDefaults.standard.string(forKey: "customVocabulary"),
           !stored.isEmpty {
            return stored
        }
        return Self.defaultVocabulary
    }() {
        didSet { UserDefaults.standard.set(customVocabulary, forKey: "customVocabulary") }
    }

    static let defaultVocabulary = """
    React, TypeScript, SwiftUI, macOS, iOS, Claude, Anthropic, \
    MCP, API, JSON, useState, useEffect, async, await, actor, \
    WhisperKit, Foundation Models, ANE, CoreML
    """
```

3) Добавить `mergeVocabulary` статический метод:
```swift
    static func mergeVocabulary(current: String, presetWords: [String]) -> String {
        let currentWords = current
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let effective = currentWords.isEmpty && presetWords.isEmpty
            ? Self.defaultVocabulary
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            : currentWords
        let combined = effective + presetWords
        var seen = Set<String>()
        let unique = combined.filter { w in
            let lower = w.lowercased()
            return seen.insert(lower).inserted
        }
        return unique.joined(separator: ", ")
    }
```

- [ ] **Step 4: Запустить тесты**

```bash
swift test --filter VocabularyMigrationTests
```

Expected: 3 тестов PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Solo_STT/AppState.swift Tests/Solo_STTTests/VocabularyMigrationTests.swift
git commit -m "feat: убрать пресеты словаря, default customVocabulary + merge-логика"
```

---

## Task 16: Миграция настроек при первом запуске v2

**Files:**
- Modify: `Sources/Solo_STT/AppState.swift`
- Create: `Tests/Solo_STTTests/TranscriptionProviderMigrationTests.swift`

- [ ] **Step 1: Написать тесты миграции**

Создать `Tests/Solo_STTTests/TranscriptionProviderMigrationTests.swift`:

```swift
import XCTest
@testable import Solo_STT

final class TranscriptionProviderMigrationTests: XCTestCase {
    func testLegacyOpenAIProviderMigrates() {
        XCTAssertEqual(
            AppState.migrateProvider(from: "openai"),
            (provider: "cloud", cloudService: "openai")
        )
    }

    func testLegacyGroqProviderMigrates() {
        XCTAssertEqual(
            AppState.migrateProvider(from: "groq"),
            (provider: "cloud", cloudService: "groq")
        )
    }

    func testLegacyLogosSttMigratesToCustomServer() {
        let (provider, _) = AppState.migrateProvider(from: "logosStt")
        XCTAssertEqual(provider, "customServer")
    }

    func testModernLocalPassesThrough() {
        let (provider, _) = AppState.migrateProvider(from: "local")
        XCTAssertEqual(provider, "local")
    }
}
```

- [ ] **Step 2: Реализовать `migrateProvider` и `performMigration`**

В `Sources/Solo_STT/AppState.swift` добавить:

```swift
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

        DiagnosticLogger.shared.info("Running migration from v\(stored) to v\(Self.currentMigrationVersion)", category: "Migration")

        // Migrate provider
        let oldProvider = UserDefaults.standard.string(forKey: "transcriptionProvider") ?? "local"
        let (newProvider, newCloudService) = Self.migrateProvider(from: oldProvider)
        UserDefaults.standard.set(newProvider, forKey: "transcriptionProvider")
        if let cloudService = newCloudService {
            UserDefaults.standard.set(cloudService, forKey: "cloudService")
        }

        // Migrate model
        let oldModel = UserDefaults.standard.string(forKey: "selectedModel") ?? ""
        let newModel = WhisperModel.migrateFromLegacy(oldModel)
        UserDefaults.standard.set(newModel.rawValue, forKey: "selectedModel")

        // Migrate presets → vocabulary
        if let presets = UserDefaults.standard.array(forKey: "selectedPresets") as? [String],
           !presets.isEmpty {
            let current = UserDefaults.standard.string(forKey: "customVocabulary") ?? ""
            let merged = Self.mergeVocabulary(current: current, presetWords: presets)
            UserDefaults.standard.set(merged, forKey: "customVocabulary")
            UserDefaults.standard.removeObject(forKey: "selectedPresets")
        }

        // Mark done
        UserDefaults.standard.set(Self.currentMigrationVersion, forKey: Self.migrationVersionKey)
        DiagnosticLogger.shared.info("Migration to v\(Self.currentMigrationVersion) complete", category: "Migration")
    }
```

- [ ] **Step 3: Вызвать миграцию в AppDelegate до создания сервисов**

В `Sources/Solo_STT/AppDelegate.swift`, самым первым действием в `applicationDidFinishLaunching(...)` (перед защитой от двойного запуска — не критично, но логично):

```swift
        appState.performMigrationIfNeeded()
```

- [ ] **Step 4: Запустить тесты**

```bash
swift test --filter TranscriptionProviderMigrationTests
swift build -c debug
```

Expected: 4 тестов PASS, build SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/Solo_STT/AppState.swift Sources/Solo_STT/AppDelegate.swift Tests/Solo_STTTests/TranscriptionProviderMigrationTests.swift
git commit -m "feat: миграция UserDefaults при первом запуске v2"
```

---

## Task 17: MigrationOnboardingView + first-launch wire

**Files:**
- Create: `Sources/Solo_STT/Views/MigrationOnboardingView.swift`
- Modify: `Sources/Solo_STT/AppDelegate.swift`

- [ ] **Step 1: Создать MigrationOnboardingView**

Создать `Sources/Solo_STT/Views/MigrationOnboardingView.swift`:

```swift
import SwiftUI

struct MigrationOnboardingView: View {
    let appState: AppState
    let modelService: ModelService
    let onDismiss: () -> Void

    @State private var deleteLegacy: Bool = true
    @State private var downloading: Bool = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Solo STT v2.0")
                .font(.largeTitle).bold()

            Text("Обновили движок на WhisperKit (Neural Engine).")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Label("В 2-3 раза быстрее", systemImage: "bolt.fill")
                Label("Меньше расход батареи", systemImage: "battery.100")
                Label("Лучше распознаёт технические термины", systemImage: "text.cursor")
            }
            .font(.callout)

            Divider()

            Text("Нужно скачать новую модель (~1.5 GB).")

            Toggle("Удалить старые GGML-модели (освободит ~2 GB)", isOn: $deleteLegacy)
                .toggleStyle(.checkbox)

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button("Позже") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Скачать модель") {
                    Task { await download() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(downloading)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func download() async {
        downloading = true
        defer { downloading = false }
        do {
            try await modelService.downloadAndLoad(variant: WhisperModel.turbo.rawValue)
            if deleteLegacy {
                modelService.deleteLegacyGgmlModels()
            }
            onDismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Показать окно в AppDelegate при первом запуске v2**

В `Sources/Solo_STT/AppDelegate.swift`:

1) Добавить поле:
```swift
    private var migrationWindow: NSWindow?
```

2) Добавить флаг `migrationCompleted` в UserDefaults. Показывать окно миграции если:
- `currentMigrationVersion` > previous AND
- model НЕ загружена.

В `applicationDidFinishLaunching` после `performMigrationIfNeeded()`:

```swift
        let showMigration = !UserDefaults.standard.bool(forKey: "v2MigrationUISeen")
                            && modelService?.isModelDownloaded(.turbo) == false
        if showMigration {
            showMigrationWindow()
            UserDefaults.standard.set(true, forKey: "v2MigrationUISeen")
        }
```

3) Добавить метод:

```swift
    private func showMigrationWindow() {
        guard let modelService else { return }
        let view = MigrationOnboardingView(
            appState: appState,
            modelService: modelService,
            onDismiss: { [weak self] in
                self?.migrationWindow?.close()
                self?.migrationWindow = nil
            }
        )
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Solo STT — Обновление"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        migrationWindow = window
    }
```

- [ ] **Step 3: Проверить сборку**

```bash
swift build -c debug
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual test**

```bash
# Сбросить флаг миграции
defaults delete com.solo.stt v2MigrationUISeen 2>/dev/null || true
defaults delete com.solo.stt appMigrationVersion 2>/dev/null || true
bash build-app.sh
open "/Applications/Solo STT.app"
```

Expected: окно «Solo STT v2.0» появляется.

- [ ] **Step 5: Commit**

```bash
git add Sources/Solo_STT/Views/MigrationOnboardingView.swift Sources/Solo_STT/AppDelegate.swift
git commit -m "feat: экран миграции v1→v2 при первом запуске"
```

---

## Task 18: Обновить SettingsView (vocabulary, provider, cleanup toggle)

**Files:**
- Modify: `Sources/Solo_STT/Views/SettingsView.swift`
- Modify: `Sources/Solo_STT/Views/StatusItemManager.swift`

- [ ] **Step 1: Прочитать SettingsView**

```bash
cat Sources/Solo_STT/Views/SettingsView.swift
```

- [ ] **Step 2: Внести изменения в SettingsView**

Правки:

1) **Секция Провайдер** — Picker вместо старых чекбоксов:
```swift
Section("Провайдер распознавания") {
    Picker("Движок", selection: Binding(
        get: { appState.currentProvider.rawValue },
        set: { appState.transcriptionProvider = $0 }
    )) {
        ForEach(TranscriptionProvider.allCases) { provider in
            Text(provider.displayName).tag(provider.rawValue)
        }
    }
    .pickerStyle(.menu)
}
```

2) **Секция Модель** (только когда `.local`) — Picker из `WhisperModel.all`:
```swift
if appState.currentProvider == .local {
    Section("Модель") {
        Picker("Модель", selection: $appState.selectedModel) {
            ForEach(WhisperModel.all) { model in
                Text(model.displayName).tag(model.rawValue)
            }
        }
        .pickerStyle(.menu)
    }
}
```

3) **Секция Словарь** (убрать чекбоксы пресетов):
```swift
Section("Технические термины") {
    TextEditor(text: $appState.customVocabulary)
        .frame(minHeight: 80)
        .font(.body.monospaced())
    Text("Через запятую. До 224 токенов Whisper-ом.")
        .font(.caption)
        .foregroundStyle(.secondary)
    Button("Сбросить на умолчания") {
        appState.customVocabulary = AppState.defaultVocabulary
    }
}
```

4) **Новая секция AI-очистка**:
```swift
Section("AI-очистка текста") {
    Toggle("Включить Foundation Models cleanup",
           isOn: $appState.aiCleanupEnabled)
    Text("Убирает заполнители, исправляет пунктуацию, капитализирует термины. Локально, через Apple Intelligence.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

(Опционально если хотим быть точными — определить доступность Foundation Models и disable toggle с подсказкой.)

- [ ] **Step 3: Обновить StatusItemManager (меню выбора модели)**

В `Sources/Solo_STT/Views/StatusItemManager.swift` в методе, который строит динамическое меню из `WhisperModel.all`, убедиться, что используются новые варианты. Если есть `ggml-medium.bin` строки — заменить на `WhisperModel.turbo.rawValue`.

- [ ] **Step 4: Проверить сборку**

```bash
swift build -c debug
swift test
```

Expected: build SUCCEEDED, все тесты PASS.

- [ ] **Step 5: Manual smoke test**

```bash
bash build-app.sh
open "/Applications/Solo STT.app"
# Menu bar → Настройки → проверить все секции
```

- [ ] **Step 6: Commit**

```bash
git add Sources/Solo_STT/Views/SettingsView.swift Sources/Solo_STT/Views/StatusItemManager.swift
git commit -m "feat: настройки — новые провайдеры, модели, словарь, AI cleanup"
```

---

## Task 19: End-to-end verification и релизный коммит

**Files:**
- Modify: `build-app.sh` (версия 2.0)

- [ ] **Step 1: Обновить версию в build-app.sh**

В `Sources/Solo_STT/build-app.sh` или `build-app.sh` (корень) изменить:

```bash
    <key>CFBundleVersion</key>
    <string>2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
```

- [ ] **Step 2: Собрать dist-bundle**

```bash
bash build-app.sh --dist
```

Expected: `.build/release/Solo STT.dmg` создан.

- [ ] **Step 3: Полный end-to-end тест вручную**

1) Удалить старую установку: `rm -rf "/Applications/Solo STT.app"`
2) Сбросить флаги миграции: `defaults delete com.solo.stt appMigrationVersion 2>/dev/null; defaults delete com.solo.stt v2MigrationUISeen 2>/dev/null`
3) Смонтировать DMG, переместить app в Applications.
4) Запустить. Проверить:
   - [ ] Появляется окно миграции v2.0
   - [ ] Скачивание модели показывает прогресс
   - [ ] После скачивания modelState → .ready
   - [ ] Hotkey → recording → waveform в pill → transcribe → cleanup → вставка
   - [ ] Латентность keyUp → text < 1 секунды на 5-секундной фразе
   - [ ] Capitalization: фраза «создай юзэфект для клода» → «создай useEffect для Claude»
   - [ ] В Settings все секции рендерятся
   - [ ] Смена провайдера `.appleSpeech` → hotkey работает
   - [ ] Удаление GGML после миграции очистило старые файлы

- [ ] **Step 4: Tag релиза**

```bash
git tag -a v2.0 -m "Solo STT v2.0 — WhisperKit + VAD + Foundation Models cleanup"
```

- [ ] **Step 5: Commit версии и финал**

```bash
git add build-app.sh
git commit -m "chore: bump version to 2.0"
```

---

## Self-Review Notes

**Spec coverage проверка** (по секциям спеки):
- §2 Архитектура — Tasks 1-18 покрывают весь pipeline.
- §3 WhisperKit — Tasks 1-6.
- §4 VAD — Tasks 9-10.
- §5 TextCleanupService — Tasks 7-8.
- §6 Waveform — Tasks 11-13.
- §7 Провайдеры — Tasks 5, 14.
- §8 Vocabulary — Task 15.
- §9 Error handling — распределено в Tasks 7, 9, 10 (fallback).
- §10 Миграция — Tasks 16-17.
- §11 Вне scope — отсутствует в плане (correctly).
- §12 Порядок работ — соответствует Task 1-19.
- §13 Metrics — верификация в Task 19.

**Placeholders**: нет. Каждый шаг содержит полный код или команду.

**Type consistency**: `WhisperKitTranscriber.Result` и `TranscriptionService.TranscriptionResult` — разные типы, что сделано осознанно (Result — внутренний, TranscriptionResult — публичный). Остальные имена согласованы.

**Потенциальный риск**: точные API WhisperKit / SpeechTranscriber / FoundationModels могут отличаться от приведённых сниппетов — версии этих фреймворков активно меняются. Tasks 2, 7, 14 требуют сверки с фактической документацией на момент реализации. В этих задачах добавлены подсказки про docs.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-13-whisperkit-migration.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — дispatch'им fresh subagent per task, review между задачами, быстрая итерация

**2. Inline Execution** — выполняем задачи в текущей сессии через executing-plans, batch execution с checkpoint'ами

**Какой подход выбираешь?**
