import SwiftUI

struct BiometricLockView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BiometricAuthService.self) private var biometric

    @State private var isWorking: Bool = false
    @State private var didAutoTrigger: Bool = false

    var body: some View {
        ZStack {
            LoginVineyardBackground()

            VStack(spacing: 28) {
                Spacer()

                Image("vinetrack_logo")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 96)
                    .clipShape(.rect(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(.white.opacity(0.24), lineWidth: 1.2)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 8)

                VStack(spacing: 8) {
                    Text("Welcome back")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    if let email = biometric.savedEmail ?? auth.userEmail, !email.isEmpty {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    Text("Use \(biometric.displayName) to continue.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                Button {
                    Task { await unlock() }
                } label: {
                    HStack(spacing: 10) {
                        if isWorking {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: biometric.iconSystemName)
                                .font(.title3.weight(.semibold))
                        }
                        Text("Sign in with \(biometric.displayName)")
                            .font(.headline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(uiColor: .systemBlue), in: .rect(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityLabel("Sign in with \(biometric.displayName)")
                .padding(.horizontal, 24)

                if let error = biometric.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.82), in: .rect(cornerRadius: 12))
                        .padding(.horizontal, 24)
                }

                Spacer()

                Button {
                    Task {
                        biometric.markUnlocked()
                        biometric.disable() // user wants out of biometric flow on this device
                        await auth.signOut()
                    }
                } label: {
                    Text("Use a different account")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .underline()
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            guard !didAutoTrigger else { return }
            didAutoTrigger = true
            await unlock()
        }
    }

    private func unlock() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let ok = await biometric.authenticate(reason: "Sign in to VineTrack")
        if ok {
            biometric.markUnlocked()
        }
    }
}
