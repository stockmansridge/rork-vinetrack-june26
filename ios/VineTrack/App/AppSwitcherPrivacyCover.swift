import SwiftUI
import UIKit

/// A separate non-key window sits above sheets and navigation during OS snapshots.
@MainActor
final class AppSwitcherPrivacyCover {
    private var window: UIWindow?

    func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 2
        cover.backgroundColor = .black
        cover.rootViewController = UIHostingController(rootView: ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image("vinetrack_logo")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(.rect(cornerRadius: 18))
                Text("VineTrack")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
        })
        cover.isHidden = false
        window = cover
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}
