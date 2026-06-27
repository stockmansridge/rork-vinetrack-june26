import SwiftUI

struct BiometricSettingsView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BiometricAuthService.self) private var biometric

    @State private var isWorking: Bool = false
    @State private var localError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: biometric.iconSystemName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use \(biometric.displayName) for login")
                            .font(.subheadline.weight(.semibold))
                        Text("Sign in faster without retyping your password.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: bindingForToggle)
                        .labelsHidden()
                        .disabled(!canEnable || isWorking)
                        .accessibilityLabel("Use \(biometric.displayName) for login")
                }
            } footer: {
                if !canEnable {
                    Text("Biometric login isn't available on this device. Enable Face ID, Touch ID, or a device passcode in iOS Settings.")
                } else if biometric.isEnabled, let email = biometric.savedEmail {
                    Text("\(biometric.displayName) sign-in enabled for \(email).")
                } else {
                    Text("Biometric login uses your device's secure authentication. Your password is never stored.")
                }
            }

            if let error = localError ?? biometric.errorMessage, !error.isEmpty {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Sign-in")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { biometric.refreshCapability() }
    }

    private var canEnable: Bool {
        biometric.deviceSupportsBiometrics || biometric.deviceSupportsAnyAuth
    }

    private var bindingForToggle: Binding<Bool> {
        Binding(
            get: { biometric.isEnabled },
            set: { newValue in
                Task { await setEnabled(newValue) }
            }
        )
    }

    private func setEnabled(_ enabled: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        localError = nil
        if enabled {
            let ok = await biometric.enable(email: auth.userEmail)
            if !ok && biometric.errorMessage == nil {
                localError = "Couldn't enable \(biometric.displayName)."
            }
        } else {
            biometric.disable()
        }
    }
}
