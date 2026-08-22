import SwiftUI

/// Lightweight, backend-neutral access control surface used by imported legacy
/// spray screens. As of Phase 8A this defaults to a safely locked-down state
/// (all `false`); the real values are bridged in from `BackendAccessControl`
/// via `legacyAccessControl` based on the user's `BackendRole`.
struct LegacyAccessControl {
    var canDelete: Bool = false
    var canExport: Bool = false
    var canExportFinancialPDF: Bool = false
    var canViewFinancials: Bool = false
    /// Costing visibility (labour/fuel/chemical/total trip cost, operator
    /// hourly rates, fuel cost per litre). Owners + managers only. Mirrors
    /// `canViewFinancials` — kept as a distinct flag so future costing
    /// surfaces can be gated independently if needed.
    var canViewCosting: Bool = false
    /// May agree a price in the field (piece rate per vine on an unpriced job)
    /// and see that one job's total while entering it. Owners, managers AND
    /// supervisors. Never grants review of an already-priced job, and never
    /// exposes a total, summary or report — those stay on `canViewCosting`.
    var canEnterPricing: Bool = false
    var canFinalizeRecords: Bool = false
    var canReopenRecords: Bool = false
    /// Owner/manager only — controls who can create, edit, or delete shared
    /// vineyard setup data such as chemicals, presets, equipment, tractors,
    /// operator categories, varieties, and button templates.
    var canManageSetup: Bool = false
    /// Owner/manager only — may edit the vineyard's shared Spray Program,
    /// including the Program Steps that are synced with the Admin Portal.
    /// Mirrors the `spray_jobs` UPDATE policy (sql/032) rather than reusing a
    /// neighbouring flag, so the two can never drift apart silently.
    var canManageSprayProgram: Bool = false
    /// Every role. The existing rule for editing a LOCAL Program Step, carried
    /// here unchanged so the shared editor does not tighten it.
    var canEditRecords: Bool = false
}

private struct LegacyAccessControlKey: EnvironmentKey {
    static let defaultValue: LegacyAccessControl? = LegacyAccessControl()
}

extension EnvironmentValues {
    var accessControl: LegacyAccessControl? {
        get { self[LegacyAccessControlKey.self] }
        set { self[LegacyAccessControlKey.self] = newValue }
    }
}
