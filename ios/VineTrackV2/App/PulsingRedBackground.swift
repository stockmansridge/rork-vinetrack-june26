import SwiftUI

/// Repeating red pulse used to highlight UI that demands the operator's
/// immediate attention (e.g. row-side chips and the current-path banner
/// when the live detected path differs from the planned path during an
/// active trip). Uses a continuous opacity oscillation rather than a
/// scale change so it stays calm in the operator's peripheral vision.
struct PulsingRedBackground: View {
    var cornerRadius: CGFloat = 10

    @State private var pulse: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: pulse
                        ? [Color.red, Color.red.opacity(0.75)]
                        : [Color.red.opacity(0.85), Color.red.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(pulse ? 0.55 : 0.2), lineWidth: 1.2)
            )
            .shadow(color: Color.red.opacity(pulse ? 0.55 : 0.2), radius: pulse ? 8 : 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
