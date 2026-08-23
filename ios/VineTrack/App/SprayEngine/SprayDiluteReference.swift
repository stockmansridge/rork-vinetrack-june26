import Foundation

/// How the dilute / runoff reference is resolved from the canopy and the
/// operator's own entry.
///
/// This is a rule, not a view detail, so it lives outside the screen: the
/// override must behave identically wherever it is read, and a rule buried in a
/// SwiftUI body cannot be tested without rendering one.
///
/// The override is held in the TEXT FIELD itself, and an empty field means "use
/// the canopy". Nothing ever writes the canopy value into that field, which is
/// what makes a manual entry survive canopy changes and redraws — there is no
/// moment at which a recalculation could overwrite what the operator typed.
nonisolated enum SprayDiluteReference {

    /// The operator's own dilute figure, when they have typed a usable one.
    ///
    /// Blank, non-numeric and non-positive entries are all "no override" rather
    /// than zero: a zero dilute would divide the concentration factor by
    /// nothing, and a half-typed "1." should not momentarily redefine the job.
    static func manualLitresPer100m(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The dilute / runoff rate fed to the engine, in L/100 m.
    ///
    /// `supportsCanopy` is false for a spreader: a granular pass is not a
    /// concentration of anything, and inventing a reference for it would
    /// multiply every per-100 L product on the job.
    static func effectiveLitresPer100m(
        manualText: String,
        canopyLitresPer100m: Double,
        supportsCanopy: Bool
    ) -> Double? {
        if let manual = manualLitresPer100m(from: manualText) { return manual }
        guard supportsCanopy else { return nil }
        return canopyLitresPer100m > 0 ? canopyLitresPer100m : nil
    }

    /// Whether the figure in use came from the operator rather than the canopy.
    ///
    /// Drives both the "Manual override" wording and whether `Use calculated`
    /// is offered, so the two can never disagree about which number is live.
    static func isOverridden(manualText: String) -> Bool {
        manualLitresPer100m(from: manualText) != nil
    }

    /// What `Use calculated` writes back: an empty field, which restores the
    /// canopy figure by removing the override rather than by copying a value.
    static let clearedOverrideText: String = ""
}
