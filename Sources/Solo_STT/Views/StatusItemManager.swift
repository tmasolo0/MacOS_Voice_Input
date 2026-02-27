import AppKit

class StatusItemManager: NSObject {
    private var statusItem: NSStatusItem?
    private var appState: AppState
    private var modelService: ModelService
    private var observationTimer: Timer?
    var onOpenSettings: (() -> Void)?
    var onOpenAbout: (() -> Void)?

    init(appState: AppState, modelService: ModelService) {
        self.appState = appState
        self.modelService = modelService
        super.init()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "Solo STT"
            )
        }

        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: "Статус: проверка...", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Подменю провайдеров (3 пункта)
        let providerItem = NSMenuItem(title: "Провайдер: \(appState.currentProvider.displayName)", action: nil, keyEquivalent: "")
        providerItem.tag = 300
        let providerSubmenu = NSMenu()

        for provider in TranscriptionProvider.allCases {
            let item = NSMenuItem(
                title: provider.displayName,
                action: #selector(selectProvider(_:)),
                keyEquivalent: ""
            )
            item.representedObject = provider.rawValue
            item.target = self
            item.state = (provider == appState.currentProvider) ? .on : .off
            providerSubmenu.addItem(item)
        }

        providerItem.submenu = providerSubmenu
        menu.addItem(providerItem)

        // Подменю моделей — только скачанные + "Скачать модель..."
        let modelItem = NSMenuItem(title: "Модель", action: nil, keyEquivalent: "")
        modelItem.tag = 200
        let modelSubmenu = NSMenu()
        rebuildModelSubmenu(modelSubmenu)
        modelItem.submenu = modelSubmenu
        menu.addItem(modelItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Настройки...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(
            title: "О программе",
            action: #selector(openAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "Выход",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem?.menu = menu

        startObservingState()
    }

    private func rebuildModelSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()

        let downloadedModels = WhisperModel.all.filter {
            FileManager.default.fileExists(atPath: $0.localURL.path)
        }

        for model in downloadedModels {
            let item = NSMenuItem(
                title: "\(model.displayName) (\(model.size))",
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            item.representedObject = model.id
            item.target = self
            item.state = (model.id == appState.selectedModel) ? .on : .off
            submenu.addItem(item)
        }

        if !downloadedModels.isEmpty {
            submenu.addItem(NSMenuItem.separator())
        }

        let downloadItem = NSMenuItem(
            title: "Скачать модель...",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        downloadItem.target = self
        submenu.addItem(downloadItem)
    }

    // MARK: - State Observation

    private func startObservingState() {
        observationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.syncStateToUI()
        }
    }

    private func syncStateToUI() {
        let recordingState = appState.recordingState
        let modelState = appState.modelState

        switch recordingState {
        case .recording:
            updateIcon(symbolName: "mic.badge.plus")
            updateStatusText("Запись...")
            return
        case .transcribing:
            updateIcon(symbolName: "hourglass")
            updateStatusText("Транскрипция...")
            return
        case .error(let msg):
            updateIcon(symbolName: "exclamationmark.triangle.fill")
            let short = msg.prefix(40)
            updateStatusText("Ошибка: \(short)")
            return
        case .idle:
            break
        }

        let provider = appState.currentProvider
        let providerLabel = provider == .local ? "" : " \(provider.shortLabel)"

        // Cloud/customServer — skip local model state
        if provider.isCloud {
            let isReady = appState.isReadyToTranscribe
            if isReady {
                updateIcon(symbolName: "mic.fill")
                updateButtonTitle(providerLabel)
                if appState.isSecureInputActive {
                    updateStatusText("Secure Input активен")
                } else {
                    updateStatusText("Готов · \(provider.displayName)")
                }
            } else {
                updateIcon(symbolName: "exclamationmark.triangle.fill")
                updateButtonTitle(providerLabel)
                if provider == .cloud {
                    updateStatusText("API-ключ не задан")
                } else {
                    updateStatusText("URL сервера не задан")
                }
            }
            syncCheckmarks()
            return
        }

        if appState.isSecureInputActive, case .ready = modelState {
            updateIcon(symbolName: "mic.fill")
            updateButtonTitle("")
            updateStatusText("Secure Input активен")
            return
        }

        switch modelState {
        case .notLoaded:
            updateIcon(symbolName: "arrow.down.circle")
            updateButtonTitle("")
            updateStatusText("Модель не загружена")
        case .downloading(let progress):
            updateIcon(symbolName: "arrow.down.circle")
            updateButtonTitle(" \(Int(progress * 100))%")
            updateStatusText("Скачивание: \(Int(progress * 100))%")
        case .loading:
            updateIcon(symbolName: "hourglass")
            updateButtonTitle(" ...")
            updateStatusText("Загрузка модели...")
        case .ready:
            updateIcon(symbolName: "mic.fill")
            updateButtonTitle("")
            updateStatusText("Готов · Локальная")
        case .error(let msg):
            updateIcon(symbolName: "exclamationmark.triangle.fill")
            updateButtonTitle("")
            let short = msg.prefix(40)
            updateStatusText("Ошибка: \(short)")
        }

        syncCheckmarks()
    }

    private func syncCheckmarks() {
        guard let menu = statusItem?.menu else { return }

        let currentProvider = appState.currentProvider

        // Update provider menu title
        if let providerItem = menu.item(withTag: 300) {
            providerItem.title = "Провайдер: \(currentProvider.displayName)"
        }

        // Hide model submenu for non-local providers
        if let modelItem = menu.item(withTag: 200) {
            let isLocal = currentProvider == .local
            modelItem.isHidden = !isLocal
            if isLocal, let submenu = modelItem.submenu {
                rebuildModelSubmenu(submenu)
            }
        }

        // Provider checkmarks
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            for subItem in submenu.items {
                if let rawValue = subItem.representedObject as? String,
                   TranscriptionProvider(rawValue: rawValue) != nil {
                    subItem.state = (rawValue == appState.transcriptionProvider) ? .on : .off
                }
            }
        }
    }

    private func updateIcon(symbolName: String) {
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Solo STT"
        )
    }

    private func updateButtonTitle(_ title: String) {
        statusItem?.button?.title = title
    }

    func updateStatusText(_ text: String) {
        if let menu = statusItem?.menu,
           let item = menu.item(withTag: 100) {
            item.title = text
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else { return }

        guard case .idle = appState.recordingState else {
            DiagnosticLogger.shared.warning("Cannot switch model during recording", category: "Model")
            return
        }

        appState.selectedModel = modelId
        DiagnosticLogger.shared.info("Selected model: \(modelId)", category: "Model")

        Task {
            do {
                try await modelService.downloadAndLoad(variant: modelId)
            } catch {
                DiagnosticLogger.shared.error("Failed to load model: \(error)", category: "Model")
            }
        }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let provider = TranscriptionProvider(rawValue: rawValue) else { return }

        guard case .idle = appState.recordingState else {
            DiagnosticLogger.shared.warning("Cannot switch provider during recording", category: "App")
            return
        }

        appState.transcriptionProvider = provider.rawValue
        DiagnosticLogger.shared.info("Selected provider: \(provider.displayName)", category: "App")

        // При переключении на local — загрузить модель
        if provider == .local {
            Task {
                do {
                    try await modelService.downloadAndLoad(variant: appState.selectedModel)
                } catch {
                    DiagnosticLogger.shared.error("Failed to load model: \(error)", category: "Model")
                }
            }
        }
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openAbout() {
        onOpenAbout?()
    }

    deinit {
        observationTimer?.invalidate()
    }
}
