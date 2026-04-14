import Foundation
import Observation
import WhisperKit

@Observable
@MainActor
final class ModelService {
    enum ModelError: LocalizedError {
        case unknownVariant(String)
        var errorDescription: String? {
            switch self {
            case .unknownVariant(let v): return "Unknown model variant: \(v)"
            }
        }
    }

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

    /// Локальный путь к модели после snapshot download.
    /// HubApi кладёт снэпшот в `downloadBase/<repoId>/<folderName>/`.
    private func localModelFolder(_ model: WhisperModel) -> URL {
        modelsDirectory
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(model.folderName)
    }

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        let encoder = localModelFolder(model).appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    func downloadAndLoad(variant: String) async throws {
        guard let model = WhisperModel(rawValue: variant) else {
            throw ModelError.unknownVariant(variant)
        }

        let modelFolder: URL
        if isModelDownloaded(model) {
            modelFolder = localModelFolder(model)
        } else {
            appState.modelState = .downloading(progress: 0)
            DiagnosticLogger.shared.info(
                "Downloading \(variant) → \(modelsDirectory.path)",
                category: "Model"
            )

            modelFolder = try await WhisperKit.download(
                variant: variant,
                downloadBase: modelsDirectory,
                useBackgroundSession: false,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: { progress in
                    Task { @MainActor in
                        self.appState.modelState = .downloading(
                            progress: progress.fractionCompleted
                        )
                    }
                }
            )
        }

        appState.modelState = .loading
        try await transcriber.load(
            modelFolder: modelFolder,
            variant: variant,
            prewarm: true
        )
        appState.modelState = .ready
        DiagnosticLogger.shared.info(
            "Model \(variant) loaded from \(modelFolder.path)",
            category: "Model"
        )
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
}
