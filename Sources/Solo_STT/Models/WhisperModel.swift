import Foundation

struct WhisperModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let size: String
    let isRecommended: Bool

    /// Base URL for downloading GGML models from HuggingFace
    static let baseDownloadURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    /// Local directory for storing downloaded models
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Solo_STT/models", isDirectory: true)
    }

    var downloadURL: URL {
        URL(string: Self.baseDownloadURL + id)!
    }

    var localURL: URL {
        Self.modelsDirectory.appendingPathComponent(id)
    }

    /// CoreML encoder filename: ggml-medium.bin → ggml-medium-encoder.mlmodelc
    var coreMLEncoderName: String {
        let base = (id as NSString).deletingPathExtension  // "ggml-medium"
        return "\(base)-encoder.mlmodelc"
    }

    var coreMLEncoderZipURL: URL {
        URL(string: Self.baseDownloadURL + coreMLEncoderName + ".zip")!
    }

    var coreMLEncoderLocalDir: URL {
        Self.modelsDirectory.appendingPathComponent(coreMLEncoderName, isDirectory: true)
    }

    static let all: [WhisperModel] = [
        WhisperModel(
            id: "ggml-small.bin",
            displayName: "Small",
            size: "~460 MB",
            isRecommended: false
        ),
        WhisperModel(
            id: "ggml-medium.bin",
            displayName: "Medium (рекомендуется)",
            size: "~1.5 GB",
            isRecommended: true
        ),
    ]

    static var defaultModel: WhisperModel {
        all.first(where: { $0.isRecommended }) ?? all[0]
    }
}
