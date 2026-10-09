import UIKit

/// Non-interactive lifecycle anchor for the scene's native keyboard coordinator.
final class KeyboardSceneAnchorView: UIView {
    let keyboardCoordinator = KeyboardSceneCoordinator()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { keyboardCoordinator.attach(to: window) }
        else { keyboardCoordinator.detach() }
    }
}
