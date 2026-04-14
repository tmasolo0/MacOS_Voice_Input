import SwiftUI

struct WaveformBars: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(levels.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.primary)
                    .frame(width: 2, height: max(2, CGFloat(levels[i]) * 16))
                    .animation(.easeOut(duration: 0.08), value: levels[i])
            }
        }
        .frame(height: 16)
    }
}
