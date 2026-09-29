import SwiftUI
import UIKit

/// Presents the unlock UI above sheets without removing the authenticated navigation tree.
@MainActor
final class AppBiometricLockCover {
    private var window: UIWindow?

    func show(auth: NewBackendAuthService, biometric: BiometricAuthService) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.backgroundColor = .black
        cover.rootViewController = UIHostingController(rootView: BiometricLockView()
            .environment(auth)
            .environment(biometric))
        cover.isHidden = false
        window = cover
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}
