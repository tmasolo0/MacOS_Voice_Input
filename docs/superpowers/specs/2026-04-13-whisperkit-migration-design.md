# Solo STT v2: WhisperKit + VAD + Foundation Models

**Дата**: 2026-04-13
**Статус**: design approved, готов к плану реализации
**Контекст**: модернизация Solo STT под vibecoding с LLM-терминами, цели — отзывчивость и надёжность на локальных ресурсах, macOS 26+, Apple Silicon M3+.

---

## 1. Цели и ограничения

**Pain**: пользователь работает с постоянным mix русского и английского (технические термины: React, MCP, useEffect, Claude). Текущая связка SwiftWhisper + medium GGML медленная, иногда путает термины, требует регулярной постобработки вручную.

**Цели**:
- Latency от отпускания hotkey до текста в курсоре — <1 секунды на средней фразе.
- Точное распознавание code-switching (рус+англ в одном предложении).
- Правильная капитализация технических терминов в финальном тексте.
- 100% локальная обработка (нет внешних демонов типа Ollama).
- Сохранение возможности переключения на внешние провайдеры (OpenAI/Groq/custom server).

**Ограничения**:
- Only native Swift SPM dependencies (принцип проекта).
- Целевая платформа — macOS 26+ (Tahoe), чип M3+.
- Push-to-talk UX сохраняется.

**Выбранный подход**: WhisperKit large-v3-turbo на Neural Engine + Silero VAD pre-processing + Apple Foundation Models для постобработки + Apple SpeechAnalyzer как дополнительный local provider.

---

## 2. Архитектура pipeline

```
HotkeyService (CGEvent tap, без изменений)
  │
  ├─ keyDown → AudioRecordingService.start
  │            └─ audio tap → AudioLevelMonitor → FloatingPillManager (waveform)
  │
  └─ keyUp → AudioRecordingService.stop
             └─ [Float] samples @ 16kHz mono
                 │
                 ▼
             VADService (Silero VAD CoreML)
                 └─ trimmed [Float] (тишина удалена)
                     │
                     ▼
                 TranscriptionService
                 ├─ .local → WhisperKit large-v3-turbo (Neural Engine)
                 ├─ .appleSpeech → SpeechAnalyzer + SpeechTranscriber
                 ├─ .cloud → HTTP POST OpenAI/Groq
                 └─ .customServer → HTTP POST user URL
                     │
                     ▼ raw text
                 TextCleanupService (optional, toggle)
                 └─ Foundation Models (3B on-device)
                     │
                     ▼ final text
                 TextInsertionService (CGEvent paste, без изменений)
```

**Что удаляется**:
- `SwiftWhisper` dependency из `Package.swift`
- `TextProcessingService.swift` (regex-правила заменяются на Foundation Models)
- Пресеты vocabulary (IT/дизайн/бизнес) — остаётся только свободный customVocabulary

**Что добавляется**:
- `VADService` — pre-processing шаг обрезки тишины
- `TextCleanupService` — post-processing через Foundation Models
- `AudioLevelMonitor` + `WaveformBars` — waveform в pill
- Новый provider `.appleSpeech` в enum

**Что остаётся без изменений**:
- `HotkeyService` (CGEvent tap, Secure Input handling)
- `AudioRecordingService` (+ один audio tap для levels)
- `TextInsertionService`
- `FloatingPillManager` (+ новые состояния view)
- Cloud и customServer провайдеры
- Keychain, permissions, diagnostic logging

---

## 3. WhisperKit интеграция

### 3.1 Зависимость

`Package.swift`:
```swift
dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.10.0")
]
```
Убрать `SwiftWhisper` полностью.

### 3.2 Доступные модели

Источник: [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml).

| Вариант | Размер | Латентность M3 | WER (рус) | Рекомендация |
|---------|--------|----------------|-----------|---------------|
| `openai_whisper-large-v3-turbo_turbo_600MB` | 600 MB | ~350 мс | ~1% хуже | для старых Mac или экономии места |
| `openai_whisper-large-v3-turbo` | 1.5 GB | ~500 мс | baseline | **default** |
| `openai_whisper-large-v3` | 3 GB | ~800 мс | +1% лучше | максимум качества |
| `openai_whisper-small` | 250 MB | ~200 мс | -5% хуже | legacy/слабый Mac |

Хранение: `~/Library/Application Support/Solo_STT/models/whisperkit/<variant>/`.

### 3.3 API использования

```swift
actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?

    func load(variant: String) async throws {
        let modelPath = modelsDirectory.appendingPathComponent(variant)
        whisperKit = try await WhisperKit(
            modelFolder: modelPath.path,
            prewarm: true
        )
    }

    func transcribe(
        samples: [Float],
        language: String,
        vocabulary: String
    ) async throws -> TranscriptionResult {
        guard let whisperKit else { throw TranscriberError.notLoaded }

        let promptTokens = try whisperKit.tokenizer?.encode(
            text: " \(vocabulary)"
        ).prefix(224)

        let start = Date()
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(
                task: .transcribe,
                language: language,
                promptTokens: promptTokens.map(Array.init),
                temperatureFallbackCount: 2,
                usePrefillPrompt: true
            )
        )
        let text = results.map(\.text).joined()
        return TranscriptionResult(
            text: text,
            language: language,
            latency: Date().timeIntervalSince(start)
        )
    }
}
```

### 3.4 ModelService изменения

`WhisperModel` enum обновляется:
- было: `.small`, `.medium` (GGML)
- станет: `.turboQuantized`, `.turbo`, `.largeV3`, `.small`

`ModelService.downloadAndLoad(variant:)`:
- Использует `WhisperKit.download(variant:)` — загружает полную директорию с файлами (AudioEncoder, TextDecoder, MelSpectrogram, config.json).
- Прогресс через `URLSessionDownloadDelegate` wrapper или встроенный callback WhisperKit.
- После загрузки вызывает `WhisperKitTranscriber.load(variant:)`.

### 3.5 Prewarm стратегия

При `applicationDidFinishLaunching`:
- Если провайдер `.local` и модель на диске — запустить `prewarm: true` в фоне (2-5 сек первый раз после смены чипа, мгновенно из кеша).
- `modelState = .loading` пока идёт prewarm.
- `isReadyToTranscribe = false` пока `modelState != .ready`.
- Pill показывает «прогрев модели…» если user нажал hotkey до завершения.

### 3.6 Mix рус/англ обработка

`language: "ru"` явно задаётся (не auto-detect) + английские термины через `promptTokens`. Whisper обучен code-switching, термины не теряются. Для сессий с доминирующим английским — пользователь может переключить `transcriptionLanguage` в Settings.

---

## 4. VAD Pre-processing (Silero)

### 4.1 Модель

Source: [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml). 1.8 MB, работает на ANE.

Хранение: ресурс приложения (`Resources/silero_vad.mlmodelc`), не качается отдельно.

### 4.2 API

```swift
actor VADService {
    private let model: MLModel

    /// Находит диапазон речи в аудио.
    /// Возвращает nil если речь не обнаружена.
    func trim(
        samples: [Float],
        sampleRate: Int = 16000,
        speechThreshold: Float = 0.5,
        minSpeechDurationMs: Int = 250,
        speechPadMs: Int = 150
    ) async throws -> Range<Int>?
}
```

Алгоритм:
1. Проходит окнами 32ms (512 samples @ 16kHz).
2. Для каждого окна — CoreML inference, probability [0..1] речи.
3. Threshold `>0.5` — speech.
4. Склеивает подряд идущие speech-окна, отбрасывает короче `minSpeechDurationMs`.
5. Возвращает range от первого до последнего speech-окна + padding.

### 4.3 Интеграция

В `AppDelegate.processRecordingResult`:
```swift
case .success(let samples, _):
    guard let speechRange = try? await vadService.trim(samples: samples) else {
        DiagnosticLogger.shared.info("VAD: no speech detected, skipping")
        await MainActor.run { appState.recordingState = .idle }
        return
    }
    let trimmed = Array(samples[speechRange])
    // → TranscriptionService
```

### 4.4 Fallback

Если после VAD+transcription результат пустой — повтор transcription на **полных** samples без обрезки. Защита от слишком агрессивного VAD на шёпоте. 2 transcription дороже, но user получает результат.

Если VAD инициализация упала — `VADService` возвращает `samples.indices` (эквивалент «не обрезаем»). Pipeline не блокируется.

---

## 5. TextCleanupService на Foundation Models

### 5.1 Что делает

- Убирает заполнители: «э», «эм», «ну», «типа», «короче», «вот».
- Капитализирует технические термины: React, TypeScript, Claude, MCP, API, JSON, useEffect, useState.
- Добавляет пунктуацию.
- **Не меняет** смысл, не перефразирует, не сокращает.

Заменяет `TextProcessingService.swift` полностью.

### 5.2 API

```swift
import FoundationModels

actor TextCleanupService {
    private let session: LanguageModelSession?

    init() {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            self.session = nil
            return
        }
        self.session = LanguageModelSession(
            model: model,
            instructions: Self.cleanupInstructions
        )
    }

    var isAvailable: Bool { session != nil }

    func clean(_ raw: String, timeout: TimeInterval = 5) async throws -> String {
        guard let session else { return raw }
        let wordCount = raw.split(separator: " ").count
        guard wordCount >= 5 else { return raw }

        let response = try await withTimeout(timeout) {
            try await session.respond(to: raw)
        }
        return response.content.trimmingCharacters(in: .whitespaces)
    }

    private static let cleanupInstructions = """
    Ты — редактор расшифровок речи программиста.
    Твоя задача: убрать заполнители, исправить пунктуацию,
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

### 5.3 Availability

Foundation Models доступны при:
- macOS 26+
- M1+ чип
- Apple Intelligence включён

Если недоступно — `isAvailable == false`, toggle в Settings disabled с подсказкой «требуется Apple Intelligence».

### 5.4 Performance targets

- 60-100 tok/s decode на M3+
- Типичная фраза 20 слов ≈ 30 токенов ≈ 300-500 мс cleanup
- Timeout 5 сек → fallback на сырой текст
- Коротких фраз (<5 слов) пропускаем cleanup

### 5.5 Settings UI

```
AI-очистка текста (Foundation Models)
  ☑ Включить
     Убирает заполнители, исправляет пунктуацию,
     капитализирует термины (React, MCP, Claude).
     Работает локально, требует Apple Intelligence.
```

Default: `true` на macOS 26 (если доступно), `false` иначе.

---

## 6. Waveform в Floating Pill

### 6.1 AudioLevelMonitor

```swift
@Observable
final class AudioLevelMonitor {
    var levelHistory: [Float] = Array(repeating: 0, count: 15)

    func update(from buffer: AVAudioPCMBuffer) {
        let rms = calculateRMS(buffer)
        let normalized = min(1.0, log10(1 + rms * 100) / 2)
        levelHistory.removeFirst()
        levelHistory.append(Float(normalized))
    }

    private func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return sqrt(sum / Float(count))
    }
}
```

### 6.2 Интеграция с AudioRecordingService

В существующий `inputNode.installTap(...)` добавить вызов `levelMonitor.update(from: buffer)`. AudioLevelMonitor инжектится в FloatingPillManager.

### 6.3 FloatingPillView

```swift
struct FloatingPillView: View {
    let appState: AppState
    let levelMonitor: AudioLevelMonitor

    var body: some View {
        HStack(spacing: 6) {
            switch appState.recordingState {
            case .recording:
                Circle().fill(.red).frame(width: 6, height: 6)
                WaveformBars(levels: levelMonitor.levelHistory)
                Text("REC").font(.caption2).monospaced()
            case .transcribing:
                ProgressView().controlSize(.mini)
                Text("Transcribing…").font(.caption2)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle")
                Text(msg).font(.caption2).lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
    }
}

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
    }
}
```

### 6.4 Размеры

Pill расширяется до ~120px шириной для размещения waveform. `pillOffsetDX/DY` в UserDefaults остаётся.

---

## 7. Провайдеры (все сохраняются)

### 7.1 TranscriptionProvider enum

```swift
enum TranscriptionProvider: String {
    case local           // WhisperKit (new default)
    case appleSpeech     // macOS 26 native (new)
    case cloud           // OpenAI/Groq
    case customServer    // self-hosted
}
```

### 7.2 Behaviors

| Provider | initial_prompt vocabulary | Cleanup | Ограничения |
|----------|---------------------------|---------|-------------|
| `.local` | ✅ через promptTokens | ✅ | macOS 14+ |
| `.appleSpeech` | ❌ (v1, extensibility позже) | ✅ | macOS 26+ only |
| `.cloud` | ✅ через `prompt` API field | ✅ | требует API key |
| `.customServer` | ✅ если endpoint совместим | ✅ | требует URL |

Cleanup через Foundation Models применяется к выходу **любого** провайдера (если `aiCleanupEnabled && cleanupService.isAvailable`).

### 7.3 Settings UI

Dropdown «Провайдер распознавания»:
- Локальный — WhisperKit (быстро, оффлайн) — **default**
- Локальный — Apple Speech (macOS 26, быстрее но без vocabulary)
- Облачный — OpenAI/Groq (нужен API-ключ)
- Свой сервер — любой Whisper API (нужен URL)

---

## 8. Vocabulary simplification

**Удаляется**: `selectedPresets: [String]`, `VocabularyPreset.swift`, UI с чекбоксами пресетов.

**Остаётся**: `customVocabulary: String` — свободный TextField.

**Default customVocabulary** (при первом запуске v2, может редактироваться):
```
React, TypeScript, SwiftUI, macOS, iOS, Claude, Anthropic,
MCP, API, JSON, useState, useEffect, async, await, actor,
WhisperKit, Foundation Models, ANE, CoreML
```

**Migration**: при запуске v2 — если `customVocabulary` пустой, подставить default. Если `selectedPresets` непустой — добавить их слова в `customVocabulary` и сбросить `selectedPresets`.

---

## 9. Error handling

| Ошибка | Fallback |
|--------|----------|
| WhisperKit модель не загружена | Onboarding / download prompt |
| WhisperKit transcribe failed | `recordingState = .error(msg)`, pill показывает ошибку |
| VAD: речь не найдена | Skip без ошибки, idle |
| VAD: инициализация упала | Skip VAD, транскрибировать целиком |
| WhisperKit вернул пустой текст после VAD trim | Retry без VAD на полных samples |
| Foundation Models unavailable | Cleanup skip, сырой текст |
| Foundation Models timeout (5s) | Cleanup skip, сырой текст |
| Cloud provider network error | `recordingState = .error`, НЕ fallback на local |
| Prewarm не завершился до hotkey | Ignore hotkey, pill показывает «прогрев…» |

Логирование через `DiagnosticLogger` в каждой ветке fallback. Пользователь видит graceful state в pill, не падение.

---

## 10. Миграция с v1 (onboarding)

### 10.1 Что автоматически

При первом запуске v2:
- `transcriptionProvider = "local"` → продолжает работать, но теперь использует WhisperKit.
- `selectedModel = "ggml-medium.bin"` → мапится на `"openai_whisper-large-v3-turbo"`.
- `selectedPresets` → слова merge в `customVocabulary`, пресеты сбрасываются.
- `hotkeyKeyCode`, `hotkeyIsModifier`, `selectedAudioDeviceUID`, `pillOffsetDX/DY` — сохраняются без изменений.
- `aiCleanupEnabled = true` (macOS 26) или `false` (если Foundation Models недоступны).

### 10.2 Onboarding-экран v2

Показывается один раз при первом запуске новой версии (после мапы настроек, до первого использования):

```
┌────────────────────────────────────────┐
│  Solo STT v2.0                         │
│                                        │
│  Обновили движок распознавания на      │
│  WhisperKit (Neural Engine).           │
│                                        │
│  Это даёт:                             │
│  • В 2-3 раза быстрее                  │
│  • Меньше расход батареи                │
│  • Лучше работа с технической речью    │
│                                        │
│  Нужно скачать новую модель (1.5 GB).  │
│  Старые модели можно удалить (2 GB).   │
│                                        │
│  [Скачать модель]     [Позже]          │
│                                        │
│  ☑ Удалить старые GGML модели          │
└────────────────────────────────────────┘
```

Если user жмёт «Позже» — приложение работает, но при первом нажатии hotkey показывает подсказку «скачайте модель в настройках».

### 10.3 Обратная совместимость

v1 пользователи, которые не откроют v2, продолжают работать на v1. Нет обязательного принудительного обновления.

---

## 11. Что НЕ делаем (вне scope этого дизайна)

- Command Mode («сделай короче», «переведи») — отдельная фича.
- Power Mode (per-app конфигурация модель/промпт/язык) — отдельная фича v3.
- Speaker diarization — не push-to-talk use case.
- Streaming preview (partial results в pill) — обсуждалось, отвергнуто (сложность > польза).
- Parakeet / Moonshine провайдеры — нет русского / слабый на рус-англ.
- Ollama/MLX интеграция — внешний демон, противоречит «native Swift».
- Sparkle + auto-update — требует Developer ID ($99/год), отложено.
- Smart formatting (голосовые команды «новая строка», «кавычки») — отдельная фича.
- Raycast extension / Shortcuts action — post-v2.

---

## 12. Порядок работ (для плана реализации)

1. **WhisperKit интеграция** — удалить SwiftWhisper, добавить WhisperKit, переписать `TranscriptionService` для provider `.local`. ModelService переделать на WhisperKit download. Prewarm при старте.
2. **TextCleanupService** — Foundation Models cleanup. Удалить `TextProcessingService.swift`. Toggle в Settings. (Шаги 1+3 мерджить вместе — иначе регрессия качества.)
3. **VADService** — Silero VAD pre-processing в pipeline.
4. **Waveform UI** — `AudioLevelMonitor`, `WaveformBars`, расширение pill.
5. **Apple SpeechAnalyzer provider** — новый case `.appleSpeech`.
6. **Vocabulary simplification** — удалить пресеты, дефолтный customVocabulary, merge при миграции.
7. **Onboarding v2** — экран миграции, auto-map настроек, удаление старых GGML.

---

## 13. Metrics (как проверить что стало лучше)

После реализации замерить на M3+ на типичном vibecoding сценарии (10-секундная фраза с 3-4 техническими терминами):

| Метрика | v1 (baseline) | v2 (target) |
|---------|---------------|-------------|
| End-to-end latency (keyUp → text in cursor) | ~2.5с (medium GGML) | <1с |
| WER на mixed рус+англ | ~15% (оценка) | <8% |
| Термин корректно капитализирован | ~30% | >90% |
| Заполнители в финальном тексте | частые | ≤1% |
| Battery impact за 1 час активной диктовки | baseline | -30% (ANE vs GPU) |

Метрики замерить на 10 реальных записях пользователя до и после миграции.
