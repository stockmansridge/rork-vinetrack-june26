import Foundation
import LocalAuthentication
import Observation

@Observable
@MainActor
final class BiometricAuthService {

    enum Biometry {
        case none
        case faceID
        case touchID
        case opticID
    }

    private(set) var biometry: Biometry = .none
    private(set) var deviceSupportsBiometrics: Bool = false
    private(set) var deviceSupportsAnyAuth: Bool = false

    /// True when the Supabase session has been restored but the user
    /// must satisfy a biometric prompt before we expose the app UI.
    var requiresUnlock: Bool = false

    var errorMessage: String?

    private static let promptShownKey = "biometric.enrollmentPromptShown"

    init() {
        refreshCapability()
    }

    // MARK: - Capability

    func refreshCapability() {
        let context = LAContext()
        var bioError: NSError?
        deviceSupportsBiometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &bioError)

        var anyError: NSError?
        deviceSupportsAnyAuth = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &anyError)

        switch context.biometryType {
        case .faceID: biometry = .faceID
        case .touchID: biometry = .touchID
        #if compiler(>=5.9)
        case .opticID: biometry = .opticID
        #endif
        default: biometry = .none
        }
    }

    var displayName: String {
        switch biometry {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "Biometrics"
        }
    }

    var iconSystemName: String {
        switch biometry {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "lock.shield.fill"
        }
    }

    // MARK: - Stored state

    var isEnabled: Bool { BiometricKeychain.isEnabled }
    var savedEmail: String? { BiometricKeychain.savedEmail }

    var hasShownEnrollmentPrompt: Bool {
        UserDefaults.standard.bool(forKey: Self.promptShownKey)
    }

    func markEnrollmentPromptShown() {
        UserDefaults.standard.set(true, forKey: Self.promptShownKey)
    }

    func resetEnrollmentPromptForTesting() {
        UserDefaults.standard.removeObject(forKey: Self.promptShownKey)
    }

    // MARK: - Authenticate

    @discardableResult
    func authenticate(reason: String? = nil) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var policyError: NSError?

        // Prefer biometrics, but allow device passcode as fallback so the
        // user is never locked out if a fingerprint or face fails.
        let policy: LAPolicy = deviceSupportsBiometrics
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            errorMessage = policyError?.localizedDescription ?? "Biometric authentication is unavailable."
            return false
        }

        let prompt = reason ?? "Sign in to VineTrack"
        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: prompt)
            if ok {
                errorMessage = nil
            }
            return ok
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                errorMessage = nil
            case .userFallback:
                // User tapped "Use Passcode" — try device passcode policy.
                return await authenticateWithPasscode(reason: prompt)
            default:
                errorMessage = error.localizedDescription
            }
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func authenticateWithPasscode(reason: String) async -> Bool {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            errorMessage = policyError?.localizedDescription ?? "Authentication unavailable."
            return false
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { errorMessage = nil }
            return ok
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Enable / disable

    @discardableResult
    func enable(email: String?) async -> Bool {
        guard deviceSupportsBiometrics || deviceSupportsAnyAuth else {
            errorMessage = "This device does not support biometric authentication."
            return false
        }
        let ok = await authenticate(reason: "Enable \(displayName) for faster sign-in")
        if ok {
            BiometricKeychain.setEnabled(true)
            BiometricKeychain.setSavedEmail(email)
            markEnrollmentPromptShown()
        }
        return ok
    }

    func disable() {
        BiometricKeychain.clearAll()
        requiresUnlock = false
        errorMessage = nil
    }

    // MARK: - Session gating

    /// After Supabase restores the session, lock the UI if the user has
    /// opted into biometric login on this device.
    func lockIfEnabled() {
        if isEnabled && (deviceSupportsBiometrics || deviceSupportsAnyAuth) {
            requiresUnlock = true
        } else {
            requiresUnlock = false
        }
    }

    func markUnlocked() {
        requiresUnlock = false
        errorMessage = nil
    }

    /// Update the saved email after a sign-in/sign-up so the unlock screen
    /// can show the right account.
    func updateSavedEmailIfEnabled(_ email: String?) {
        guard isEnabled else { return }
        BiometricKeychain.setSavedEmail(email)
    }
}
