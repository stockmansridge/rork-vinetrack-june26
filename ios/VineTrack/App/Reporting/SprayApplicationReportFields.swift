import Foundation

/// Display only: recorded intent, never inferred from products, blocks or current settings.
nonisolated struct SprayApplicationReportFields {
    let targets: String
    let sprayHead: String
    let ground: String
    let mode: String

    init(snapshot: SprayApplicationSnapshot?) {
        if snapshot?.targets == nil && snapshot?.customTargets == nil {
            targets = "Not recorded"
        } else {
            let entries = (snapshot?.targets ?? []).map(\.label) + (snapshot?.customTargets ?? [])
            targets = entries.isEmpty ? "None recorded" : entries.joined(separator: "; ")
        }
        sprayHead = snapshot?.sprayHeadTarget?.label ?? "Not recorded"
        ground = snapshot?.groundTarget?.label ?? "Not recorded"
        mode = snapshot?.applicationMode?.rawValue.replacingOccurrences(of: "_", with: " ").capitalized ?? "Not recorded"
    }

    var values: [String] { [targets, sprayHead, ground, mode] }
    static let headers: [String] = ["Disease/pest targets", "Spray-head application location", "Ground application location", "Application mode"]
}
