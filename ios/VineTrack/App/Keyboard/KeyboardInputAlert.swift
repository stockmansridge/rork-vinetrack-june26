import SwiftUI
import UIKit

/// Editable prompts use an app-owned native dialog: SwiftUI's system alert makes
/// the keyboard accessory unreliable in its modal accessibility hierarchy.
struct KeyboardInputAlert: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var draft: String
    let title: String
    let message: String?
    let placeholder: String
    var identifier: String = ""
    var keyboardType: UIKeyboardType = .default
    var capitalization: UITextAutocapitalizationType = .sentences
    var confirmTitle: String = "Save"
    var confirmStyle: UIAlertAction.Style = .default
    var canConfirm: (String) -> Bool = { _ in true }
    var onConfirm: () -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> Presenter {
        let presenter = Presenter()
        presenter.onAppear = { [weak coordinator = context.coordinator, weak presenter] in
            if let presenter { coordinator?.update(in: presenter) }
        }
        return presenter
    }
    func updateUIViewController(_ presenter: Presenter, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(in: presenter)
    }
    final class Presenter: UIViewController {
        var onAppear: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); onAppear?() }
    }
    final class Coordinator: NSObject {
        var parent: KeyboardInputAlert
        private weak var prompt: KeyboardInputPromptController?
        init(parent: KeyboardInputAlert) { self.parent = parent }
        func update(in presenter: Presenter) {
            guard presenter.viewIfLoaded?.window != nil else { return }
            if !parent.isPresented {
                prompt?.dismiss(animated: true)
                prompt = nil
                return
            }
            if let prompt {
                prompt.confirmButton.isEnabled = parent.canConfirm(parent.draft)
                if prompt.field.text != parent.draft { prompt.field.text = parent.draft }
                return
            }
            guard presenter.presentedViewController == nil else { return }
            let dialog = KeyboardInputPromptController()
            dialog.loadViewIfNeeded()
            dialog.heading.text = parent.title
            dialog.message.text = parent.message
            dialog.message.isHidden = parent.message == nil
            dialog.field.placeholder = parent.placeholder
            dialog.field.text = parent.draft
            dialog.field.accessibilityIdentifier = parent.identifier
            dialog.field.keyboardType = parent.keyboardType
            dialog.field.autocapitalizationType = parent.capitalization
            dialog.confirmButton.setTitle(parent.confirmTitle, for: .normal)
            dialog.confirmButton.isEnabled = parent.canConfirm(parent.draft)
            if parent.confirmStyle == .destructive { dialog.confirmButton.tintColor = .systemRed }
            dialog.field.addTarget(self, action: #selector(changed), for: .editingChanged)
            dialog.onConfirm = { [weak self] in
                guard let self else { return }
                self.parent.onConfirm()
                self.parent.isPresented = false
                self.prompt = nil
            }
            dialog.onCancel = { [weak self] in
                guard let self else { return }
                self.parent.onCancel()
                self.parent.isPresented = false
                self.prompt = nil
            }
            prompt = dialog
            presenter.present(dialog, animated: true)
        }
        @objc private func changed(_ field: UITextField) {
            parent.draft = field.text ?? ""
            prompt?.confirmButton.isEnabled = parent.canConfirm(parent.draft)
        }
    }
}

/// Done is part of the dialog, not an alert action or transient keyboard window.
final class KeyboardInputPromptController: UIViewController {
    let heading = UILabel()
    let message = UILabel()
    let field = UITextField()
    let doneButton = UIButton(type: .system)
    let confirmButton = UIButton(type: .system)
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        view.accessibilityViewIsModal = true
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        card.accessibilityIdentifier = "keyboard.inputPrompt"
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.accessibilityTraits = .header
        message.font = .preferredFont(forTextStyle: .subheadline)
        for label in [heading, message] { label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true }
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        doneButton.setTitle("Done", for: .normal)
        doneButton.isAccessibilityElement = true
        doneButton.accessibilityLabel = "Done"
        doneButton.accessibilityIdentifier = "keyboard.dismiss"
        doneButton.accessibilityHint = "Dismiss keyboard without submitting"
        doneButton.addAction(UIAction { [weak self] _ in self?.field.resignFirstResponder() }, for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel?(); self?.dismiss(animated: true) }, for: .touchUpInside)
        confirmButton.addAction(UIAction { [weak self] _ in self?.onConfirm?(); self?.dismiss(animated: true) }, for: .touchUpInside)
        // Vertical actions reflow at large text sizes and remain distinct from Done.
        let stack = UIStackView(arrangedSubviews: [heading, message, field, doneButton, confirmButton, cancel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        card.addSubview(scroll)
        scroll.addSubview(stack)
        for button in [doneButton, confirmButton, cancel] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let center = card.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        center.priority = .defaultLow
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            card.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32).withPriority(.defaultHigh),
            card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            card.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -12), center,
            card.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 40).withPriority(.defaultLow),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: heading)
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ value: UILayoutPriority) -> NSLayoutConstraint { priority = value; return self }
}

extension View {
    /// Preserves the editable prompt's business actions; Done only resigns its input.
    func keyboardInputAlert(_ title: String, isPresented: Binding<Bool>, draft: Binding<String>,
                            placeholder: String, message: String? = nil, identifier: String = "",
                            keyboardType: UIKeyboardType = .default,
                            capitalization: UITextAutocapitalizationType = .sentences,
                            confirmTitle: String = "Save", confirmStyle: UIAlertAction.Style = .default,
                            canConfirm: @escaping (String) -> Bool = { _ in true },
                            onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void = {}) -> some View {
        background(KeyboardInputAlert(isPresented: isPresented, draft: draft, title: title, message: message,
            placeholder: placeholder, identifier: identifier, keyboardType: keyboardType,
            capitalization: capitalization, confirmTitle: confirmTitle, confirmStyle: confirmStyle,
            canConfirm: canConfirm, onConfirm: onConfirm, onCancel: onCancel))
    }
}
