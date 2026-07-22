import SwiftUI

struct AutoPhotoConfirmSheet: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var remaining: Int = 3
    @State private var countdownTask: Task<Void, Never>?
    @State private var didRespond: Bool = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text("Add a photo?")
                    .font(.title2.weight(.bold))
                Text("Auto-skipping in \(remaining)s")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: remaining)
            }

            HStack(spacing: 12) {
                Button(role: .cancel) {
                    respond(confirm: false)
                } label: {
                    Text("Skip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    respond(confirm: true)
                } label: {
                    Label("Take Photo", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
        .onAppear { start() }
        .onDisappear {
            countdownTask?.cancel()
            countdownTask = nil
        }
    }

    private func respond(confirm: Bool) {
        guard !didRespond else { return }
        didRespond = true
        countdownTask?.cancel()
        countdownTask = nil
        if confirm { onConfirm() } else { onCancel() }
    }

    private func start() {
        countdownTask?.cancel()
        remaining = 3
        countdownTask = Task { @MainActor in
            for value in stride(from: 2, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining = value
            }
            if !didRespond {
                didRespond = true
                onCancel()
            }
        }
    }
}
