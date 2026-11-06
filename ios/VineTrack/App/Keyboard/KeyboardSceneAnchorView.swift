import UIKit

/// Non-interactive lifecycle anchor for the scene's native keyboard coordinator.
final class KeyboardSceneAnchorView: UIView {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}
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
