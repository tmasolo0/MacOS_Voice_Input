import Foundation

class CloudTranscriptionClient {

    struct CloudResult {
        let text: String
        let latency: TimeInterval
    }

    enum CloudError: LocalizedError {
        case noAPIKey
        case invalidURL
        case httpError(Int, String)
        case decodingError
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "API-ключ не задан"
            case .invalidURL: return "Некорректный URL эндпоинта"
            case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
            case .decodingError: return "Ошибка разбора ответа API"
            case .networkError(let err): return "Сеть: \(err.localizedDescription)"
            }
        }
    }

    func transcribe(
        audioSamples: [Float],
        baseURL: String,
        apiKey: String?,
        model: String,
        language: String,
        useSimpleAPI: Bool = false,
        prompt: String? = nil
    ) async throws -> CloudResult {
        if useSimpleAPI {
            return try await transcribeSimple(audioSamples: audioSamples, language: language, customURL: baseURL, apiKey: apiKey)
        }

        guard let url = URL(string: "\(baseURL)/audio/transcriptions") else {
            throw CloudError.invalidURL
        }

        guard let apiKey, !apiKey.isEmpty else {
            throw CloudError.noAPIKey
        }

        let wavData = floatSamplesToWAV(audioSamples, sampleRate: 16000)
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        var body = Data()
        body.appendMultipart(boundary: boundary, name: "file", filename: "audio.wav", mimeType: "audio/wav", data: wavData)
        body.appendMultipart(boundary: boundary, name: "model", value: model)
        body.appendMultipart(boundary: boundary, name: "response_format", value: "json")
        if language != "auto" {
            body.appendMultipart(boundary: boundary, name: "language", value: language)
        }
        if let prompt, !prompt.isEmpty {
            body.appendMultipart(boundary: boundary, name: "prompt", value: prompt)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        DiagnosticLogger.shared.info("Cloud request → \(url)", category: "Cloud")
        let startTime = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            DiagnosticLogger.shared.error("Cloud network error: \(error.localizedDescription)", category: "Cloud")
            throw CloudError.networkError(error)
        }
        let latency = Date().timeIntervalSince(startTime)
        DiagnosticLogger.shared.info("Cloud response: \(String(format: "%.0f", latency * 1000))ms", category: "Cloud")

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudError.decodingError
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown error"
            throw CloudError.httpError(httpResponse.statusCode, errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw CloudError.decodingError
        }

        return CloudResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            latency: latency
        )
    }

    // MARK: - Simple STT (no auth, POST /transcribe)

    private func transcribeSimple(audioSamples: [Float], language: String, customURL: String, apiKey: String?) async throws -> CloudResult {
        guard !customURL.isEmpty,
              let url = URL(string: "\(customURL)/transcribe") else {
            throw CloudError.invalidURL
        }

        let wavData = floatSamplesToWAV(audioSamples, sampleRate: 16000)
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.appendMultipart(boundary: boundary, name: "file", filename: "audio.wav", mimeType: "audio/wav", data: wavData)
        if language != "auto" {
            body.appendMultipart(boundary: boundary, name: "language", value: language)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        DiagnosticLogger.shared.info("Custom server request → \(url)", category: "Cloud")
        let startTime = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            DiagnosticLogger.shared.error("Custom server network error: \(error.localizedDescription)", category: "Cloud")
            throw CloudError.networkError(error)
        }
        let latency = Date().timeIntervalSince(startTime)
        DiagnosticLogger.shared.info("Custom server response: \(String(format: "%.0f", latency * 1000))ms", category: "Cloud")

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudError.decodingError
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown error"
            throw CloudError.httpError(httpResponse.statusCode, errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw CloudError.decodingError
        }

        return CloudResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            latency: latency
        )
    }

    // MARK: - WAV Encoding

    private func floatSamplesToWAV(_ samples: [Float], sampleRate: Int) -> Data {
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = Int32(sampleRate * Int(numChannels) * Int(bitsPerSample / 8))
        let blockAlign = Int16(numChannels * (bitsPerSample / 8))
        let dataSize = Int32(samples.count * 2) // 2 bytes per Int16 sample

        var data = Data()

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(Int32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(Int32(16)) // chunk size
        data.appendLittleEndian(Int16(1))  // PCM format
        data.appendLittleEndian(numChannels)
        data.appendLittleEndian(Int32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataSize)

        // Convert Float [-1,1] → Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            data.appendLittleEndian(int16)
        }

        return data
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        withUnsafePointer(to: &le) { ptr in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    mutating func appendMultipart(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
