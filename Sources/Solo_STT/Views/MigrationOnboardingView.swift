import SwiftUI

struct MigrationOnboardingView: View {
    let appState: AppState
    let modelService: ModelService
    let onDismiss: () -> Void

    @State private var deleteLegacy: Bool = true
    @State private var downloading: Bool = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Solo STT v2.0")
                .font(.largeTitle).bold()

            Text("Обновили движок на WhisperKit (Neural Engine).")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Label("В 2-3 раза быстрее", systemImage: "bolt.fill")
                Label("Меньше расход батареи", systemImage: "battery.100")
                Label("Лучше распознаёт технические термины", systemImage: "text.cursor")
            }
            .font(.callout)

            Divider()

            Text("Нужно скачать новую модель (~1.5 GB).")

            Toggle("Удалить старые GGML-модели (освободит ~2 GB)", isOn: $deleteLegacy)
                .toggleStyle(.checkbox)

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button("Позже") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Скачать модель") {
                    Task { await download() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(downloading)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func download() async {
        downloading = true
        defer { downloading = false }
        do {
            try await modelService.downloadAndLoad(variant: WhisperModel.turbo.rawValue)
            if deleteLegacy {
                modelService.deleteLegacyGgmlModels()
            }
            onDismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
