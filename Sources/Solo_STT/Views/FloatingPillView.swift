import SwiftUI
import AppKit

// MARK: - Main View

struct FloatingPillView: View {
    let recordingState: AppState.RecordingState

    var body: some View {
        HStack(spacing: 8) {
            // App icon
            ZStack {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                if case .recording = recordingState {
                    PulsingRing()
                }
            }

            switch recordingState {
            case .recording:
                RecordingDot()
                Text("Запись")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)

            case .transcribing:
                Text("Обработка")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                BouncingDots()

            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.3)
            }
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }
}

// MARK: - Visual Effect

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - Pulsing Ring

struct PulsingRing: View {
    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(Color.red, lineWidth: 2)
            .frame(width: 28, height: 28)
            .scaleEffect(animate ? 1.3 : 1.0)
            .opacity(animate ? 0.2 : 0.6)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
    }
}

// MARK: - Recording Dot

struct RecordingDot: View {
    @State private var visible = true

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(visible ? 1.0 : 0.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

// MARK: - Bouncing Dots

struct BouncingDots: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 4, height: 4)
                    .offset(y: animate ? -3 : 0)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
