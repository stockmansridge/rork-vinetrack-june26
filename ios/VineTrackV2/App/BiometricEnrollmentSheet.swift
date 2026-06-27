import SwiftUI

struct BiometricEnrollmentSheet: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BiometricAuthService.self) private var biometric
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(VineyardTheme.leafGreen.gradient)
                        .frame(width: 96, height: 96)
                    Image(systemName: biometric.iconSystemName)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 8) {
                    Text("Use \(biometric.displayName) to sign in faster")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Biometric login uses your device's secure authentication. Your password is never stored.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await enable() }
                    } label: {
                        HStack {
                            if isWorking { ProgressView().tint(.white) }
                            Text("Enable \(biometric.displayName)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.vineyardPrimary)
                    .disabled(isWorking)

                    Button {
                        biometric.markEnrollmentPromptShown()
                        dismiss()
                    } label: {
                        Text("Not now")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(VineyardTheme.olive)
                    .disabled(isWorking)
                }

                if let error = biometric.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        biometric.markEnrollmentPromptShown()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func enable() async {
        isWorking = true
        defer { isWorking = false }
        let ok = await biometric.enable(email: auth.userEmail)
        if ok {
            dismiss()
        }
    }
}
