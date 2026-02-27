import SwiftUI

struct SettingsView: View {
    var appState: AppState
    var modelService: ModelService
    var onHotkeyChanged: (() -> Void)?

    @State private var audioDevices: [AudioInputDevice] = []
    @State private var isRecordingHotkey: Bool = false
    @State private var hotkeyMonitor: Any?
    @State private var apiKey: String = ""

    private var languageOptions: [(value: String, label: String)] {
        [
            ("auto", "Авто-определение"),
            ("ru", "Русский"),
            ("en", "English"),
            ("de", "Deutsch"),
            ("fr", "Français"),
            ("es", "Español"),
            ("uk", "Українська"),
        ]
    }

    var body: some View {
        Form {
            // MARK: - Провайдер
            Section("Провайдер") {
                Picker("Транскрипция", selection: Binding(
                    get: { appState.transcriptionProvider },
                    set: { appState.transcriptionProvider = $0 }
                )) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }

                if appState.currentProvider == .cloud {
                    Picker("Сервис", selection: Binding(
                        get: { appState.cloudService },
                        set: { newValue in
                            appState.cloudService = newValue
                            loadAPIKey()
                        }
                    )) {
                        Text("OpenAI").tag("openai")
                        Text("Groq").tag("groq")
                    }

                    SecureField("API-ключ", text: $apiKey)
                        .onChange(of: apiKey) { _, newValue in
                            let key = appState.cloudKeychainKey
                            if newValue.isEmpty {
                                KeychainService.delete(key: key)
                            } else {
                                _ = KeychainService.save(key: key, value: newValue)
                            }
                        }
                }

                if appState.currentProvider == .customServer {
                    TextField("URL сервера", text: Binding(
                        get: { appState.customEndpointURL },
                        set: { appState.customEndpointURL = $0 }
                    ))
                    Text("POST /transcribe с полем file (например: http://192.168.1.100:8000)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    SecureField("API-ключ (необязательно)", text: $apiKey)
                        .onChange(of: apiKey) { _, newValue in
                            let key = appState.currentProvider.keychainKey
                            if newValue.isEmpty {
                                KeychainService.delete(key: key)
                            } else {
                                _ = KeychainService.save(key: key, value: newValue)
                            }
                        }
                }

                Picker("Язык", selection: Binding(
                    get: { appState.transcriptionLanguage },
                    set: { appState.transcriptionLanguage = $0 }
                )) {
                    ForEach(languageOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
            }
            .onChange(of: appState.transcriptionProvider) { _, _ in
                loadAPIKey()
            }

            // MARK: - Распознавание (local only)
            if appState.currentProvider == .local {
                Section("Распознавание") {
                    Picker("Модель", selection: Binding(
                        get: { appState.selectedModel },
                        set: { switchModel($0) }
                    )) {
                        ForEach(WhisperModel.all) { model in
                            Text("\(model.displayName) (\(model.size))")
                                .tag(model.id)
                        }
                    }

                    modelStatusView

                    Toggle("Повышенная точность", isOn: Binding(
                        get: { appState.useBeamSearch },
                        set: { appState.useBeamSearch = $0 }
                    ))
                    Text("Beam search — точнее, но медленнее ~20-30%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // MARK: - Словарь (local only)
                Section("Словарь") {
                    ForEach(VocabularyPreset.allCases) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(preset.displayName, isOn: Binding(
                                get: { appState.selectedPresets.contains(preset.rawValue) },
                                set: { enabled in
                                    if enabled {
                                        if !appState.selectedPresets.contains(preset.rawValue) {
                                            appState.selectedPresets.append(preset.rawValue)
                                        }
                                    } else {
                                        appState.selectedPresets.removeAll { $0 == preset.rawValue }
                                    }
                                }
                            ))
                            Text(preset.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: Binding(
                            get: { appState.customVocabulary },
                            set: { appState.customVocabulary = $0 }
                        ))
                        .font(.body)
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .background(Color(.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(.separatorColor), lineWidth: 1)
                        )

                        if appState.customVocabulary.isEmpty {
                            Text("Например: Кубернетис, Редис, бэклог, продакшен")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    Text("Свои термины через запятую — помогает Whisper распознавать их правильно")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Горячая клавиша
            Section("Горячая клавиша") {
                HStack {
                    Text("Push-to-talk")
                    Spacer()
                    Button(action: { startRecordingHotkey() }) {
                        Text(isRecordingHotkey
                            ? "Нажмите клавишу..."
                            : HotkeyService.keyName(
                                for: appState.hotkeyKeyCode,
                                isModifier: appState.hotkeyIsModifier
                            )
                        )
                        .frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                }

                if isRecordingHotkey {
                    Text("Escape — отмена")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Аудио и параметры
            Section("Аудиоустройство") {
                Picker("Микрофон", selection: Binding(
                    get: { appState.selectedAudioDeviceUID ?? "" },
                    set: { appState.selectedAudioDeviceUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Системный по умолчанию").tag("")
                    ForEach(audioDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                Toggle("Авто-нормализация громкости", isOn: Binding(
                    get: { appState.audioNormalization },
                    set: { appState.audioNormalization = $0 }
                ))
                Text("Подтягивает тихий микрофон до оптимального уровня (BT наушники)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Дополнительные параметры") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.1f", appState.whisperTemperature))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { appState.whisperTemperature },
                                set: { appState.whisperTemperature = $0 }
                            ),
                            in: 0.0...1.0,
                            step: 0.1
                        )
                        Text("0 = детерминированно, выше = разнообразнее")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Compression ratio")
                            Spacer()
                            Text(String(format: "%.1f", appState.whisperEntropyThreshold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { appState.whisperEntropyThreshold },
                                set: { appState.whisperEntropyThreshold = $0 }
                            ),
                            in: 0.5...5.0,
                            step: 0.1
                        )
                        Text("Фильтр повторов — ниже = строже")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Log probability")
                            Spacer()
                            Text(String(format: "%.1f", appState.whisperLogprobThreshold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { appState.whisperLogprobThreshold },
                                set: { appState.whisperLogprobThreshold = $0 }
                            ),
                            in: -3.0...0.0,
                            step: 0.1
                        )
                        Text("Порог уверенности — выше = строже")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: - Диагностика
            Section("Диагностика") {
                Button("Собрать логи") {
                    let summary = DiagnosticLogger.shared.diagnosticSummary(appState: appState)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                    NSWorkspace.shared.open(DiagnosticLogger.logsDirectory)
                }
                Button("Открыть папку логов") {
                    NSWorkspace.shared.open(DiagnosticLogger.logsDirectory)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 620)
        .onAppear {
            audioDevices = AudioDeviceService.inputDevices()
            loadAPIKey()
        }
        .onDisappear {
            stopRecordingHotkey()
        }
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch appState.modelState {
        case .notLoaded:
            Label("Модель не загружена", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Загрузка модели...")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Готово", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func loadAPIKey() {
        switch appState.currentProvider {
        case .cloud:
            apiKey = KeychainService.load(key: appState.cloudKeychainKey) ?? ""
        case .customServer:
            apiKey = KeychainService.load(key: appState.currentProvider.keychainKey) ?? ""
        case .local:
            apiKey = ""
        }
    }

    private func switchModel(_ modelId: String) {
        guard case .idle = appState.recordingState else { return }
        appState.selectedModel = modelId
        Task {
            do {
                try await modelService.downloadAndLoad(variant: modelId)
            } catch {
                DiagnosticLogger.shared.error("Failed to switch model: \(error)", category: "Model")
            }
        }
    }

    // MARK: - Hotkey Recording

    private func startRecordingHotkey() {
        isRecordingHotkey = true
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    // Escape — cancel
                    stopRecordingHotkey()
                    return event
                }
                let code = Int(event.keyCode)
                appState.hotkeyKeyCode = code
                appState.hotkeyIsModifier = false
                stopRecordingHotkey()
                onHotkeyChanged?()
                return nil  // Consume the event
            }

            if event.type == .flagsChanged {
                let code = Int(event.keyCode)
                guard HotkeyService.modifierKeyCodes.contains(code) else { return event }
                appState.hotkeyKeyCode = code
                appState.hotkeyIsModifier = true
                stopRecordingHotkey()
                onHotkeyChanged?()
                return nil
            }

            return event
        }
    }

    private func stopRecordingHotkey() {
        isRecordingHotkey = false
        if let hotkeyMonitor {
            NSEvent.removeMonitor(hotkeyMonitor)
        }
        hotkeyMonitor = nil
    }
}
