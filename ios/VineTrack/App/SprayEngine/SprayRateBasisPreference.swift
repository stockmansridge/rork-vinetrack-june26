import Foundation

/// Which LABEL rate basis a vineyard's carrier workflow should start from.
///
/// # Why this exists as one shared rule
///
/// A product can carry two perfectly valid label rates — `200 g/100 L` for
/// dilute spraying and `2.5 kg/ha` as a concentrate instruction — and both are
/// stored, because both are what the label says. Which one a job should START
/// from is not a property of the product; it is a property of the WORKFLOW.
///
/// The 100 m runoff workflow begins with dilute carrier volume per 100 m of
/// row. Its natural arithmetic is:
///
/// ```text
/// label rate /100 L  ×  runoff carrier L/100 m  →  product /100 m
///                                              →  derived /ha, tank totals
/// ```
///
/// Starting that workflow from a per-hectare rate makes the operator reconcile
/// two different carrier models by hand. Conversely a vineyard entering carrier
/// volume in L/ha should start from the per-hectare rate.
///
/// Before this type the preference was inferred, per call site, from the legacy
/// `ratePer100L` scalar — a value the consolidated Chemical Store no longer
/// edits and which is now projected from the structured record. A product whose
/// only structured rate was per-100 L still projected a zero into that scalar,
/// so every call site read "no per-100 L rate" and defaulted to per hectare.
/// One rule, in one place, is what stops that drifting apart again.
///
/// # What it does NOT do
///
/// It expresses a PREFERENCE ORDER over rates that actually exist. It never
/// converts a rate, never invents the missing basis, and never suppresses a
/// rate the label states. A product registered only as `2.5 kg/ha` stays
/// `2.5 kg/ha` in a 100 m vineyard, and the existing planner rules deal with
/// the fact that no per-100 L label rate exists.
nonisolated enum SprayRateBasisPreference {

    /// The label rate bases to try, strongest preference first.
    ///
    /// Both bases always appear: the preference decides which is tried FIRST,
    /// never which is allowed. A vineyard on the 100 m workflow with a
    /// per-hectare-only product still gets its per-hectare rate.
    static func order(for carrier: SprayCarrierBasis) -> [ChemicalRateBasis] {
        switch carrier {
        case .litresPer100Metres: return [.per100Litres, .perHectare]
        case .litresPerHectare: return [.perHectare, .per100Litres]
        // A manual job states total litres, so a per-100 L label rate is the
        // one that reads straight off it. Per-hectare rates remain fully
        // available — the order is a preference, never a restriction.
        case .manualTotalVolume: return [.per100Litres, .perHectare]
        }
    }

    /// The basis a fresh product line should adopt when the product offers no
    /// selectable rate at all.
    ///
    /// Deliberately the workflow's own basis rather than a hardcoded
    /// per-hectare: an operator on the 100 m runoff workflow typing a rate by
    /// hand is typing a per-100 L rate.
    static func fallbackBasis(for carrier: SprayCarrierBasis) -> ChemicalRateBasis {
        order(for: carrier)[0]
    }

    /// The preference order for a vineyard, from its resolved spray profile.
    ///
    /// Used where a live carrier choice is not in scope — composing a Program
    /// Step, for instance, which is configuration rather than an application.
    static func order(for profile: SprayVineyardProfile) -> [ChemicalRateBasis] {
        order(for: profile.defaultCarrierBasis)
    }

    static func fallbackBasis(for profile: SprayVineyardProfile) -> ChemicalRateBasis {
        fallbackBasis(for: profile.defaultCarrierBasis)
    }
}
