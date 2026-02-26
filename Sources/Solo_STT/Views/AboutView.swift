import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Solo STT")
                .font(.title)
                .fontWeight(.bold)

            Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 4) {
                Text("Дмитрий Смирнов")
                    .font(.headline)

                Link("tmasolo0@gmail.com", destination: URL(string: "mailto:tmasolo0@gmail.com")!)
                    .font(.subheadline)
            }

            Spacer()
                .frame(height: 8)
        }
        .padding(24)
        .frame(width: 300, height: 300)
    }
}
