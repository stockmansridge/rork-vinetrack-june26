import Testing
import UIKit
import MapKit
@testable import VineTrack

@MainActor
@Suite(.serialized)
struct KeyboardSceneCoordinatorTests {
    @Test func allNativeKeyboardTypesAndSecureFieldsReceiveOneAccessoryWithoutChangingValues() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinator = KeyboardSceneCoordinator()
        coordinator.attach(to: window)
        defer { coordinator.detach() }
        for type in [UIKeyboardType.default, .numberPad, .decimalPad, .emailAddress, .URL, .phonePad, .webSearch, .numbersAndPunctuation] {
            let field = UITextField(frame: CGRect(x: 16, y: 100, width: 300, height: 44))
            field.keyboardType = type
            field.text = "Unsubmitted 12.50"
            field.returnKeyType = .next
            window.addSubview(field)
            coordinator.activate(field)
            let first = try #require(field.inputAccessoryView as? KeyboardAccessoryView)
            coordinator.activate(field)
            #expect(field.inputAccessoryView === first)
            #expect(field.text == "Unsubmitted 12.50")
            #expect(field.keyboardType == type && field.returnKeyType == .next)
            #expect(first.toolbar.items?.last?.accessibilityIdentifier == "keyboard.dismiss")
            field.removeFromSuperview()
        }
        let secure = UITextField(); secure.isSecureTextEntry = true; secure.text = "secret"
        window.addSubview(secure); coordinator.activate(secure)
        #expect(secure.inputAccessoryView is KeyboardAccessoryView)
        #expect(secure.isSecureTextEntry && secure.text == "secret")
        let editor = UITextView(); editor.text = "Line one\nLine two"
        window.addSubview(editor); coordinator.activate(editor)
        #expect(editor.inputAccessoryView is KeyboardAccessoryView)
        #expect(editor.text == "Line one\nLine two")
    }

    @Test func existingNavigationAccessoryIsPreservedAndDoneDoesNotInvokeReturn() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        let field = UITextField(frame: CGRect(x: 16, y: 100, width: 300, height: 44))
        let delegate = ReturnCounter()
        field.delegate = delegate
        field.text = "12.50"
        let navigation = UIToolbar(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        navigation.items = [UIBarButtonItem(title: "Previous", style: .plain, target: nil, action: nil),
                            UIBarButtonItem(title: "Next", style: .plain, target: nil, action: nil)]
        field.inputAccessoryView = navigation
        window.rootViewController?.view.addSubview(field)
        let coordinator = KeyboardSceneCoordinator(); coordinator.attach(to: window)
        window.makeKeyAndVisible()
        defer { coordinator.detach(); window.isHidden = true }
        #expect(field.becomeFirstResponder())
        let accessory = try #require(field.inputAccessoryView as? KeyboardAccessoryView)
        #expect(accessory.preservedAccessory === navigation)
        #expect(navigation.items?.map(\.title) == ["Previous", "Next"])
        coordinator.dismissKeyboard()
        #expect(!field.isFirstResponder)
        #expect(field.text == "12.50" && delegate.submissions == 0)
        #expect(field.delegate === delegate)
    }

    @Test func interactiveDismissalIsScopedToInputAncestorsAndRestored() {
        let window = UIWindow()
        let form = UIScrollView(); form.keyboardDismissMode = .none
        let unrelated = UIScrollView(); unrelated.keyboardDismissMode = .onDrag
        let editor = UITextView(); editor.keyboardDismissMode = .none
        window.addSubview(form); window.addSubview(unrelated); form.addSubview(editor)
        let coordinator = KeyboardSceneCoordinator(); coordinator.attach(to: window)
        coordinator.activate(editor)
        #expect(form.keyboardDismissMode == .interactiveWithAccessory && editor.keyboardDismissMode == .interactiveWithAccessory)
        #expect(unrelated.keyboardDismissMode == .onDrag)
        coordinator.detach()
        #expect(form.keyboardDismissMode == .none && editor.keyboardDismissMode == .none)
        #expect(unrelated.keyboardDismissMode == .onDrag)
    }

    @Test func frameUpdatesNeverRepositionAFormDuringDragOrRecedingKeyboard() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        let form = TrackingRegressionScrollView(frame: window.bounds)
        form.contentSize = CGSize(width: 390, height: 1800)
        let field = UITextField(frame: CGRect(x: 16, y: 1100, width: 300, height: 44))
        field.keyboardType = .numberPad
        field.text = "42"
        form.addSubview(field)
        window.rootViewController?.view.addSubview(form)
        let coordinator = KeyboardSceneCoordinator()
        coordinator.attach(to: window)
        window.makeKeyAndVisible()
        defer { coordinator.detach(); window.isHidden = true }
        #expect(field.becomeFirstResponder())
        coordinator.activate(field)
        func frame(_ y: CGFloat) {
            let rect = window.convert(CGRect(x: 0, y: y, width: 390, height: 844 - y), to: window.screen.coordinateSpace)
            NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: rect])
        }
        form.reportsTracking = true
        frame(500)
        form.contentOffset = .zero
        coordinator.revealActiveInput()
        #expect(form.contentOffset == .zero && form.contentInset.bottom == 0)
        form.reportsTracking = false
        frame(650)
        coordinator.revealActiveInput()
        #expect(form.contentOffset == .zero && form.contentInset.bottom == 0)
        #expect(field.text == "42" && field.isFirstResponder)
        // Standalone test windows do not reproduce UIKit's visible scroll layout;
        // assert the growing-frame policy directly, with rendered repair covered by UI tests.
        let shown = CGRect(x: 0, y: 500, width: 390, height: 344)
        let receding = CGRect(x: 0, y: 650, width: 390, height: 194)
        #expect(KeyboardSceneCoordinator.isReceding(previous: shown, next: receding, bounds: window.bounds, wasReceding: false))
        #expect(KeyboardSceneCoordinator.isReceding(previous: receding, next: receding, bounds: window.bounds, wasReceding: true))
        #expect(!KeyboardSceneCoordinator.isReceding(previous: receding, next: shown, bounds: window.bounds, wasReceding: true))
        #expect(!KeyboardSceneCoordinator.isReceding(previous: .null, next: shown, bounds: window.bounds, wasReceding: false))
        #expect(field.text == "42")
    }

    @Test func foreignWindowInputsAreNotModified() {
        let window = UIWindow(), otherWindow = UIWindow()
        let field = UITextField(); otherWindow.addSubview(field)
        let coordinator = KeyboardSceneCoordinator(); coordinator.attach(to: window)
        defer { coordinator.detach() }
        coordinator.activate(field)
        #expect(field.inputAccessoryView == nil)
    }

    @Test func backgroundPolicyRejectsInputsButtonsPickersMapsAndCustomGestures() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let background = UIView(frame: window.bounds); window.addSubview(background)
        #expect(KeyboardInteractionPolicy.permitsBackgroundDismissal(hitView: background, in: window, screenPoint: CGPoint(x: 20, y: 20)))
        for control in [UIButton(), UITextField(), UITextView(), UIPickerView(), MKMapView()] {
            background.addSubview(control)
            #expect(!KeyboardInteractionPolicy.permitsBackgroundDismissal(hitView: control, in: window, screenPoint: .zero))
            control.removeFromSuperview()
        }
        let custom = UIView(); custom.addGestureRecognizer(UITapGestureRecognizer())
        background.addSubview(custom)
        #expect(!KeyboardInteractionPolicy.permitsBackgroundDismissal(hitView: custom, in: window, screenPoint: .zero))
    }

    @Test func swiftUIStyleVirtualButtonIsExcludedWithoutCancellingWindowTouches() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let background = UIView(frame: window.bounds); window.addSubview(background)
        window.isHidden = false
        defer { window.isHidden = true }
        let button = UIAccessibilityElement(accessibilityContainer: background)
        button.accessibilityTraits = .button
        button.accessibilityFrame = CGRect(x: 10, y: 10, width: 100, height: 44)
        background.accessibilityElements = [button]
        #expect(!KeyboardInteractionPolicy.permitsBackgroundDismissal(hitView: background, in: window, screenPoint: CGPoint(x: 20, y: 20)))
        #expect(KeyboardInteractionPolicy.permitsBackgroundDismissal(hitView: background, in: window, screenPoint: CGPoint(x: 200, y: 200)))
        let coordinator = KeyboardSceneCoordinator(); coordinator.attach(to: window)
        defer { coordinator.detach() }
        #expect(window.gestureRecognizers?.last?.cancelsTouchesInView == false)
        #expect(window.gestureRecognizers?.last?.delaysTouchesBegan == false)
    }
}

@MainActor
private final class TrackingRegressionScrollView: UIScrollView {
    var reportsTracking: Bool = false
    override var isTracking: Bool { reportsTracking }
}

@MainActor
private final class ReturnCounter: NSObject, UITextFieldDelegate {
    var submissions: Int = 0
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { submissions += 1; return true }
}
