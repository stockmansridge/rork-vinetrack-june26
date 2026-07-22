import Foundation

/// Simple row-by-row completion result used by the End Trip Review, Trip
/// Detail, and Trip PDF. The derivation is intentionally pure: given the
/// trip's `rowSequence`, `completedPaths`, `skippedPaths`, and
/// `manualCorrectionEvents`, it produces a flat list answering the only
/// question the operator cares about: "Was each planned row completed,
/// partial, or not completed — and why?"
///
/// The same fields are already synced to Supabase, so Lovable can reproduce
/// this list server-side without any schema change.
nonisolated enum RowCompletionStatus: String, Sendable {
    case complete
    case partial
    case notComplete = "not_complete"

    var label: String {
        switch self {
        case .complete: return "Complete"
        case .partial: return "Partial"
        case .notComplete: return "Not complete"
        }
    }

    /// SF Symbol name for in-app rendering.
    var iconName: String {
        switch self {
        case .complete: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .notComplete: return "xmark.circle.fill"
        }
    }

    /// Plain-text marker for PDF / share output where SF Symbols aren't
    /// available. Emoji render reliably in UIKit text drawing.
    var emoji: String {
        switch self {
        case .complete: return "✅"
        case .partial: return "⚠️"
        case .notComplete: return "❌"
        }
    }
}

nonisolated enum RowCompletionSource: String, Sendable {
    case auto
    case manual
    case endReview = "end_review"

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .manual: return "Manual"
        case .endReview: return "End review"
        }
    }
}

nonisolated struct RowCompletionResult: Sendable, Identifiable, Hashable {
    let path: Double
    let status: RowCompletionStatus
    let source: RowCompletionSource?

    var id: Double { path }

    var formattedPath: String {
        if path.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", path)
        }
        return String(format: "%.1f", path)
    }

    /// Operator-friendly one-line summary, e.g. "Complete — Auto" or
    /// "Not complete".
    var statusAndSourceLabel: String {
        if let source {
            return "\(status.label) — \(source.label)"
        }
        return status.label
    }
}

nonisolated enum RowCompletionDeriver {
    /// Derive the per-row completion list from the trip's stored fields.
    static func results(for trip: Trip) -> [RowCompletionResult] {
        results(
            rowSequence: trip.rowSequence,
            completedPaths: trip.completedPaths,
            skippedPaths: trip.skippedPaths,
            manualCorrectionEvents: trip.manualCorrectionEvents
        )
    }

    static func results(
        rowSequence: [Double],
        completedPaths: [Double],
        skippedPaths: [Double],
        manualCorrectionEvents: [String]
    ) -> [RowCompletionResult] {
        let completed = Set(completedPaths)
        let skipped = Set(skippedPaths)
        let manualPaths = parseManualCompleted(manualCorrectionEvents)
        let endReviewPaths = parseEndReviewCompleted(manualCorrectionEvents)

        return rowSequence.map { path in
            if completed.contains(where: { abs($0 - path) < 0.01 }) {
                let source: RowCompletionSource = {
                    if endReviewPaths.contains(where: { abs($0 - path) < 0.01 }) {
                        return .endReview
                    }
                    if manualPaths.contains(where: { abs($0 - path) < 0.01 }) {
                        return .manual
                    }
                    return .auto
                }()
                return RowCompletionResult(path: path, status: .complete, source: source)
            }
            if skipped.contains(where: { abs($0 - path) < 0.01 }) {
                return RowCompletionResult(path: path, status: .partial, source: .auto)
            }
            return RowCompletionResult(path: path, status: .notComplete, source: nil)
        }
    }

    // MARK: - Audit-event parsing

    /// Paths the operator manually ticked complete via the row toolbar
    /// (`Done <row>`) during the trip.
    static func parseManualCompleted(_ events: [String]) -> [Double] {
        var out: [Double] = []
        let marker = "manual_complete: "
        for event in events {
            guard let r = event.range(of: marker) else { continue }
            let tail = event[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = Double(tail) { out.append(d) }
        }
        return out
    }

    /// Paths ticked complete from the End Trip Review sheet, recorded as
    /// `end_review_completed: [a,b,c]`.
    static func parseEndReviewCompleted(_ events: [String]) -> [Double] {
        var out: [Double] = []
        let marker = "end_review_completed: ["
        for event in events {
            guard let r = event.range(of: marker),
                  let end = event.range(of: "]", range: r.upperBound..<event.endIndex) else { continue }
            let inner = event[r.upperBound..<end.lowerBound]
            for piece in inner.split(separator: ",") {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if let d = Double(trimmed) { out.append(d) }
            }
        }
        return out
    }
}
