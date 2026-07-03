import Foundation
import Observation

@Observable
@MainActor
final class NewBackendAuthService {
    var isLoading: Bool = false
    var isSignedIn: Bool = false
    var userId: UUID?
    var userEmail: String?
    var userName: String?
    var userCreatedAt: Date?
    var errorMessage: String?
    var pendingInvitations: [BackendInvitation] = []
    var isInPasswordRecovery: Bool = false
    var passwordResetSuccessMessage: String?
    var defaultVineyardId: UUID?

    private let authRepository: any AuthRepository
    private let profileRepository: any ProfileRepositoryProtocol
    private let teamRepository: any TeamRepositoryProtocol

    init(
        authRepository: any AuthRepository = SupabaseAuthRepository(),
        profileRepository: any ProfileRepositoryProtocol = SupabaseProfileRepository(),
        teamRepository: any TeamRepositoryProtocol = SupabaseTeamRepository()
    ) {
        self.authRepository = authRepository
        self.profileRepository = profileRepository
        self.teamRepository = teamRepository
    }

    func restoreSession() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let user = try await authRepository.restoreSession()
            applyUser(user)
            if isSignedIn {
                await refreshProfile()
            }
        } catch {
            errorMessage = error.localizedDescription
            applyUser(nil)
        }
    }

    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let user = try await authRepository.signInWithEmail(email: trimmedEmail, password: password)
            applyUser(user)
            await refreshProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signUp(name: String, email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let user = try await authRepository.signUpWithEmail(name: trimmedName, email: trimmedEmail, password: password)
            applyUser(user)
            if isSignedIn {
                try? await profileRepository.upsertMyProfile(
                    fullName: trimmedName.isEmpty ? nil : trimmedName,
                    email: trimmedEmail.isEmpty ? nil : trimmedEmail
                )
                if !trimmedName.isEmpty {
                    userName = trimmedName
                    cacheDisplayName(trimmedName, for: userId)
                }
            } else {
                errorMessage = "Check your email to confirm your account, then sign in."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signInWithApple(idToken: String, nonce: String?, fullName: String?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let user = try await authRepository.signInWithApple(idToken: idToken, nonce: nonce)
            applyUser(user)
            if isSignedIn {
                let trimmedName = fullName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let nameToSave = (trimmedName?.isEmpty == false) ? trimmedName : nil
                if nameToSave != nil {
                    try? await profileRepository.upsertMyProfile(
                        fullName: nameToSave,
                        email: user.email.isEmpty ? nil : user.email
                    )
                    if let nameToSave {
                        userName = nameToSave
                        cacheDisplayName(nameToSave, for: userId)
                    }
                }
                await refreshProfile()
            }
        } catch {
            errorMessage = friendlyAppleError(error)
        }
    }

    private func friendlyAppleError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("cancel") {
            return "Sign in with Apple was cancelled."
        }
        if lower.contains("nonce") {
            return "Apple sign-in failed (nonce mismatch). Please try again."
        }
        if lower.contains("identity token") || lower.contains("id token") {
            return "Apple did not return a valid identity token. Please try again."
        }
        return raw
    }

    func signOut() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await authRepository.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
        applyUser(nil)
        pendingInvitations = []
        defaultVineyardId = nil
    }

    @discardableResult
    func sendPasswordReset(email: String) async -> Bool {
        isLoading = true
        errorMessage = nil
        passwordResetSuccessMessage = nil
        defer { isLoading = false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            errorMessage = "Please enter your email address."
            return false
        }
        do {
            try await authRepository.sendPasswordReset(
                email: trimmedEmail,
                redirectTo: nil
            )
            #if DEBUG
            print("[Auth] Password reset code requested for \(trimmedEmail)")
            #endif
            passwordResetSuccessMessage = "If an account exists for \(trimmedEmail), we've sent a 6-digit code. Enter it below with your new password."
            return true
        } catch {
            #if DEBUG
            print("[Auth] sendPasswordReset failed: \(error)")
            #endif
            errorMessage = friendlyResetError(error)
            return false
        }
    }

    private func friendlyResetError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("rate") || lower.contains("too many") {
            return "Too many requests. Wait a minute and try again. (Supabase email rate limit)"
        }
        if lower.contains("smtp") {
            return "Email could not be sent. Check Supabase SMTP / email provider settings."
        }
        if lower.contains("invalid") && lower.contains("email") {
            return "That email address looks invalid."
        }
        return raw
    }

    func resetPasswordWithPin(email: String, pin: String, newPassword: String) async -> Bool {
        isLoading = true
        errorMessage = nil
        passwordResetSuccessMessage = nil
        defer { isLoading = false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await authRepository.resetPasswordWithPin(
                email: trimmedEmail,
                pin: trimmedPin,
                newPassword: newPassword
            )
            try? await authRepository.signOut()
            applyUser(nil)
            passwordResetSuccessMessage = "Password updated. You can now sign in with your new password."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updatePassword(newPassword: String) async -> Bool {
        isLoading = true
        errorMessage = nil
        passwordResetSuccessMessage = nil
        defer { isLoading = false }
        do {
            try await authRepository.updatePassword(newPassword)
            passwordResetSuccessMessage = "Password updated successfully."
            isInPasswordRecovery = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cancelPasswordRecovery() async {
        isInPasswordRecovery = false
        await signOut()
    }

    @discardableResult
    func updateDisplayName(_ newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter a name."
            return false
        }
        guard isSignedIn else { return false }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await profileRepository.upsertMyProfile(fullName: trimmed, email: userEmail)
            userName = trimmed
            cacheDisplayName(trimmed, for: userId)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadPendingInvitations() async {
        guard isSignedIn else { return }
        do {
            pendingInvitations = try await teamRepository.listPendingInvitations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func acceptInvitation(_ invitation: BackendInvitation) async {
        do {
            try await teamRepository.acceptInvitation(invitationId: invitation.id)
            pendingInvitations.removeAll { $0.id == invitation.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func declineInvitation(_ invitation: BackendInvitation) async {
        do {
            try await teamRepository.declineInvitation(invitationId: invitation.id)
            pendingInvitations.removeAll { $0.id == invitation.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyUser(_ user: AppUser?) {
        if let user {
            isSignedIn = true
            userId = user.id
            userEmail = user.email
            // Prefer the locally cached server profile name over the email
            // placeholder so an offline launch still shows the user's name.
            // The server profile (profiles.full_name) remains the source of
            // truth and overrides this in refreshProfile().
            let resolved = user.displayName.isEmpty ? user.email : user.displayName
            if resolved.isEmpty || resolved == user.email,
               let cached = cachedDisplayName(for: user.id), !cached.isEmpty {
                userName = cached
            } else {
                userName = resolved
            }
            userCreatedAt = user.createdAt
        } else {
            isSignedIn = false
            userId = nil
            userEmail = nil
            userName = nil
            userCreatedAt = nil
        }
    }

    private func refreshProfile() async {
        do {
            if let profile = try await profileRepository.getMyProfile() {
                userEmail = profile.email
                if let fullName = profile.fullName, !fullName.isEmpty {
                    userName = fullName
                    cacheDisplayName(fullName, for: userId)
                }
                defaultVineyardId = profile.defaultVineyardId
            }
        } catch {
            // Silent — profile fetch failure should not block sign-in flow.
        }
    }

    // MARK: - Offline display-name cache
    //
    // The server profile (public.profiles.full_name) is the cross-platform
    // source of truth for the display name. This cache exists purely so an
    // offline session restore can show the user's name instead of their
    // email; it is keyed by user id so it can never leak across accounts.

    private nonisolated static func displayNameCacheKey(for userId: UUID) -> String {
        "profile_display_name.\(userId.uuidString)"
    }

    private func cachedDisplayName(for userId: UUID) -> String? {
        UserDefaults.standard.string(forKey: Self.displayNameCacheKey(for: userId))
    }

    private func cacheDisplayName(_ name: String?, for userId: UUID?) {
        guard let userId else { return }
        let key = Self.displayNameCacheKey(for: userId)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Persist the per-user default vineyard via the `set_default_vineyard`
    /// RPC. This call is intentionally **best-effort** and silent on failure:
    ///   - it is always a follow-up to a primary action (sign-in, invitation
    ///     accept, settings tap),
    ///   - it must never surface a destructive-looking error banner if the
    ///     primary action succeeded,
    ///   - if the RPC is missing from the PostgREST schema cache or the
    ///     network fails, the user can still proceed using the locally
    ///     selected vineyard.
    /// The error is logged in DEBUG builds only.
    @discardableResult
    func setDefaultVineyard(_ vineyardId: UUID?) async -> Bool {
        guard isSignedIn else { return false }
        do {
            try await profileRepository.updateDefaultVineyard(vineyardId: vineyardId)
            defaultVineyardId = vineyardId
            return true
        } catch {
            #if DEBUG
            print("[Auth] setDefaultVineyard failed (non-blocking):", error.localizedDescription)
            #endif
            return false
        }
    }
}
