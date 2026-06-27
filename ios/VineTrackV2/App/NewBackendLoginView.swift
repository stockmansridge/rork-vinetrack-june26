import SwiftUI
import AuthenticationServices

struct NewBackendLoginView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BiometricAuthService.self) private var biometric

    private enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign In"
        case signUp = "Sign Up"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .signIn
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var showForgotPassword: Bool = false
    @State private var resetStep: ResetStep = .enterEmail
    @State private var resetEmail: String = ""
    @State private var resetPin: String = ""
    @State private var resetNewPassword: String = ""
    @State private var resetConfirmPassword: String = ""
    @State private var resetLocalError: String?
    @State private var currentNonce: String?

    private enum ResetStep {
        case enterEmail
        case enterCode
        case completed
    }

    var body: some View {
        ZStack {
            LoginVineyardBackground()

            GeometryReader { proxy in
                let isCompactHeight = proxy.size.height < 760

                VStack(spacing: isCompactHeight ? 8 : 12) {
                    header(isCompactHeight: isCompactHeight)
                    featureChips
                    modePicker
                    formCard(isCompactHeight: isCompactHeight)
                    actionButton
                    if showBiometricQuickButton {
                        biometricQuickButton
                    }
                    dividerWithOr
                    appleSignInButton
                    footerLinks
                    if let errorMessage = auth.errorMessage {
                        Text(errorMessage)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.red.opacity(0.82), in: .rect(cornerRadius: 14))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 18)
                .padding(.top, isCompactHeight ? 10 : 22)
                .padding(.bottom, isCompactHeight ? 10 : 18)
            }
        }
        .sheet(isPresented: $showForgotPassword) {
            forgotPasswordSheet
        }
    }

    private func header(isCompactHeight: Bool) -> some View {
        VStack(spacing: isCompactHeight ? 8 : 12) {
            Image("vinetrack_logo")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: isCompactHeight ? 82 : 102, height: isCompactHeight ? 82 : 102)
                .clipShape(.rect(cornerRadius: isCompactHeight ? 22 : 26))
                .overlay(
                    RoundedRectangle(cornerRadius: isCompactHeight ? 22 : 26)
                        .stroke(.white.opacity(0.24), lineWidth: 1.2)
                )
                .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 8)

            VStack(spacing: isCompactHeight ? 4 : 6) {
                BrandWordmark(size: isCompactHeight ? 38 : 48)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .shadow(color: .black.opacity(0.28), radius: 2, x: 0, y: 2)

                Text("Built by viticulturists to manage\n vineyard work, row by row.")
                    .font(isCompactHeight ? .subheadline.weight(.medium) : .body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .multilineTextAlignment(.center)
                    .lineSpacing(isCompactHeight ? 2 : 3)
                    .shadow(color: .black.opacity(0.24), radius: 1, x: 0, y: 1)
            }
        }
    }

    private var featureChips: some View {
        HStack(spacing: 6) {
            LoginFeatureChip(title: "GPS Pins", systemImage: "mappin.circle.fill")
            LoginFeatureChip(title: "Row Tracking", systemImage: "line.3.horizontal.decrease")
            LoginFeatureChip(title: "Spray Records", systemImage: "leaf.fill")
        }
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { m in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        mode = m
                    }
                } label: {
                    Text(m.rawValue)
                        .font(.body.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .foregroundStyle(mode == m ? .white : Color(red: 0.02, green: 0.22, blue: 0.10))
                        .background(mode == m ? Color(red: 0.01, green: 0.30, blue: 0.13) : .clear, in: .rect(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(5)
        .background(.white.opacity(0.94), in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
    }

    private func formCard(isCompactHeight: Bool) -> some View {
        VStack(spacing: isCompactHeight ? 8 : 10) {
            if mode == .signUp {
                LoginField(
                    title: "Name",
                    text: $name,
                    icon: "person.fill",
                    contentType: .name,
                    keyboard: .default
                )
            }
            LoginField(
                title: "Email",
                text: $email,
                icon: "envelope.fill",
                contentType: .emailAddress,
                keyboard: .emailAddress,
                autocapitalize: false
            )
            LoginField(
                title: "Password",
                text: $password,
                icon: "lock.fill",
                contentType: mode == .signUp ? .newPassword : .password,
                keyboard: .default,
                autocapitalize: false,
                isSecure: true
            )
        }
        .padding(isCompactHeight ? 10 : 12)
        .background(.white.opacity(0.96), in: .rect(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.65), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 18, x: 0, y: 10)
    }

    private var showBiometricQuickButton: Bool {
        mode == .signIn
        && biometric.isEnabled
        && (biometric.deviceSupportsBiometrics || biometric.deviceSupportsAnyAuth)
    }

    private var biometricQuickButton: some View {
        Button {
            Task {
                let ok = await biometric.authenticate(reason: "Sign in to VineTrack")
                if ok {
                    // If a Supabase session is already persisted we are
                    // effectively signed in — flag unlocked so the root
                    // view advances. Otherwise the user still needs to
                    // type their password (we never store it).
                    biometric.markUnlocked()
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: biometric.iconSystemName)
                    .font(.title3.weight(.semibold))
                Text("Sign in with \(biometric.displayName)")
                    .font(.headline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(.white.opacity(0.16), in: .rect(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.32), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with \(biometric.displayName)")
    }

    private var actionButton: some View {
        Button {
            guard !auth.isLoading, canSubmit else { return }
            Task {
                switch mode {
                case .signIn:
                    await auth.signIn(email: email, password: password)
                case .signUp:
                    await auth.signUp(name: name, email: email, password: password)
                }
            }
        } label: {
            Group {
                if auth.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(mode == .signIn ? "Sign In" : "Create Account")
                }
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color(uiColor: .systemBlue), in: .rect(cornerRadius: 15))
            .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }

    private var dividerWithOr: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(.white.opacity(0.42))
                .frame(height: 1)
            Text("or")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
            Rectangle()
                .fill(.white.opacity(0.42))
                .frame(height: 1)
        }
    }

    private var appleSignInButton: some View {
        SignInWithAppleButton(.signIn) { request in
            let nonce = AppleSignInHelper.randomNonce()
            currentNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleSignInHelper.sha256(nonce)
        } onCompletion: { result in
            handleAppleResult(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 48)
        .clipShape(.rect(cornerRadius: 15))
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
        .disabled(auth.isLoading)
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            let nsError = error as NSError
            if nsError.code == ASAuthorizationError.canceled.rawValue { return }
            Task { @MainActor in
                auth.errorMessage = error.localizedDescription
            }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                Task { @MainActor in
                    auth.errorMessage = "Apple did not return a valid identity token."
                }
                return
            }
            let fullName = credential.fullName.flatMap { components -> String? in
                let parts = [components.givenName, components.middleName, components.familyName]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            }
            let nonce = currentNonce
            Task {
                await auth.signInWithApple(idToken: idToken, nonce: nonce, fullName: fullName)
                currentNonce = nil
            }
        }
    }

    private var footerLinks: some View {
        VStack(spacing: 8) {
            if mode == .signIn {
                Button("Forgot password?") {
                    resetEmail = email
                    resetStep = .enterEmail
                    resetPin = ""
                    resetNewPassword = ""
                    resetConfirmPassword = ""
                    resetLocalError = nil
                    showForgotPassword = true
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(red: 0.94, green: 0.92, blue: 0.72))
            }
        }
    }

    private var forgotPasswordSheet: some View {
        NavigationStack {
            Form {
                switch resetStep {
                case .enterEmail:
                    enterEmailSection
                case .enterCode:
                    enterCodeSection
                case .completed:
                    completedSection
                }

                if let message = resetLocalError ?? auth.errorMessage, resetStep != .completed {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Reset Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(resetStep == .completed ? "Close" : "Cancel") {
                        closeForgotPasswordSheet()
                    }
                }
            }
            .interactiveDismissDisabled(resetStep == .enterCode)
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var enterEmailSection: some View {
        Section {
            TextField("Email", text: $resetEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Step 1 — Request Code")
        } footer: {
            Text("We'll email you a 6-digit code. No links — codes only.")
        }

        Section {
            Button {
                Task { await requestResetCode() }
            } label: {
                if auth.isLoading {
                    ProgressView()
                } else {
                    Text("Send Code")
                }
            }
            .disabled(auth.isLoading || resetEmail.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var enterCodeSection: some View {
        if let success = auth.passwordResetSuccessMessage {
            Section {
                Label(success, systemImage: "envelope.badge.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
            }
        }

        Section {
            HStack {
                Text("Email")
                Spacer()
                Text(resetEmail)
                    .foregroundStyle(.secondary)
            }
            TextField("6-digit code", text: $resetPin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
            SecureField("New password", text: $resetNewPassword)
                .textContentType(.newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Confirm new password", text: $resetConfirmPassword)
                .textContentType(.newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Step 2 — Enter Code & New Password")
        } footer: {
            Text("Code expires after a short time. Password must be at least 8 characters.")
        }

        Section {
            Button {
                Task { await submitPasswordReset() }
            } label: {
                if auth.isLoading {
                    ProgressView()
                } else {
                    Text("Update Password")
                }
            }
            .disabled(auth.isLoading || !canSubmitReset)

            Button("Resend Code") {
                Task { await requestResetCode() }
            }
            .disabled(auth.isLoading)

            Button("Use a different email") {
                resetStep = .enterEmail
                resetPin = ""
                resetNewPassword = ""
                resetConfirmPassword = ""
                resetLocalError = nil
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var completedSection: some View {
        Section {
            Label(
                auth.passwordResetSuccessMessage ?? "Password updated. You can now sign in.",
                systemImage: "checkmark.seal.fill"
            )
            .foregroundStyle(VineyardTheme.leafGreen)
        }
        Section {
            Button("Back to Sign In") {
                password = resetNewPassword
                email = resetEmail
                closeForgotPasswordSheet()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func requestResetCode() async {
        resetLocalError = nil
        let success = await auth.sendPasswordReset(email: resetEmail)
        if success {
            resetStep = .enterCode
        }
    }

    private var canSubmitReset: Bool {
        let pinOk = resetPin.trimmingCharacters(in: .whitespaces).count >= 4
        let pwOk = resetNewPassword.count >= 8 && resetNewPassword == resetConfirmPassword
        return pinOk && pwOk
    }

    private func submitPasswordReset() async {
        resetLocalError = nil
        let trimmedPin = resetPin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPin.count >= 4 else {
            resetLocalError = "Enter the code from your email."
            return
        }
        guard resetNewPassword.count >= 8 else {
            resetLocalError = "Password must be at least 8 characters."
            return
        }
        guard resetNewPassword == resetConfirmPassword else {
            resetLocalError = "Passwords do not match."
            return
        }
        let success = await auth.resetPasswordWithPin(
            email: resetEmail,
            pin: trimmedPin,
            newPassword: resetNewPassword
        )
        if success {
            resetStep = .completed
        }
    }

    private func closeForgotPasswordSheet() {
        showForgotPassword = false
        resetStep = .enterEmail
        resetPin = ""
        resetNewPassword = ""
        resetConfirmPassword = ""
        resetLocalError = nil
    }

    private var canSubmit: Bool {
        let hasEmail = !email.trimmingCharacters(in: .whitespaces).isEmpty
        let hasPassword = !password.isEmpty
        if mode == .signUp {
            return hasEmail && hasPassword && !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return hasEmail && hasPassword
    }
}

struct LoginVineyardBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.43, blue: 0.20),
                    Color(red: 0.02, green: 0.28, blue: 0.13),
                    Color(red: 0.01, green: 0.17, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.15), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 420
            )

            VineyardSweepShape()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.10), .white.opacity(0.02)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            VineyardRowsShape()
                .stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .blendMode(.screen)
        }
        .ignoresSafeArea()
    }
}

struct VineyardSweepShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -rect.width * 0.12, y: rect.height * 0.34))
        path.addCurve(
            to: CGPoint(x: rect.width * 1.18, y: rect.height * 0.06),
            control1: CGPoint(x: rect.width * 0.24, y: rect.height * 0.20),
            control2: CGPoint(x: rect.width * 0.66, y: rect.height * 0.36)
        )
        path.addLine(to: CGPoint(x: rect.width * 1.18, y: rect.height * 0.16))
        path.addCurve(
            to: CGPoint(x: -rect.width * 0.12, y: rect.height * 0.48),
            control1: CGPoint(x: rect.width * 0.70, y: rect.height * 0.45),
            control2: CGPoint(x: rect.width * 0.23, y: rect.height * 0.28)
        )
        path.closeSubpath()
        return path
    }
}

struct VineyardRowsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<10 {
            let startY = rect.height * (0.37 + CGFloat(index) * 0.047)
            let endY = rect.height * (0.23 + CGFloat(index) * 0.020)
            path.move(to: CGPoint(x: rect.width * 0.45, y: startY))
            path.addQuadCurve(
                to: CGPoint(x: rect.width * 1.10, y: endY),
                control: CGPoint(x: rect.width * (0.65 + CGFloat(index) * 0.018), y: rect.height * 0.31)
            )
        }
        for index in 0..<6 {
            let y = rect.height * (0.26 + CGFloat(index) * 0.055)
            path.move(to: CGPoint(x: -rect.width * 0.08, y: y))
            path.addQuadCurve(
                to: CGPoint(x: rect.width * 0.72, y: rect.height * (0.20 + CGFloat(index) * 0.018)),
                control: CGPoint(x: rect.width * 0.24, y: y - rect.height * 0.08)
            )
        }
        return path
    }
}

private struct LoginFeatureChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(.white.opacity(0.10), in: .capsule)
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            )
    }
}

private struct LoginField: View {
    let title: String
    @Binding var text: String
    let icon: String
    let contentType: UITextContentType
    let keyboard: UIKeyboardType
    var autocapitalize: Bool = true
    var isSecure: Bool = false

    @State private var isRevealed: Bool = false
    @FocusState private var isFocused: Bool

    private var fieldPrompt: Text {
        Text(title)
            .foregroundStyle(Color(red: 0.30, green: 0.36, blue: 0.32))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(red: 0.02, green: 0.32, blue: 0.14))
                .frame(width: 32, height: 32)
                .background(Color(red: 0.93, green: 0.97, blue: 0.91), in: .rect(cornerRadius: 10))

            Group {
                if isSecure && !isRevealed {
                    SecureField(title, text: $text, prompt: fieldPrompt)
                        .focused($isFocused)
                } else {
                    TextField(title, text: $text, prompt: fieldPrompt)
                        .focused($isFocused)
                }
            }
            .font(.body)
            .foregroundStyle(Color(red: 0.02, green: 0.20, blue: 0.10))
            .tint(Color(red: 0.02, green: 0.32, blue: 0.14))
            .textContentType(contentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocapitalize ? .sentences : .never)
            .autocorrectionDisabled(!autocapitalize)

            if isSecure {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.02, green: 0.32, blue: 0.14).opacity(0.72))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(.white, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator).opacity(0.32), lineWidth: 1)
        )
    }
}
