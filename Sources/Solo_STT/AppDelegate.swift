import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItemManager: StatusItemManager?
    var modelService: ModelService?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var hotkeyService: HotkeyService?
    private var soundFeedbackService: SoundFeedbackService?
    private var floatingPillManager: FloatingPillManager?
    private var audioRecordingService: AudioRecordingService?
    private var transcriptionService: TranscriptionService?
    private var textCleanupService: TextCleanupService?
    private var vadService: VADService?
    private var audioLevelMonitor: AudioLevelMonitor?
    private var textInsertionService: TextInsertionService?
    private var targetApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.performMigrationIfNeeded()

        // Защита от двойного запуска
        let dominated = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if dominated.count > 1 {
            DiagnosticLogger.shared.warning("Another instance already running, quitting", category: "App")
            NSApp.terminate(nil)
            return
        }

        modelService = ModelService(appState: appState)
        statusItemManager = StatusItemManager(appState: appState, modelService: modelService!)
        statusItemManager?.onOpenSettings = { [weak self] in
            self?.showSettingsWindow()
        }
        statusItemManager?.onOpenAbout = { [weak self] in
            self?.showAboutWindow()
        }
        statusItemManager?.setup()

        // Create services
        soundFeedbackService = SoundFeedbackService()
        audioRecordingService = AudioRecordingService()
        audioRecordingService?.selectedDeviceUID = appState.selectedAudioDeviceUID
        audioRecordingService?.normalizeAudio = appState.audioNormalization
        transcriptionService = TranscriptionService(modelService: modelService!, appState: appState)
        textCleanupService = TextCleanupService()
        vadService = VADService()
        textInsertionService = TextInsertionService()

        audioLevelMonitor = AudioLevelMonitor()
        audioRecordingService?.levelMonitor = audioLevelMonitor

        floatingPillManager = FloatingPillManager(
            appState: appState,
            levelMonitor: audioLevelMonitor!
        )
        floatingPillManager?.start()

        // Wire hotkey callbacks
        hotkeyService = HotkeyService()
        hotkeyService?.keyCode = Int64(appState.hotkeyKeyCode)
        hotkeyService?.isModifier = appState.hotkeyIsModifier
        hotkeyService?.onKeyDown = { [weak self] in
            self?.handleRecordingStart()
        }
        hotkeyService?.onKeyUp = { [weak self] in
            self?.handleRecordingStop()
        }
        hotkeyService?.onSecureInputChanged = { [weak self] isSecure in
            self?.appState.isSecureInputActive = isSecure
        }
        hotkeyService?.start()

        checkPermissions()

        // Start audio engine early so Bluetooth devices have time to activate
        audioRecordingService?.ensureEngineRunning()

        if !appState.hasCompletedOnboarding {
            showOnboardingWindow()
        } else if appState.currentProvider == .local {
            // Local mode — load model in background
            let variant = appState.selectedModel
            DiagnosticLogger.shared.info("Loading model: \(variant)", category: "Model")
            Task {
                do {
                    try await modelService?.downloadAndLoad(variant: variant)
                } catch {
                    DiagnosticLogger.shared.error("Failed to load model: \(error)", category: "Model")
                }
            }
        } else {
            DiagnosticLogger.shared.info("Provider: \(appState.currentProvider.displayName), skipping local model load", category: "App")
        }
    }

    private func showOnboardingWindow() {
        guard let modelService else { return }

        let onboardingView = OnboardingView(
            appState: appState,
            modelService: modelService
        )
        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Solo STT — Настройка"
        window.setContentSize(NSSize(width: 500, height: 450))
        window.center()
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApplication.shared.activate(ignoringOtherApps: true)

        onboardingWindow = window
    }

    func showSettingsWindow() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        guard let modelService else { return }
        let settingsView = SettingsView(
            appState: appState,
            modelService: modelService,
            onHotkeyChanged: { [weak self] in
                guard let self else { return }
                self.hotkeyService?.keyCode = Int64(self.appState.hotkeyKeyCode)
                self.hotkeyService?.isModifier = self.appState.hotkeyIsModifier
            }
        )
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Solo STT — Настройки"
        window.setContentSize(NSSize(width: 420, height: 620))
        window.center()
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 420, height: 500)
        window.maxSize = NSSize(width: 420, height: 800)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApplication.shared.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    private func showAboutWindow() {
        if let aboutWindow, aboutWindow.isVisible {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: AboutView())

        let window = NSWindow(contentViewController: hostingController)
        window.title = "О программе"
        window.setContentSize(NSSize(width: 300, height: 300))
        window.center()
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApplication.shared.activate(ignoringOtherApps: true)

        aboutWindow = window
    }

    // MARK: - Recording Pipeline

    private func handleRecordingStart() {
        // Guard: must be ready to transcribe (local model loaded OR cloud with API key)
        guard appState.isReadyToTranscribe else {
            DiagnosticLogger.shared.warning("Not ready to transcribe, ignoring hotkey", category: "Recording")
            return
        }
        // Allow restart from error state
        if case .error = appState.recordingState {
            appState.recordingState = .idle
        }
        // Guard: must be idle
        guard case .idle = appState.recordingState else { return }

        // Remember the frontmost app before recording starts
        targetApp = NSWorkspace.shared.frontmostApplication

        // Ensure audio engine is running before starting recording
        if let engineError = audioRecordingService?.ensureEngineRunning() {
            self.appState.recordingState = .error(engineError.localizedDescription)
            DiagnosticLogger.shared.error("Engine not ready: \(engineError.localizedDescription)", category: "Audio")
            return
        }

        // Sync settings before recording
        audioRecordingService?.normalizeAudio = appState.audioNormalization

        // Start recording IMMEDIATELY to not lose first words
        do {
            try self.audioRecordingService?.startRecording()
            self.appState.recordingState = .recording
            // Play sound AFTER recording starts (brief Tink won't affect transcription)
            soundFeedbackService?.playStart()
            DiagnosticLogger.shared.info("Recording started", category: "Recording")
        } catch {
            self.appState.recordingState = .error(error.localizedDescription)
            DiagnosticLogger.shared.error("Failed to start recording: \(error)", category: "Recording")
        }
    }

    private func handleRecordingStop() {
        // Guard: must be recording
        guard case .recording = appState.recordingState else { return }

        guard let audioRecordingService else { return }

        // Grace period to capture trailing audio
        DispatchQueue.main.asyncAfter(deadline: .now() + AudioRecordingService.stopDelay) { [weak self] in
            guard let self else { return }
            let result = audioRecordingService.stopRecording()
            self.audioLevelMonitor?.reset()
            self.processRecordingResult(result)
        }
    }

    private func processRecordingResult(_ result: AudioRecordingService.AudioRecordingResult) {
        switch result {
        case .tooShort(let duration):
            DiagnosticLogger.shared.info("Recording too short (\(String(format: "%.0f", duration * 1000))ms), skipping", category: "Recording")
            appState.recordingState = .idle
            return

        case .error(let error):
            appState.recordingState = .error(error.localizedDescription)
            soundFeedbackService?.playStop()
            return

        case .success(let samples, let duration):
            // Play stop sound
            soundFeedbackService?.playStop()
            DiagnosticLogger.shared.info("Recording stopped (\(String(format: "%.1f", duration))s), transcribing...", category: "Recording")

            // Transcribe, process, and insert asynchronously
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

                    await MainActor.run {
                        self.appState.lastTranscription = processedText
                    }

                    if processedText.isEmpty {
                        await MainActor.run {
                            self.appState.recordingState = .idle
                        }
                        DiagnosticLogger.shared.info("Empty transcription after processing, skipping insertion", category: "Transcription")
                        return
                    }

                    DiagnosticLogger.shared.info("Transcription (\(result.language), \(String(format: "%.0f", result.latency * 1000))ms): \(processedText)", category: "Transcription")

                    // Insert text at cursor
                    let isSecure = await MainActor.run { self.appState.isSecureInputActive }
                    await MainActor.run {
                        self.appState.insertionState = isSecure ? .clipboardOnly : .inserting
                    }

                    await self.textInsertionService?.insert(processedText, secureInput: isSecure, targetApp: self.targetApp)
                    self.targetApp = nil

                    await MainActor.run {
                        self.appState.insertionState = .idle
                        self.appState.recordingState = .idle
                    }
                } catch {
                    await MainActor.run {
                        self.appState.insertionState = .idle
                        self.appState.recordingState = .error(error.localizedDescription)
                        DiagnosticLogger.shared.error("Transcription failed: \(error)", category: "Transcription")
                    }
                }
            }
        }
    }

    // MARK: - Permissions

    private func checkPermissions() {
        appState.accessibilityGranted = PermissionService.checkAccessibility()

        if !appState.accessibilityGranted {
            DiagnosticLogger.shared.warning("Accessibility permission not granted", category: "Permissions")
        } else {
            DiagnosticLogger.shared.info("Accessibility permission granted", category: "Permissions")
        }

        Task {
            let micGranted = await PermissionService.checkMicrophone()
            await MainActor.run {
                appState.microphoneGranted = micGranted
                if micGranted {
                    DiagnosticLogger.shared.info("Microphone permission granted", category: "Permissions")
                } else {
                    DiagnosticLogger.shared.warning("Microphone permission not granted", category: "Permissions")
                }
            }
        }
    }
}
