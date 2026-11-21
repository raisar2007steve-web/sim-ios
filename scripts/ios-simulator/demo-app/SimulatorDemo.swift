import SwiftUI

/// Starly Industries demo application.
///
/// Used only when the repository contains no iOS application source of its own:
/// it gives the remote session something real and branded to show, and an
/// obvious target for proving that injected touch, swipes and keyboard input
/// reach the simulator.
@main
struct StarlyDemoApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

private enum Brand {
    static let teal = Color(red: 0.43, green: 0.91, blue: 0.78)
    static let indigo = Color(red: 0.35, green: 0.47, blue: 1.0)
    static let night = Color(red: 0.03, green: 0.05, blue: 0.10)
    static let dusk = Color(red: 0.09, green: 0.11, blue: 0.22)
}

/// The Starly mark: a five-point star with the brand gradient.
struct StarlyMark: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle().strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                    )

                Path { path in
                    let center = CGPoint(x: side / 2, y: side / 2)
                    let outer = side * 0.33
                    let inner = outer * 0.44
                    for index in 0..<10 {
                        let radius = index.isMultiple(of: 2) ? outer : inner
                        let angle = -CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 5
                        let point = CGPoint(
                            x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius
                        )
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Brand.teal, Brand.indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Brand.teal.opacity(0.45), radius: 10, y: 4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Starly Industries logo")
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.42), .white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
    }
}

struct ContentView: View {
    @State private var taps = 0
    @State private var typed = ""
    @State private var gesture = "waiting for input"
    @State private var pulse = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.night, Brand.dusk, Brand.night],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Brand.indigo.opacity(0.35))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: 130, y: -260)
                .ignoresSafeArea()

            Circle()
                .fill(Brand.teal.opacity(0.22))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: -140, y: 340)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                header
                counterCard
                inputCard
                Spacer(minLength: 8)
                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { register() })
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dx) > abs(dy) {
                        gesture = dx > 0 ? "swipe → right" : "swipe ← left"
                    } else {
                        gesture = dy > 0 ? "swipe ↓ down" : "swipe ↑ up"
                    }
                }
        )
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StarlyMark()
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text("STARLY INDUSTRIES")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .tracking(1.6)
                    Text("Remote iOS Simulator")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                LivePill()
            }

            Text("Built by STARLY")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.2)
                .foregroundStyle(Brand.teal)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Brand.teal.opacity(0.12))
                )
                .overlay(
                    Capsule().strokeBorder(Brand.teal.opacity(0.35), lineWidth: 1)
                )
        }
        .foregroundStyle(.white)
    }

    private var counterCard: some View {
        GlassCard {
            VStack(spacing: 6) {
                Text("\(taps)")
                    .font(.system(size: 76, weight: .thin, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, Brand.teal],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .contentTransition(.numericText())
                    .scaleEffect(pulse ? 1.04 : 1.0)
                    .animation(.spring(response: 0.28, dampingFraction: 0.6), value: pulse)

                Text(taps == 1 ? "tap received" : "taps received")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.62))

                Text(gesture)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var inputCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("KEYBOARD INPUT")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.5))

                TextField("Tap a field, then type", text: $typed)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.09))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    )

                Text(typed.isEmpty ? "Typed characters appear here" : typed)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(typed.isEmpty ? 0.35 : 0.8))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 5) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, style: .time)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Text("Starly Industries · demo build \(version)")
                .font(.system(size: 10))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.32))
        }
    }

    // MARK: - Behaviour

    private func register() {
        taps += 1
        gesture = "tap received"
        pulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { pulse = false }
    }
}

private struct LivePill: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(red: 0.43, green: 0.91, blue: 0.78))
                .frame(width: 7, height: 7)
                .shadow(color: Brand.teal.opacity(0.8), radius: 4)
            Text("LIVE")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.10)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
}
