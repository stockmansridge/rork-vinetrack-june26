import UIKit

/// Observes only the app's own scene window. No swizzling, field delegates, Return handlers or data bindings.
final class KeyboardSceneCoordinator: NSObject, UIGestureRecognizerDelegate {
    private weak var window: UIWindow?
    private weak var activeInput: UIView?
    private var keyboardFrame: CGRect = .null
    private var isKeyboardReceding: Bool = false
    private var scrollStates: [ScrollState] = []
    private let backgroundTap = UITapGestureRecognizer()

    private struct ScrollState {
        weak var scrollView: UIScrollView?
        let dismissMode: UIScrollView.KeyboardDismissMode
        var addedBottom: CGFloat = 0
    }

    func attach(to window: UIWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        backgroundTap.addTarget(self, action: #selector(backgroundTapped))
        backgroundTap.cancelsTouchesInView = false
        backgroundTap.delaysTouchesBegan = false
        backgroundTap.delaysTouchesEnded = false
        backgroundTap.delegate = self
        window.addGestureRecognizer(backgroundTap)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(editingBegan), name: UITextField.textDidBeginEditingNotification, object: nil)
        center.addObserver(self, selector: #selector(editingBegan), name: UITextView.textDidBeginEditingNotification, object: nil)
        center.addObserver(self, selector: #selector(editingEnded), name: UITextField.textDidEndEditingNotification, object: nil)
        center.addObserver(self, selector: #selector(editingEnded), name: UITextView.textDidEndEditingNotification, object: nil)
        center.addObserver(self, selector: #selector(textChanged), name: UITextView.textDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardDidHideNotification, object: nil)
        if let responder = firstInput(in: window) { activate(responder) }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        window?.removeGestureRecognizer(backgroundTap)
        backgroundTap.removeTarget(self, action: #selector(backgroundTapped))
        restoreScrollViews()
        activeInput = nil
        keyboardFrame = .null
        window = nil
    }

    /// Resigns the actual active native control; does not call submit, validation or persistence.
    func dismissKeyboard() {
        guard let input = activeInput, input.window === window, input.isFirstResponder else { return }
        input.resignFirstResponder()
    }

    @objc private func editingBegan(_ notification: Notification) {
        guard let input = notification.object as? UIView, input.window === window else { return }
        activate(input)
    }

    func activate(_ input: UIView) {
        guard input.window === window, input is UITextField || input is UITextView else { return }
        restoreScrollViews()
        activeInput = input
        isKeyboardReceding = false
        installAccessory(on: input)
        // Only the focused input's containing scroll views are touched; maps and tracing surfaces are not.
        var ancestor: UIView? = input
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                scrollStates.append(ScrollState(scrollView: scrollView, dismissMode: scrollView.keyboardDismissMode))
                scrollView.keyboardDismissMode = .interactiveWithAccessory
            }
            ancestor = view.superview
        }
        scheduleVisibilityUpdate()
    }

    private func installAccessory(on input: UIView) {
        let existing: UIView?
        if let field = input as? UITextField { existing = field.inputAccessoryView }
        else if let editor = input as? UITextView { existing = editor.inputAccessoryView }
        else { return }
        guard !(existing is KeyboardAccessoryView) else { return }
        let accessory = KeyboardAccessoryView(preserving: existing) { [weak self, weak input] in
            guard let self, self.activeInput === input else { return }
            self.dismissKeyboard()
        }
        if let field = input as? UITextField { field.inputAccessoryView = accessory }
        else if let editor = input as? UITextView { editor.inputAccessoryView = accessory }
        if input.isFirstResponder { input.reloadInputViews() }
    }

    @objc private func editingEnded(_ notification: Notification) {
        guard let input = notification.object as? UIView, input === activeInput else { return }
        restoreScrollViews()
        activeInput = nil
    }

    @objc private func textChanged(_ notification: Notification) {
        guard let input = notification.object as? UIView, input === activeInput else { return }
        scheduleVisibilityUpdate()
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let window, activeInput?.window === window,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let nextFrame = window.convert(frame, from: window.screen.coordinateSpace)
        isKeyboardReceding = Self.isReceding(previous: keyboardFrame, next: nextFrame,
            bounds: window.bounds, wasReceding: isKeyboardReceding)
        keyboardFrame = nextFrame
        // Interactive dismissal sends a shrinking frame on each drag update.
        // Never scroll the form back towards its responder while UIKit is dismissing.
        guard !isKeyboardReceding else { return }
        scheduleVisibilityUpdate()
    }

    static func isReceding(previous: CGRect, next: CGRect, bounds: CGRect, wasReceding: Bool) -> Bool {
        let oldOverlap = bounds.intersection(previous)
        let oldHeight = oldOverlap.isNull ? 0 : oldOverlap.height
        let newOverlap = bounds.intersection(next)
        return newOverlap.isNull || newOverlap.height < oldHeight
            || (wasReceding && newOverlap.height == oldHeight)
    }

    @objc private func keyboardHidden(_ notification: Notification) {
        keyboardFrame = .null
        isKeyboardReceding = false
        removeAddedInsets()
    }

    private func scheduleVisibilityUpdate() {
        // SwiftUI first gets a layout pass to apply its native keyboard safe area (no double keyboard padding).
        DispatchQueue.main.async { [weak self] in self?.revealActiveInput() }
    }

    func revealActiveInput() {
        guard let window, let input = activeInput, input.window === window, input.isFirstResponder,
              !isKeyboardReceding, !keyboardFrame.isNull, keyboardFrame.intersects(window.bounds),
              !scrollStates.contains(where: { $0.scrollView?.isTracking == true || $0.scrollView?.isDragging == true || $0.scrollView?.isDecelerating == true })
        else { return }
        window.layoutIfNeeded()
        for index in scrollStates.indices.reversed() {
            guard let scrollView = scrollStates[index].scrollView, scrollView !== input else { continue }
            scrollView.keyboardDismissMode = .interactiveWithAccessory
            let frame = scrollView.convert(scrollView.bounds, to: window)
            let overlap = frame.intersection(keyboardFrame)
            // Do not inset the whole screen for a floating/split keyboard.
            let bottomOverlap = !overlap.isNull && keyboardFrame.maxY >= frame.maxY - 1 ? overlap.height : 0
            let state = scrollStates[index]
            let baseBottom = scrollView.adjustedContentInset.bottom - state.addedBottom
            let added = max(0, bottomOverlap - baseBottom)
            if abs(added - state.addedBottom) > 0.5 {
                scrollView.contentInset.bottom += added - state.addedBottom
                scrollView.verticalScrollIndicatorInsets.bottom += added - state.addedBottom
                scrollStates[index].addedBottom = added
            }
            let target: CGRect
            if let editor = input as? UITextView, let range = editor.selectedTextRange {
                target = editor.convert(editor.caretRect(for: range.end), to: scrollView)
            } else {
                target = input.convert(input.bounds, to: scrollView)
            }
            let padded = target.inset(by: UIEdgeInsets(top: -36, left: 0, bottom: -16, right: 0))
            scrollView.scrollRectToVisible(padded, animated: false)
        }
        if let editor = input as? UITextView { editor.scrollRangeToVisible(editor.selectedRange) }
    }

    private func removeAddedInsets() {
        for index in scrollStates.indices {
            let state = scrollStates[index]
            if let scrollView = state.scrollView, state.addedBottom > 0 {
                scrollView.contentInset.bottom -= state.addedBottom
                scrollView.verticalScrollIndicatorInsets.bottom -= state.addedBottom
            }
            scrollStates[index].addedBottom = 0
        }
    }

    private func restoreScrollViews() {
        removeAddedInsets()
        for state in scrollStates {
            if state.scrollView?.keyboardDismissMode == .interactiveWithAccessory {
                state.scrollView?.keyboardDismissMode = state.dismissMode
            }
        }
        scrollStates.removeAll()
    }

    @objc private func backgroundTapped() {
        guard backgroundTap.state == .ended else { return }
        dismissKeyboard()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window, activeInput?.isFirstResponder == true, let hit = touch.view else { return false }
        return KeyboardInteractionPolicy.permitsBackgroundDismissal(hitView: hit, in: window,
            screenPoint: window.convert(touch.location(in: window), to: window.screen.coordinateSpace))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    private func firstInput(in view: UIView) -> UIView? {
        if view.isFirstResponder, view is UITextField || view is UITextView { return view }
        for child in view.subviews {
            if let input = firstInput(in: child) { return input }
        }
        return nil
    }
}
