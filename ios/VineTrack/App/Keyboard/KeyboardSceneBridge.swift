import SwiftUI
import UIKit

/// Installs scene-window keyboard handling, including controls in presented sheets and full-screen covers.
struct KeyboardSceneBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardSceneAnchorView { KeyboardSceneAnchorView() }
    func updateUIView(_ uiView: KeyboardSceneAnchorView, context: Context) {}
    static func dismantleUIView(_ uiView: KeyboardSceneAnchorView, coordinator: Void) { uiView.keyboardCoordinator.detach() }
}
