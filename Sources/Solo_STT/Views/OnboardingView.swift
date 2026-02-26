import SwiftUI

struct OnboardingView: View {
    @Bindable var appState: AppState
    let modelService: ModelService
    @State private var currentStep: Int = 1
    @State private var selectedModel: WhisperModel = WhisperModel.defaultModel
    @State private var downloadError: String?
    @State private var isDownloading: Bool = false
    @State private var testResult: String?
    @State private var accessibilityTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 8) {
                ForEach(1...3, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            switch currentStep {
            case 1:
                permissionsStep
            case 2:
                modelSelectionStep
            case 3:
                readyStep
            default:
                EmptyView()
            }
        }
        .frame(width: 500, height: 450)
        .onAppear {
            startAccessibilityPolling()
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
        }
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            Text("Добро пожаловать в Solo STT")
                .font(.title)
                .fontWeight(.bold)

            Text("Голосовой ввод текста без интернета")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer().frame(height: 8)

            // Accessibility
            permissionRow(
                title: "Accessibility",
                description: "Необходимо для глобальных горячих клавиш и вставки текста",
                isGranted: appState.accessibilityGranted,
                requestAction: {
                    PermissionService.requestAccessibility()
                },
                openSettingsAction: {
                    PermissionService.openAccessibilitySettings()
                }
            )

            // Microphone
            permissionRow(
                title: "Микрофон",
                description: "Необходимо для записи голоса",
                isGranted: appState.microphoneGranted,
                requestAction: {
                    Task {
                        let granted = await PermissionService.requestMicrophone()
                        await MainActor.run {
                            appState.microphoneGranted = granted
                        }
                    }
                },
                openSettingsAction: {
                    PermissionService.openMicrophoneSettings()
                }
            )

            Spacer()

            Button("Далее") {
                currentStep = 2
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appState.allPermissionsGranted)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
    }

    private func permissionRow(
        title: String,
        description: String,
        isGranted: Bool,
        requestAction: @escaping () -> Void,
        openSettingsAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isGranted ? .green : .red)
                .font(.title2)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isGranted {
                VStack(spacing: 4) {
                    Button("Запросить") {
                        requestAction()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Открыть настройки") {
                        openSettingsAction()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isGranted ? Color.green.opacity(0.05) : Color.red.opacity(0.05))
        )
    }

    // MARK: - Step 2: Model Selection + Download

    private var modelSelectionStep: some View {
        VStack(spacing: 16) {
            Text("Выберите модель")
                .font(.title)
                .fontWeight(.bold)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(WhisperModel.all) { model in
                        modelRow(model)
                    }
                }
            }
            .frame(maxHeight: 200)

            // Download state
            if isDownloading {
                downloadProgressView
            } else if let error = downloadError {
                downloadErrorView(error)
            } else {
                Button("Скачать") {
                    startDownload()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func modelRow(_ model: WhisperModel) -> some View {
        Button {
            if !isDownloading {
                selectedModel = model
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.headline)
                    Text(model.size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model == selectedModel {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        model == selectedModel ? Color.accentColor : Color.gray.opacity(0.2),
                        lineWidth: model == selectedModel ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDownloading)
    }

    private var downloadProgressView: some View {
        VStack(spacing: 8) {
            if case .downloading(let progress) = appState.modelState {
                ProgressView(value: progress) {
                    Text("Скачивание: \(Int(progress * 100))%")
                        .font(.caption)
                }
                .progressViewStyle(.linear)
            } else if case .loading = appState.modelState {
                ProgressView()
                    .controlSize(.small)
                Text("Загрузка модели...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private func downloadErrorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Button("Повторить") {
                downloadError = nil
                startDownload()
            }
            .buttonStyle(.borderedProminent)

            Text("Вы также можете скачать модель вручную и поместить в ~/Library/Application Support/Solo_STT/models/")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func startDownload() {
        isDownloading = true
        downloadError = nil
        appState.selectedModel = selectedModel.id

        Task {
            do {
                try await modelService.downloadAndLoad(variant: selectedModel.id)
                await MainActor.run {
                    isDownloading = false
                    currentStep = 3
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Модель загружена!")
                .font(.title)
                .fontWeight(.bold)

            Text("Модель готова к работе")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let result = testResult {
                GroupBox("Тест транскрипции") {
                    Text(result)
                        .font(.body)
                        .padding(8)
                }
            }

            Spacer()

            Button("Готово") {
                appState.hasCompletedOnboarding = true
                NSApplication.shared.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Helpers

    private func startAccessibilityPolling() {
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let granted = PermissionService.checkAccessibility()
            if granted != appState.accessibilityGranted {
                appState.accessibilityGranted = granted
            }
        }
    }
}
