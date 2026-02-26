import Foundation
import SwiftWhisper

class ModelService: NSObject {
    private(set) var whisper: Whisper?
    private let appState: AppState

    private static let modelVariantKey = "downloadedModelVariant"

    private var downloadTask: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<URL, any Error>?
    private var pendingDownloadLocalURL: URL?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Check if model file exists on disk
    func hasCachedModel(variant: String) -> Bool {
        guard let model = WhisperModel.all.first(where: { $0.id == variant }) else {
            return false
        }
        return FileManager.default.fileExists(atPath: model.localURL.path)
    }

    func downloadModel(variant: String) async throws {
        guard let model = WhisperModel.all.first(where: { $0.id == variant }) else {
            throw ModelServiceError.unknownModel(variant)
        }

        // Ensure models directory exists
        try FileManager.default.createDirectory(
            at: WhisperModel.modelsDirectory,
            withIntermediateDirectories: true
        )

        await MainActor.run {
            appState.modelState = .downloading(progress: 0)
        }

        do {
            let localURL = try await downloadFile(from: model.downloadURL, to: model.localURL)
            UserDefaults.standard.set(variant, forKey: Self.modelVariantKey)
            print("[Solo_STT] Model downloaded to: \(localURL.path)")
        } catch {
            await MainActor.run {
                appState.modelState = .error(error.localizedDescription)
            }
            throw error
        }
    }

    func loadModel(variant: String) async throws {
        guard let model = WhisperModel.all.first(where: { $0.id == variant }) else {
            throw ModelServiceError.unknownModel(variant)
        }

        guard FileManager.default.fileExists(atPath: model.localURL.path) else {
            throw ModelServiceError.modelFileNotFound
        }

        await MainActor.run {
            appState.modelState = .loading
        }

        let startTime = Date()
        print("[Solo_STT] Loading model from: \(model.localURL.path)")

        whisper = Whisper(fromFileURL: model.localURL)

        let elapsed = Date().timeIntervalSince(startTime)
        print("[Solo_STT] Model loaded in \(String(format: "%.1f", elapsed))s")

        await MainActor.run {
            appState.modelState = .ready
        }
    }

    func downloadAndLoad(variant: String) async throws {
        if hasCachedModel(variant: variant) {
            print("[Solo_STT] Model cached, skipping download")
        } else {
            try await downloadModel(variant: variant)
        }
        try await loadModel(variant: variant)

        // Download CoreML encoder in background (non-blocking)
        if let model = WhisperModel.all.first(where: { $0.id == variant }) {
            Task {
                await downloadCoreMLEncoderIfNeeded(model: model)
            }
        }
    }

    /// Download and unzip CoreML encoder if not already present
    func downloadCoreMLEncoderIfNeeded(model: WhisperModel) async {
        let encoderDir = model.coreMLEncoderLocalDir
        if FileManager.default.fileExists(atPath: encoderDir.path) {
            print("[Solo_STT] CoreML encoder already exists: \(encoderDir.lastPathComponent)")
            return
        }

        print("[Solo_STT] Downloading CoreML encoder: \(model.coreMLEncoderZipURL.lastPathComponent)")
        await MainActor.run {
            appState.modelState = .downloading(progress: 0)
        }

        let zipURL = model.localURL.deletingLastPathComponent()
            .appendingPathComponent(model.coreMLEncoderName + ".zip")

        do {
            let downloadedURL = try await downloadFile(from: model.coreMLEncoderZipURL, to: zipURL)
            print("[Solo_STT] CoreML encoder downloaded, unzipping...")

            // Unzip using Process (unzip command)
            try unzipFile(at: downloadedURL, to: model.localURL.deletingLastPathComponent())

            // Remove zip after extraction
            try? FileManager.default.removeItem(at: downloadedURL)

            if FileManager.default.fileExists(atPath: encoderDir.path) {
                print("[Solo_STT] CoreML encoder ready: \(encoderDir.lastPathComponent)")
            } else {
                print("[Solo_STT] Warning: CoreML encoder dir not found after unzip")
            }
        } catch {
            print("[Solo_STT] CoreML encoder download failed: \(error.localizedDescription)")
        }

        await MainActor.run {
            appState.modelState = .ready
        }
    }

    private func unzipFile(at zipURL: URL, to destDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", destDir.path]
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ModelServiceError.downloadFailed("unzip failed with status \(process.terminationStatus)")
        }
    }

    // MARK: - Download with progress

    private func downloadFile(from remoteURL: URL, to localURL: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            self.pendingDownloadLocalURL = localURL

            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: remoteURL)
            self.downloadTask = task
            task.resume()
        }
    }

    // MARK: - Errors

    enum ModelServiceError: LocalizedError {
        case modelNotLoaded
        case modelFileNotFound
        case unknownModel(String)
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "Модель не загружена"
            case .modelFileNotFound:
                return "Файл модели не найден. Сначала скачайте модель."
            case .unknownModel(let id):
                return "Неизвестная модель: \(id)"
            case .downloadFailed(let reason):
                return "Ошибка скачивания: \(reason)"
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelService: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let localURL = pendingDownloadLocalURL else {
            downloadContinuation?.resume(throwing: ModelServiceError.downloadFailed("Не удалось определить путь сохранения"))
            downloadContinuation = nil
            return
        }

        do {
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: location, to: localURL)
            downloadContinuation?.resume(returning: localURL)
        } catch {
            downloadContinuation?.resume(throwing: error)
        }
        downloadContinuation = nil
        pendingDownloadLocalURL = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.appState.modelState = .downloading(progress: progress)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            downloadContinuation?.resume(throwing: error)
            downloadContinuation = nil
            pendingDownloadLocalURL = nil
        }
    }
}
