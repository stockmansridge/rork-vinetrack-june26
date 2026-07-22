import Foundation

/// Shared, display-only helper for rendering `PaddockVarietyAllocation`
/// summaries consistently across the app (Vineyard Summary block list,
/// block map pull-up, paddock detail, etc.).
///
/// Reference-only: this helper never participates in spray, trip, row,
/// yield, irrigation, geometry, or validation logic. It resolves the
/// display name via `PaddockVarietyResolver` and appends optional
/// `clone` / `rootstock` reference fields when present, hiding blank
/// values entirely.
nonisolated enum VarietyAllocationFormatter {

    /// A resolved, display-ready allocation line.
    struct Line: Identifiable, Sendable {
        let id: UUID
        /// Resolved variety display name (e.g. "Pinot Noir"). Nil only
        /// when the allocation cannot be resolved at all.
        let name: String?
        /// Whole-number-ish percentage string (e.g. "100%"). Nil when the
        /// allocation has no meaningful percentage.
        let percentText: String?
        /// Trimmed clone reference, or nil when blank/missing.
        let clone: String?
        /// Trimmed rootstock reference, or nil when blank/missing.
        let rootstock: String?
    }

    /// Resolve and order allocations into display-ready lines. Allocations
    /// are sorted by descending percentage so the dominant variety leads.
    /// Allocations that resolve to no name at all are dropped.
    static func lines(
        for allocations: [PaddockVarietyAllocation],
        varieties: [GrapeVariety]
    ) -> [Line] {
        allocations
            .sorted { $0.percent > $1.percent }
            .compactMap { alloc -> Line? in
                let resolved = PaddockVarietyResolver.resolve(allocation: alloc, varieties: varieties)
                let name = resolved.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let clone = alloc.clone?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rootstock = alloc.rootstock?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasName = !(name?.isEmpty ?? true)
                // Drop fully-unresolvable, content-free allocations.
                if !hasName && (clone?.isEmpty ?? true) && (rootstock?.isEmpty ?? true) {
                    return nil
                }
                return Line(
                    id: alloc.id,
                    name: hasName ? name : nil,
                    percentText: percentText(for: alloc.percent),
                    clone: (clone?.isEmpty ?? true) ? nil : clone,
                    rootstock: (rootstock?.isEmpty ?? true) ? nil : rootstock
                )
            }
    }

    /// Compact single-line summary for one allocation, e.g.
    /// `Pinot Noir 100% · Clone MV6 · Rootstock 101-14`.
    /// Blank clone/rootstock segments are omitted.
    static func compactLine(_ line: Line) -> String {
        var head = line.name ?? ""
        if let pct = line.percentText {
            head += head.isEmpty ? pct : " \(pct)"
        }
        var segments: [String] = []
        if !head.isEmpty { segments.append(head) }
        if let clone = line.clone { segments.append("Clone \(clone)") }
        if let rootstock = line.rootstock { segments.append("Rootstock \(rootstock)") }
        return segments.joined(separator: " · ")
    }

    /// Convenience: compact lines for an allocation set, one string per
    /// variety. Useful for stacked multi-variety summaries.
    static func compactLines(
        for allocations: [PaddockVarietyAllocation],
        varieties: [GrapeVariety]
    ) -> [String] {
        lines(for: allocations, varieties: varieties).map(compactLine)
    }

    /// A single joined summary suitable for one-line contexts. Multiple
    /// varieties are separated by `", "`. Returns nil when there is
    /// nothing to show.
    static func oneLineSummary(
        for allocations: [PaddockVarietyAllocation],
        varieties: [GrapeVariety]
    ) -> String? {
        let parts = compactLines(for: allocations, varieties: varieties)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Format a percentage as a compact string. Whole numbers drop the
    /// decimal; fractional values keep one place. Zero/blank -> nil.
    static func percentText(for percent: Double) -> String? {
        guard percent > 0 else { return nil }
        if percent.rounded() == percent {
            return "\(Int(percent))%"
        }
        return String(format: "%.1f%%", percent)
    }
}
