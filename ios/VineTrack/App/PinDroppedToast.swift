import SwiftUI

struct PinDroppedToast: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            ZStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 26, height: 26)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
        )
        .padding(.horizontal, 16)
    }
}

struct PinDroppedToastModifier: ViewModifier {
    @Binding var info: PinDroppedToastInfo?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let info {
                    PinDroppedToast(title: info.title, subtitle: info.subtitle)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: info?.id)
            .onChange(of: info?.id) { _, newId in
                guard newId != nil else { return }
                Task {
                    try? await Task.sleep(for: .seconds(2.2))
                    await MainActor.run {
                        if info?.id == newId {
                            info = nil
                        }
                    }
                }
            }
    }
}

struct PinDroppedToastInfo: Equatable, Identifiable {
    let id: UUID = UUID()
    let title: String
    let subtitle: String
}

extension View {
    func pinDroppedToast(_ info: Binding<PinDroppedToastInfo?>) -> some View {
        modifier(PinDroppedToastModifier(info: info))
    }
}
