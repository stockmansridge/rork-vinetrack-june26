import UIKit
import MapKit

/// Conservative hit testing: only passive content may dismiss; controls and map gestures are untouched.
enum KeyboardInteractionPolicy {
    static func permitsBackgroundDismissal(hitView: UIView, in window: UIWindow, screenPoint: CGPoint) -> Bool {
        var ancestor: UIView? = hitView
        while let view = ancestor, view !== window {
            if view is UIControl || view is UITextView || view is UIPickerView || view is MKMapView {
                return false
            }
            if isInteractive(view.accessibilityTraits) { return false }
            // Hosting/scroll containers own recognizers for all descendants, including blank space.
            // Only leaf custom gesture surfaces are excluded here; semantic controls are checked below.
            if view === hitView, view.subviews.isEmpty, !(view is UIScrollView),
               view !== window.rootViewController?.view,
               view.gestureRecognizers?.contains(where: { $0.isEnabled && !($0 is UIPanGestureRecognizer) }) == true {
                return false
            }
            ancestor = view.superview
        }
        // SwiftUI buttons/pickers may be virtual accessibility elements, not UIControls.
        var visited: Set<ObjectIdentifier> = []
        var budget = 1024
        return !containsInteractiveElement(window, at: screenPoint, visited: &visited, budget: &budget)
    }

    private static func isInteractive(_ traits: UIAccessibilityTraits) -> Bool {
        !traits.intersection([.button, .link, .adjustable, .searchField, .keyboardKey, .allowsDirectInteraction]).isEmpty
    }

    private static func containsInteractiveElement(_ element: NSObject, at point: CGPoint,
                                                    visited: inout Set<ObjectIdentifier>, budget: inout Int) -> Bool {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return false }
        guard budget > 0 else { return true }
        budget -= 1
        if let view = element as? UIView, view.isHidden || view.alpha < 0.01 { return false }
        if element.accessibilityFrame.contains(point),
           isInteractive(element.accessibilityTraits) || (element.isAccessibilityElement && element.accessibilityRespondsToUserInteraction) {
            return true
        }
        if let elements = element.accessibilityElements {
            for child in elements {
                if let child = child as? NSObject,
                   containsInteractiveElement(child, at: point, visited: &visited, budget: &budget) { return true }
            }
        }
        if let view = element as? UIView {
            for child in view.subviews where child.convert(child.bounds, to: nil).contains(point) {
                if containsInteractiveElement(child, at: point, visited: &visited, budget: &budget) { return true }
            }
        }
        return false
    }
}
