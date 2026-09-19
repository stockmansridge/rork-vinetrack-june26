import SwiftUI
import UIKit
import AVFoundation

struct CameraImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImageCaptured: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied,
              AVCaptureDevice.authorizationStatus(for: .video) != .restricted else {
            let denied = UIAlertController(
                title: "Camera access denied",
                message: "Allow camera access in Settings to capture field evidence.",
                preferredStyle: .alert
            )
            denied.addAction(UIAlertAction(title: "Close", style: .cancel) { _ in
                onImageCaptured(nil)
                dismiss()
            })
            denied.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                onImageCaptured(nil)
                dismiss()
            })
            return denied
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            let unavailable = UIAlertController(
                title: "Camera unavailable",
                message: "This device does not have an available camera. No library image will be substituted for field evidence.",
                preferredStyle: .alert
            )
            unavailable.addAction(UIAlertAction(title: "Close", style: .default) { _ in
                onImageCaptured(nil)
                dismiss()
            })
            return unavailable
        }
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        return picker
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImageCaptured: onImageCaptured, dismiss: dismiss)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImageCaptured: (Data?) -> Void
        let dismiss: DismissAction

        init(onImageCaptured: @escaping (Data?) -> Void, dismiss: DismissAction) {
            self.onImageCaptured = onImageCaptured
            self.dismiss = dismiss
        }

        nonisolated func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            Task { @MainActor in
                if let image = info[.originalImage] as? UIImage {
                    let data = image.jpegData(compressionQuality: 0.8)
                    onImageCaptured(data)
                } else {
                    onImageCaptured(nil)
                }
                dismiss()
            }
        }

        nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            Task { @MainActor in
                onImageCaptured(nil)
                dismiss()
            }
        }
    }
}
