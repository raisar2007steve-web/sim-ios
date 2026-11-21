import SwiftUI

/// Built-in demo application used only when the repository contains no iOS
/// application source. It gives the remote session something real to show and
/// an obvious target for verifying injected touch input.
@main
struct SimulatorDemoApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var taps = 0
    @State private var typed = ""
    @State private var lastGesture = "none"

    private let accent = Color(red: 0.24, green: 0.86, blue: 0.59)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.12), Color(red: 0.10, green: 0.13, blue: 0.21)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Text("REMOTE SIMULATOR")
                    .font(.caption.weight(.semibold))
                    .tracking(2.4)
                    .foregroundStyle(.secondary)

                Text("\(taps)")
                    .font(.system(size: 96, weight: .thin, design: .rounded))
                    .foregroundStyle(accent)

                Text(taps == 1 ? "tap received" : "taps received")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    TextField("Tap here, then type", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text(typed.isEmpty ? "keyboard input appears here" : typed)
                        .font(.footnote.monospaced())
                        .foregroundStyle(typed.isEmpty ? .tertiary : .secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)

                Text(lastGesture)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(28)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            taps += 1
            lastGesture = "tap received"
        }
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dx) > abs(dy) {
                        lastGesture = dx > 0 ? "swipe right" : "swipe left"
                    } else {
                        lastGesture = dy > 0 ? "swipe down" : "swipe up"
                    }
                }
        )
    }
}
