import Foundation

/// Store classification only. Never repairs saved fields or changes calculation eligibility.
/// Mirrored by Android ChemicalStoreAssessment.
nonisolated struct ChemicalStoreAssessment: Sendable {
    enum RevisionResolution: Sendable {
        case loading, unavailable, resolved(CatalogueWire)
        var revision: CatalogueWire? {
            if case .resolved(let revision) = self { return revision }
            return nil
        }
    }

    let details: ChemicalDetailsCompleteness
    let attentionReasons: [String]
    let isActive: Bool
    var title: String { attentionReasons.isEmpty ? details.title : "Review required" }
    var needsAttention: Bool { isActive && !attentionReasons.isEmpty }

    static func assess(_ chemical: SavedChemical, resolution: RevisionResolution = .loading) -> Self {
        // Only real, customer-visible disagreements count; enrichment and confidence do not.
        let compatibilityDetails = ChemicalDetailsCompleteness.assess(chemical)
        let verification = chemical.chemicalIntelligence?.verification
        let explicitConflict = verification?.status == .conflict && verification?.conflicts.isEmpty == true
        var reasons: [String] = compatibilityDetails.hasConflict || explicitConflict ? ["Review conflicting chemical information."] : []
        if let revisionId = chemical.chemicalV3RevisionId {
            var missing: [String] = []
            switch resolution {
            case .loading:
                missing = ["catalogue information is loading"]
            case .unavailable:
                reasons.append("Catalogue information unavailable. Retry loading the linked revision.")
            case .resolved(let revision):
                if revision.id.lowercased() != revisionId.uuidString.lowercased() {
                    reasons.append("Catalogue information unavailable. Retry loading the linked revision.")
                } else {
                    if (revision.text("product_name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        reasons.append("The linked catalogue revision has no product name.")
                    }
                    // Pending VineTrack review is not an operator task. Superseded revisions
                    // remain exact historical facts; never substitute the latest revision.
                    if ["needs_attention", "rejected"].contains(revision.text("review_status") ?? "") {
                        reasons.append("The linked catalogue revision requires review.")
                    }
                }
            }
            // No compatibility fields, resistance enrichment, or vineyard default selection
            // are required here. NOT_APPLICABLE and structured groups are valid as stored.
            return Self(details: .init(missing: missing, hasConflict: !reasons.isEmpty),
                        attentionReasons: reasons, isActive: chemical.isActive)
        }

        let slots = ChemicalDefaultRateValidity.validSlots(chemical.defaultRates)
        // Provenance alone cannot distinguish older manually entered legacy records.
        let isManual = ChemicalStorePresentation.editorKind(chemical) == .manual
        if isManual {
            let rates = slots.map { slot in
                ChemicalLabelRate(
                    basis: slot.basis == .perHectare
                        ? (slot.range == nil ? .perHectare : .rangePerHectare)
                        : (slot.range == nil ? .per100Litres : .rangePer100Litres),
                    value: slot.scalar, minValue: slot.range?.min, maxValue: slot.range?.max, unit: slot.unit)
            }
            let evaluation = ChemicalSaveContract.evaluateMinimumOperational(
                productName: chemical.name, productUnit: chemical.unit.rawValue, rates: rates)
            reasons += evaluation.violations.map(\.message)
            let storedCount = [chemical.defaultRates?.perHectare, chemical.defaultRates?.per100Litres].compactMap { $0 }.count
            if storedCount > slots.count { reasons.append("Review the unusable operational rate.") }
        } else {
            // Preserve legacy operational compatibility without demanding optional enrichment
            // or a new structured default from a historical record.
            let hasLegacyRate = chemical.rates.contains { $0.value.isFinite && $0.value > 0 }
                || chemical.ratePerHa.map { $0.isFinite && $0 > 0 } == true
            let hasLabelRate = chemical.resolvedIntelligence.registeredUses.flatMap(\.rates).contains(where: ChemicalSaveContract.isUsable)
            if chemical.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasons.append("Enter the chemical / product name.")
            }
            if slots.isEmpty && !(chemical.defaultRates == nil && (hasLegacyRate || hasLabelRate)) {
                reasons.append("Review the missing or unusable operational rate.")
            }
        }
        return Self(details: compatibilityDetails, attentionReasons: reasons, isActive: chemical.isActive)
    }

    static func activeAssessments(_ chemicals: [SavedChemical], resolutions: [UUID: RevisionResolution]) -> [UUID: Self] {
        Dictionary(ChemicalStorePresentation.active(chemicals).map { chemical in
            (chemical.id, assess(chemical, resolution: chemical.chemicalV3RevisionId.flatMap { resolutions[$0] } ?? .loading))
        }, uniquingKeysWith: { _, latest in latest })
    }
}
