import Foundation
import Supabase

final class SupabaseAuthRepository: AuthRepository {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    var currentUserId: UUID? {
        provider.client.auth.currentUser?.id
    }

    func restoreSession() async throws -> AppUser? {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        // No stored session at all → genuinely unauthenticated. Route to login.
        guard let cached = provider.client.auth.currentSession else { return nil }
        do {
            // `currentSession` may be expired. `auth.session` validates and
            // refreshes the token, guaranteeing a non-expired session or
            // throwing. This is what distinguishes a live session from a stale
            // one that the SDK cached on launch.
            let session = try await provider.client.auth.session
            return appUser(from: session.user)
        } catch {
            if Self.isLikelyNetworkError(error) {
                // Offline: we cannot reach the auth server to refresh. Keep the
                // user signed in using the cached session so offline field work
                // continues. The token will be revalidated once back online.
                return appUser(from: cached.user)
            }
            // Genuine auth rejection (expired/invalid refresh token, deleted or
            // disabled user). Clear the stale session so the app routes to the
            // login screen rather than a stale "authenticated" state.
            try? await provider.client.auth.signOut()
            return nil
        }
    }

    /// True when an error looks like a transport/connectivity failure rather
    /// than a credential rejection. Used to keep offline users signed in.
    nonisolated static func isLikelyNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return true }
        // Some SDK errors wrap the URLError as an underlying error.
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return true
        }
        return false
    }

    /// True when the server actively rejected the session/credentials (expired
    /// refresh token, missing session, 401/403). Network failures return false
    /// so we don't sign out an offline user. Used by startup routing to decide
    /// between the login screen and a retryable offline state.
    nonisolated static func isAuthRejection(_ error: Error) -> Bool {
        if isLikelyNetworkError(error) { return false }
        if error is AuthError { return true }
        let nsError = error as NSError
        if nsError.code == 401 || nsError.code == 403 { return true }
        return false
    }

    func signInWithEmail(email: String, password: String) async throws -> AppUser {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.auth.signIn(email: email, password: password)
        let session = try await provider.client.auth.session
        return appUser(from: session.user)
    }

    func signUpWithEmail(name: String, email: String, password: String) async throws -> AppUser? {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let response = try await provider.client.auth.signUp(email: email, password: password)
        return appUser(from: response.user, fallbackEmail: email, fallbackDisplayName: name)
    }

    func signOut() async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.auth.signOut()
    }

    func sendPasswordReset(email: String, redirectTo: URL?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.auth.resetPasswordForEmail(email, redirectTo: redirectTo)
    }

    func handlePasswordRecoveryURL(_ url: URL) async throws -> AppUser {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let session = try await provider.client.auth.session(from: url)
        return appUser(from: session.user)
    }

    func verifyPasswordResetPin(email: String, pin: String) async throws -> AppUser {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.auth.verifyOTP(email: email, token: pin, type: .recovery)
        let session = try await provider.client.auth.session
        return appUser(from: session.user, fallbackEmail: email)
    }

    func updatePassword(_ newPassword: String) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.auth.update(user: UserAttributes(password: newPassword))
    }

    func resetPasswordWithPin(email: String, pin: String, newPassword: String) async throws -> AppUser {
        let user = try await verifyPasswordResetPin(email: email, pin: pin)
        try await updatePassword(newPassword)
        return user
    }

    func signInWithApple(idToken: String, nonce: String?) async throws -> AppUser {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let credentials = OpenIDConnectCredentials(
            provider: .apple,
            idToken: idToken,
            nonce: nonce
        )
        try await provider.client.auth.signInWithIdToken(credentials: credentials)
        let session = try await provider.client.auth.session
        return appUser(from: session.user)
    }

    private func appUser(from user: User, fallbackEmail: String? = nil, fallbackDisplayName: String? = nil) -> AppUser {
        let email = user.email ?? fallbackEmail ?? ""
        return AppUser(
            id: user.id,
            email: email,
            displayName: fallbackDisplayName ?? email,
            avatarURL: nil,
            createdAt: user.createdAt
        )
    }
}
