import SwiftUI
import UIKit

/// Native sharing is presented only after the diagnostics screen re-verifies access.
struct PerformanceTimingShareSheet: UIViewControllerRepresentable {
    let report: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [report], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
