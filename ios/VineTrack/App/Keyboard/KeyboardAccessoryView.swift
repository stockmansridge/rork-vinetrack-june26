import UIKit

/// Native dismissal accessory. Existing custom field-navigation controls stay above Done.
final class KeyboardAccessoryView: UIView {
    let toolbar: UIToolbar
    let preservedAccessory: UIView?

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
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in dismiss() })
        done.accessibilityLabel = String(localized: "Done")
        done.accessibilityHint = String(localized: "Dismiss keyboard without submitting")
        done.accessibilityIdentifier = "keyboard.dismiss"
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: bounds.height) }
}
