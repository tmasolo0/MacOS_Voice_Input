import SwiftUI

struct FloatingPillView: View {
    let appState: AppState
    let levelMonitor: AudioLevelMonitor

    var body: some View {
        HStack(spacing: 6) {
            switch appState.recordingState {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                WaveformBars(levels: levelMonitor.levelHistory)
                Text("REC")
                    .font(.caption2)
                    .monospaced()
            case .transcribing:
                ProgressView()
                    .controlSize(.mini)
                Text("Transcribing…")
                    .font(.caption2)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.caption2)
                    .lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}
