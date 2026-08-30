import Foundation

/// The vineyard-only scoping rule for a saved chemical's OPERATIONAL data.
///
/// # Why this exists
///
/// The VineTrack Chemical Store describes products as a vineyard uses them. A
/// real APVMA label, however, routinely registers the same product on
/// macadamias, cereals, citrus, pasture and vegetables alongside grapevines.
/// The resolver returns all of it, and until this type existed the whole label
/// was persisted into `registered_uses` — the same collection that feeds
/// default-rate options, `viticulturalTargets`, the Spray Tool's rate
/// projection and the compliance display.
///
/// That is not a cosmetic problem. A macadamia rate sitting in the operational
/// use set is a number a spray calculation can reach. A cereal withholding
/// period is a legal figure attached to the wrong crop. Hiding those rows in
/// the UI while still saving them as ordinary uses would leave the defect
/// intact and merely invisible, which is why the partition happens at the
/// WRITE boundary.
///
/// # What is kept
///
/// ```text
/// grapevine stated uses       KEPT    — the vineyard's operational registrations
/// product-level rate carriers KEPT    — rates the label states for the PRODUCT,
///                                       belonging to no crop at all
/// every other crop            DROPPED from the operational set
/// ```
///
/// A product-level rate carrier (`ChemicalManualEntry.isProductRateCarrier`)
/// has no crop and no target by construction, so it is not "another crop" — it
/// is the product's own rate, recorded without inventing a registration claim.
/// Dropping it would discard real label content and would break every product
/// whose label quotes one rate for the whole drum.
///
/// # What is NOT dropped
///
/// Provenance survives untouched: `verification.sources`, `fieldProvenance`,
/// conflicts and the registration block are evidence about the RESEARCH, not
/// operational crop claims, and nothing here rewrites them. The lookup response
/// also keeps its own `otherCropUses`, so a review screen can still show "other
/// crops on this label" from the live research before the record is saved.
///
/// Mirrors the Android `ChemicalVineyardScope`, and the server's own
/// `grapevine_uses` / `other_crop_uses` partition in
/// `supabase/functions/chemical-info-lookup/grapevine_label.ts`. All three read
/// grapevine membership through the same whole-token predicate
/// (`ChemicalGrapevineCrop`), so `GRAPEFRUIT` can never be scoped in as a vine.
nonisolated enum ChemicalVineyardScope {

    /// Whether this use belongs in the vineyard's OPERATIONAL set.
    ///
    /// True for a grapevine registration, and for a product-level rate carrier
    /// that claims no crop at all. False for every other crop on the label.
    static func isOperational(_ use: ChemicalRegisteredUse) -> Bool {
        ChemicalManualEntry.isProductRateCarrier(use) || use.isViticultural
    }

    /// The operational partition: grapevine claims plus product-level rates.
    static func operationalUses(_ uses: [ChemicalRegisteredUse]) -> [ChemicalRegisteredUse] {
        uses.filter(isOperational)
    }

    /// The uses this scoping removes — every stated registration on a crop
    /// that is not grapevines.
    ///
    /// Exposed so a screen can say honestly HOW MUCH of the label it is not
    /// showing, rather than silently presenting a partial document as the
    /// whole one.
    static func excludedUses(_ uses: [ChemicalRegisteredUse]) -> [ChemicalRegisteredUse] {
        uses.filter { !isOperational($0) }
    }

    /// Distinct crop wordings that were excluded, in label order.
    ///
    /// The label's own wording is preserved verbatim (`"MACADAMIAS"`), because
    /// re-titling a regulator's crop name is its own small falsification.
    static func excludedCrops(_ uses: [ChemicalRegisteredUse]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for use in excludedUses(uses) {
            let crop = use.crop.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !crop.isEmpty, seen.insert(crop).inserted else { continue }
            ordered.append(crop)
        }
        return ordered
    }

    /// True when the label carries registrations for crops other than grapes.
    static func hasExcludedUses(_ uses: [ChemicalRegisteredUse]) -> Bool {
        uses.contains { !isOperational($0) }
    }

    /// Scope an intelligence payload to the vineyard before it is persisted.
    ///
    /// The ONE place `registeredUses` is narrowed. Everything else on the
    /// payload — actives, registration, verification, provenance, category — is
    /// carried through byte for byte, because none of it is a crop claim.
    ///
    /// Idempotent: scoping an already-scoped record changes nothing, so a
    /// re-save, a re-verification or an edit can never compound the filter.
    static func scoped(_ intelligence: ChemicalIntelligence) -> ChemicalIntelligence {
        let operational = operationalUses(intelligence.registeredUses)
        guard operational.count != intelligence.registeredUses.count else { return intelligence }
        var scoped = intelligence
        scoped.registeredUses = operational
        return scoped
    }

    /// The sentence shown when a label's other crops were left out.
    ///
    /// Deliberately states the RULE and the evidence, not an apology: the
    /// operator should know the document says more than the record does, and
    /// why. `nil` when nothing was excluded — an empty notice is noise.
    static func exclusionNotice(_ uses: [ChemicalRegisteredUse]) -> String? {
        let crops = excludedCrops(uses)
        guard !crops.isEmpty else { return nil }
        let listed: String
        switch crops.count {
        case 1: listed = crops[0]
        case 2: listed = "\(crops[0]) and \(crops[1])"
        default:
            listed = crops.dropLast().joined(separator: ", ") + " and " + (crops.last ?? "")
        }
        return "This label also registers \(listed). VineTrack is a vineyard record, "
            + "so only the grapevine directions are saved and used for rates and "
            + "spray calculations."
    }
}
