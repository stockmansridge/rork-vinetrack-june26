import SwiftUI

struct ResetPasswordView: View {
    @Environment(NewBackendAuthService.self) private var auth

    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var showPassword: Bool = false
    @State private var localError: String?
    @State private var didSucceed: Bool = false

    var body: some View {
        ZStack {
            VineyardTheme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    header
                    if didSucceed {
                        successCard
                    } else {
                        formCard
                        actionButton
                        cancelButton
                    }
                    if let message = displayedError {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding()
                .padding(.top, 24)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(VineyardTheme.leafGreen.gradient)
                    .frame(width: 80, height: 80)
                Image(systemName: "lock.rotation")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Reset Password")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(VineyardTheme.olive)
            Text(auth.userEmail.map { "Choose a new password for \($0)." } ?? "Choose a new password.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var formCard: some View {
        VStack(spacing: 12) {
            passwordField(title: "New password", text: $newPassword)
            passwordField(title: "Confirm password", text: $confirmPassword)
            Toggle("Show password", isOn: $showPassword)
                .font(.footnote)
                .tint(VineyardTheme.leafGreen)
                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
            VStack(alignment: .leading, spacing: 4) {
                Text("Password must be at least 8 characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(VineyardTheme.cardBorder, lineWidth: 0.5)
        )
    }

    private func passwordField(title: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(VineyardTheme.olive)
                .frame(width: 20)
            Group {
                if showPassword {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
            }
            .textContentType(.newPassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color(.systemBackground), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(VineyardTheme.stone.opacity(0.4), lineWidth: 1)
        )
    }

    private var actionButton: some View {
        Button {
            Task { await submit() }
        } label: {
            if auth.isLoading {
                ProgressView().tint(.white)
            } else {
                Text("Update Password")
            }
        }
        .buttonStyle(.vineyardPrimary)
        .disabled(auth.isLoading || !canSubmit)
    }

    private var cancelButton: some View {
        Button("Cancel") {
            Task { await auth.cancelPasswordRecovery() }
        }
        .font(.footnote)
        .foregroundStyle(VineyardTheme.olive)
    }

    private var successCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(VineyardTheme.leafGreen)
            Text("Password updated")
                .font(.title3.weight(.semibold))
            Text("You can now sign in with your new password.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await auth.signOut() }
            } label: {
                Text("Back to Sign In")
            }
            .buttonStyle(.vineyardPrimary)
            .padding(.top, 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(VineyardTheme.cardBorder, lineWidth: 0.5)
        )
    }

    private var canSubmit: Bool {
        newPassword.count >= 8 && newPassword == confirmPassword
    }

    private var displayedError: String? {
        if let localError { return localError }
        return auth.errorMessage
    }

    private func submit() async {
        localError = nil
        guard newPassword.count >= 8 else {
            localError = "Password must be at least 8 characters."
            return
        }
        guard newPassword == confirmPassword else {
            localError = "Passwords do not match."
            return
        }
        let success = await auth.updatePassword(newPassword: newPassword)
        if success {
            didSucceed = true
        }
    }
}
