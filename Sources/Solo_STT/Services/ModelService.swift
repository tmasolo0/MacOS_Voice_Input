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
            DiagnosticLogger.shared.info(
                "Downloading \(variant) → \(modelsDirectory.path)",
                category: "Model"
            )

            _ = try await WhisperKit.download(
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
        let modelFolder = modelsDirectory.appendingPathComponent(variant)
        try await transcriber.load(
            modelFolder: modelFolder,
            variant: variant,
            prewarm: true
        )
        appState.modelState = .ready
        DiagnosticLogger.shared.info(
            "Model \(variant) loaded and ready",
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
