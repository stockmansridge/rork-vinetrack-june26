import UIKit

/// Native dismissal accessory. Existing custom field-navigation controls stay above Done.
final class KeyboardAccessoryView: UIView {
    let toolbar: UIToolbar
    let preservedAccessory: UIView?
    let dismissButton = UIButton(type: .system)

    init(preserving accessory: UIView?, dismiss: @escaping @MainActor () -> Void) {
        preservedAccessory = accessory
        toolbar = UIToolbar()
        let existingHeight = accessory.map { max($0.bounds.height, $0.intrinsicContentSize.height, 0) } ?? 0
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: existingHeight + 44))
        autoresizingMask = [.flexibleWidth]
        if let accessory {
            accessory.frame = CGRect(x: 0, y: 0, width: bounds.width, height: existingHeight)
            accessory.autoresizingMask = [.flexibleWidth]
            addSubview(accessory)
        }
        toolbar.frame = CGRect(x: 0, y: existingHeight, width: bounds.width, height: 44)
        toolbar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        // A system Done item's iOS toolbar representation can lose its accessibility
        // identity when UIKit transfers input accessories. Own the actual control.
        let button = dismissButton
        button.setTitle(String(localized: "Done"), for: .normal)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.isAccessibilityElement = true
        button.accessibilityLabel = String(localized: "Done")
        button.accessibilityHint = String(localized: "Dismiss keyboard without submitting")
        button.accessibilityIdentifier = "keyboard.dismiss"
        button.addAction(UIAction { _ in dismiss() }, for: .touchUpInside)
        button.frame = CGRect(x: 0, y: 0, width: max(64, button.intrinsicContentSize.width + 24), height: 44)
        toolbar.items = []
        toolbar.isAccessibilityElement = false
        addSubview(toolbar)
        // Keep the button out of UIToolbar's transient item host/proxy hierarchy.
        button.frame.origin = CGPoint(x: bounds.width - button.bounds.width - 12, y: existingHeight)
        button.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        addSubview(button)
        isAccessibilityElement = false
        accessibilityElements = accessory.map { [$0, button] } ?? [button]
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: bounds.height) }
}
