import Foundation

/// Decides whether a restored or freshly signed-in session may show the one-time offer.
nonisolated enum BiometricEnrollmentEligibility {
    static func shouldOffer(isInMainShell: Bool, supportsDeviceAuth: Bool, isEnabled: Bool, hasPrompted: Bool) -> Bool {
        isInMainShell && supportsDeviceAuth && !isEnabled && !hasPrompted
    }

    static func shouldLock(hasRestoredSession: Bool, isEnabled: Bool, supportsDeviceAuth: Bool) -> Bool {
        hasRestoredSession && isEnabled && supportsDeviceAuth
    }
}
