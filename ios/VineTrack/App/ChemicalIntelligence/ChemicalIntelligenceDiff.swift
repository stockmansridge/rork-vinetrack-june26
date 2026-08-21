import Foundation

/// Which part of a chemical record a change concerns.
///
/// Grouped by `section` so the review screen can lead with the chemistry that
/// changes a resistance decision and keep registry housekeeping further down.
nonisolated enum ChemicalIntelligenceDiffField: String, Codable, Sendable, Hashable, CaseIterable {
    // Identity
    case productName = "product_name"
    case registrant
    case registrationIdentifier = "registration_identifier"
    case country
    case registrationScheme = "registration_scheme"
    // Actives
    case activeIngredient = "active_ingredient"
    case activeConcentration = "active_concentration"
    case concentrationUnit = "concentration_unit"
    // Groups
    case activityGroupCode = "activity_group_code"
    case activityGroupScheme = "activity_group_scheme"
    // Label rates
    case labelRate = "label_rate"
    // Registered uses
    case registeredUse = "registered_use"
    case registeredUseRate = "registered_use_rate"
    case withholdingPeriod = "withholding_period"
    case reEntryPeriod = "re_entry_period"
    // Evidence / versions
    case source
    case labelVersion = "label_version"
    case activityGroupTableVersion = "activity_group_table_version"

    nonisolated var label: String {
        switch self {
        case .productName: return "Product name"
        case .registrant: return "Registrant"
        case .registrationIdentifier: return "Registration number"
        case .country: return "Country"
        case .registrationScheme: return "Registration scheme"
        case .activeIngredient: return "Active ingredient"
        case .activeConcentration: return "Concentration"
        case .concentrationUnit: return "Concentration unit"
        case .activityGroupCode: return "Activity group"
        case .activityGroupScheme: return "Activity group scheme"
        case .labelRate: return "Label rate"
        case .registeredUse: return "Registered use"
        case .registeredUseRate: return "Registered use rate"
        case .withholdingPeriod: return "Withholding period"
        case .reEntryPeriod: return "Re-entry period"
        case .source: return "Source"
        case .labelVersion: return "Label version"
        case .activityGroupTableVersion: return "Activity group table"
        }
    }

    nonisolated var section: ChemicalIntelligenceDiffSection {
        switch self {
        case .productName, .registrant, .registrationIdentifier, .country, .registrationScheme:
            return .identity
        case .activeIngredient, .activeConcentration, .concentrationUnit:
            return .actives
        case .activityGroupCode, .activityGroupScheme:
            return .activityGroups
        case .labelRate:
            return .labelRates
        case .registeredUse, .registeredUseRate, .withholdingPeriod, .reEntryPeriod:
            return .registeredUses
        case .source, .labelVersion, .activityGroupTableVersion:
            return .evidence
        }
    }

    /// Whether this field alone can change what the future Resistance Engine
    /// concludes. Drives the emphasis on the review screen — a new FRAC code is
    /// not the same kind of news as a new label URL.
    nonisolated var isResistanceCritical: Bool {
        switch self {
        case .activeIngredient, .activeConcentration, .concentrationUnit,
             .activityGroupCode, .activityGroupScheme,
             .registrationIdentifier, .country, .registrationScheme:
            return true
        case .productName, .registrant, .labelRate, .registeredUse, .registeredUseRate,
             .withholdingPeriod, .reEntryPeriod, .source, .labelVersion,
             .activityGroupTableVersion:
            return false
        }
    }
}

/// Presentation grouping for the review screen.
nonisolated enum ChemicalIntelligenceDiffSection: String, Codable, Sendable, Hashable, CaseIterable {
    case identity
    case actives
    case activityGroups = "activity_groups"
    case labelRates = "label_rates"
    case registeredUses = "registered_uses"
    case evidence

    nonisolated var label: String {
        switch self {
        case .identity: return "Product identity"
        case .actives: return "Active ingredients"
        case .activityGroups: return "Activity groups"
        case .labelRates: return "Label rates"
        case .registeredUses: return "Registered uses"
        case .evidence: return "Evidence and versions"
        }
    }

    /// Order the sections are presented in: chemistry first.
    nonisolated var displayOrder: Int {
        switch self {
        case .activityGroups: return 0
        case .actives: return 1
        case .identity: return 2
        case .labelRates: return 3
        case .registeredUses: return 4
        case .evidence: return 5
        }
    }
}

nonisolated enum ChemicalIntelligenceChangeKind: String, Codable, Sendable, Hashable {
    case added
    case removed
    case changed

    nonisolated var label: String {
        switch self {
        case .added: return "Added"
        case .removed: return "Removed"
        case .changed: return "Changed"
        }
    }
}

/// One structural difference between the stored record and a lookup candidate.
nonisolated struct ChemicalIntelligenceChange: Sendable, Hashable, Identifiable {
    let field: ChemicalIntelligenceDiffField
    let kind: ChemicalIntelligenceChangeKind
    /// What the change is ABOUT when the field repeats — an active's name, or a
    /// `"Grapes — Powdery mildew"` use. `nil` for record-level fields.
    let subject: String?
    /// Rendered current value. `nil` for an addition.
    let currentValue: String?
    /// Rendered candidate value. `nil` for a removal.
    let candidateValue: String?

    nonisolated var id: String {
        "\(field.rawValue)|\(kind.rawValue)|\(subject ?? "")|\(currentValue ?? "")|\(candidateValue ?? "")"
    }

    nonisolated var section: ChemicalIntelligenceDiffSection { field.section }
    nonisolated var isResistanceCritical: Bool { field.isResistanceCritical }

    /// `"Activity group — Azoxystrobin"`.
    nonisolated var title: String {
        guard let subject, !subject.isEmpty else { return field.label }
        return "\(field.label) — \(subject)"
    }
}

/// The result of comparing a stored chemical against a lookup candidate.
///
/// This is a comparison of MEANING, not of JSON. Two records that list the same
/// two actives in a different order, or cite the same sources in a different
/// order, are the same record — reporting that as "updated information found"
/// would train operators to accept updates without reading them, which is
/// exactly how a real FRAC change slips through unnoticed.
nonisolated struct ChemicalIntelligenceDiff: Sendable, Hashable {
    let changes: [ChemicalIntelligenceChange]

    nonisolated var isEmpty: Bool { changes.isEmpty }
    nonisolated var hasMeaningfulChanges: Bool { !changes.isEmpty }

    /// Whether anything changed that the Resistance Engine would read.
    nonisolated var hasResistanceCriticalChanges: Bool {
        changes.contains(where: \.isResistanceCritical)
    }

    /// Changes that are only evidence/version housekeeping. A record whose
    /// diff is entirely this is "current, freshly confirmed" rather than
    /// "updated" — see `ChemicalReverification.isNoChangeResult`.
    nonisolated var isEvidenceOnly: Bool {
        !changes.isEmpty && changes.allSatisfy { $0.section == .evidence }
    }

    nonisolated func changes(in section: ChemicalIntelligenceDiffSection) -> [ChemicalIntelligenceChange] {
        changes.filter { $0.section == section }
    }

    /// Sections that actually contain changes, chemistry first.
    nonisolated var populatedSections: [ChemicalIntelligenceDiffSection] {
        var seen = Set<String>()
        return changes
            .map(\.section)
            .filter { seen.insert($0.rawValue).inserted }
            .sorted { $0.displayOrder < $1.displayOrder }
    }
}

/// Compares stored Chemical Intelligence against a lookup candidate.
///
/// Mirrors `ChemicalIntelligenceDiffer.kt` decision for decision: both platforms
/// review the same re-verification and must reach the same list of changes, or a
/// grower on an iPhone and a grower on a Pixel would be shown different reasons
/// to accept the same update.
nonisolated enum ChemicalIntelligenceDiffer {

    /// - Parameters:
    ///   - current: what the Chemical Store holds now. `nil`/empty is treated as
    ///     "nothing known yet", so every populated candidate field is an addition.
    ///   - candidate: what the lookup proposes. Never written anywhere by this
    ///     function — diffing is a read-only act.
    static func diff(
        current: ChemicalIntelligence?,
        candidate: ChemicalIntelligence
    ) -> ChemicalIntelligenceDiff {
        var changes: [ChemicalIntelligenceChange] = []
        let existing = current ?? ChemicalIntelligence()

        diffIdentity(existing.registration, candidate.registration, into: &changes)
        diffActives(existing.activeIngredients, candidate.activeIngredients, into: &changes)
        diffGroups(existing, candidate, into: &changes)
        diffUses(
            existing.registeredUses,
            candidate.registeredUses,
            currentHasLabelSource: existing.hasManufacturerLabelSource,
            candidateHasLabelSource: candidate.hasManufacturerLabelSource,
            into: &changes
        )
        diffEvidence(existing, candidate, into: &changes)

        return ChemicalIntelligenceDiff(changes: changes)
    }

    // MARK: - Identity

    private static func diffIdentity(
        _ current: ChemicalRegistration?,
        _ candidate: ChemicalRegistration?,
        into changes: inout [ChemicalIntelligenceChange]
    ) {
        compare(.productName,
                current?.registeredProductName, candidate?.registeredProductName,
                into: &changes)
        compare(.registrant, current?.registrant, candidate?.registrant, into: &changes)
        compare(.registrationIdentifier,
                current?.registrationNumber, candidate?.registrationNumber,
                into: &changes)
        compare(.country,
                current?.countryCode.isEmpty == true ? nil : current?.countryCode,
                candidate?.countryCode.isEmpty == true ? nil : candidate?.countryCode,
                into: &changes)
        compare(.registrationScheme,
                current?.scheme?.label, candidate?.scheme?.label,
                into: &changes)
    }

    // MARK: - Actives

    /// Actives are matched by normalised NAME, never by position, so reordering
    /// a two-active mixture reports nothing.
    private static func diffActives(
        _ current: [ChemicalActiveIngredient],
        _ candidate: [ChemicalActiveIngredient],
        into changes: inout [ChemicalIntelligenceChange]
    ) {
        var currentByName: [String: ChemicalActiveIngredient] = [:]
        for active in current where !active.name.isEmpty {
            currentByName[key(active.name)] = active
        }
        var candidateByName: [String: ChemicalActiveIngredient] = [:]
        for active in candidate where !active.name.isEmpty {
            candidateByName[key(active.name)] = active
        }

        for active in candidate where !active.name.isEmpty {
            guard let prior = currentByName[key(active.name)] else {
                changes.append(
                    ChemicalIntelligenceChange(
                        field: .activeIngredient,
                        kind: .added,
                        subject: active.name,
                        currentValue: nil,
                        candidateValue: active.displayLabelWithGroup
                    )
                )
                continue
            }
            if prior.concentration != active.concentration {
                changes.append(
                    ChemicalIntelligenceChange(
                        field: .activeConcentration,
                        kind: .changed,
                        subject: active.name,
                        currentValue: concentrationText(prior),
                        candidateValue: concentrationText(active)
                    )
                )
            }
            if prior.concentrationUnit != active.concentrationUnit {
                changes.append(
                    ChemicalIntelligenceChange(
                        field: .concentrationUnit,
                        kind: .changed,
                        subject: active.name,
                        currentValue: prior.concentrationUnit?.label,
                        candidateValue: active.concentrationUnit?.label
                    )
                )
            }
        }

        for active in current where !active.name.isEmpty {
            if candidateByName[key(active.name)] == nil {
                changes.append(
                    ChemicalIntelligenceChange(
                        field: .activeIngredient,
                        kind: .removed,
                        subject: active.name,
                        currentValue: active.displayLabelWithGroup,
                        candidateValue: nil
                    )
                )
            }
        }
    }

    // MARK: - Activity groups

    /// Groups are diffed twice over, deliberately.
    ///
    /// Per active, because "Azoxystrobin moved from FRAC 11 to FRAC 3" is the
    /// sentence an operator needs. And at product level, because a group can
    /// appear or vanish through an active being added or removed, and the set of
    /// groups the product belongs to is what resistance rotation is actually
    /// planned against.
    private static func diffGroups(
        _ current: ChemicalIntelligence,
        _ candidate: ChemicalIntelligence,
        into changes: inout [ChemicalIntelligenceChange]
    ) {
        var currentByName: [String: ChemicalActiveIngredient] = [:]
        for active in current.activeIngredients where !active.name.isEmpty {
            currentByName[key(active.name)] = active
        }

        for active in candidate.activeIngredients where !active.name.isEmpty {
            guard let prior = currentByName[key(active.name)] else { continue }
            let before = prior.activityGroup
            let after = active.activityGroup
            if before?.scheme != after?.scheme {
                changes.append(
                    ChemicalIntelligenceChange(
                        field: .activityGroupScheme,
                        kind: kind(before == nil, after == nil),
                        subject: active.name,
                        currentValue: before?.scheme.label,
                        candidateValue: after?.scheme.label
                    )
                )
            }
            if before?.code != after?.code {
                changes.append(
                    ChemicalIntelligenceChange(
                        field: .activityGroupCode,
                        kind: kind(before == nil, after == nil),
                        subject: active.name,
                        currentValue: before?.displayLabel,
                        candidateValue: after?.displayLabel
                    )
                )
            }
        }

        // Product-level set comparison, order-insensitive by construction.
        let before = Set(current.activityGroups.map(\.id))
        let after = Set(candidate.activityGroups.map(\.id))
        for group in candidate.activityGroups where !before.contains(group.id) {
            // Only report at product level if no per-active change already said
            // it, so a single reclassification is not listed twice.
            guard !changes.contains(where: {
                $0.field == .activityGroupCode && $0.candidateValue == group.displayLabel
            }) else { continue }
            changes.append(
                ChemicalIntelligenceChange(
                    field: .activityGroupCode,
                    kind: .added,
                    subject: nil,
                    currentValue: nil,
                    candidateValue: group.displayLabel
                )
            )
        }
        for group in current.activityGroups where !after.contains(group.id) {
            guard !changes.contains(where: {
                $0.field == .activityGroupCode && $0.currentValue == group.displayLabel
            }) else { continue }
            changes.append(
                ChemicalIntelligenceChange(
                    field: .activityGroupCode,
                    kind: .removed,
                    subject: nil,
                    currentValue: group.displayLabel,
                    candidateValue: nil
                )
            )
        }
    }

    // MARK: - Registered uses and label rates

    /// Uses are keyed on crop + target so reordering the label's use table
    /// reports nothing, and rate sets are compared as sets for the same reason.
    private static func diffUses(
        _ current: [ChemicalRegisteredUse],
        _ candidate: [ChemicalRegisteredUse],
        currentHasLabelSource: Bool,
        candidateHasLabelSource: Bool,
        into changes: inout [ChemicalIntelligenceChange]
    ) {
        var currentByKey: [String: ChemicalRegisteredUse] = [:]
        for use in current { currentByKey[useKey(use)] = use }
        var candidateByKey: [String: ChemicalRegisteredUse] = [:]
        for use in candidate { candidateByKey[useKey(use)] = use }

        for use in candidate {
            guard let prior = currentByKey[useKey(use)] else {
                changes.append(
                    ChemicalIntelligenceChange(
                        field: .registeredUse,
                        kind: .added,
                        subject: nil,
                        currentValue: nil,
                        candidateValue: useLabel(use)
                    )
                )
                continue
            }
            diffRates(prior.rates, use.rates, subject: useLabel(use), into: &changes)
            if prior.withholdingPeriodDays != use.withholdingPeriodDays {
                changes.append(
                    ChemicalIntelligenceChange(
                        field: .withholdingPeriod,
                        kind: kind(prior.withholdingPeriodDays == nil, use.withholdingPeriodDays == nil),
                        subject: useLabel(use),
                        // Same display rule as every other withholding surface:
                        // a zero reads as the label's "not required" wording only
                        // where that side's own evidence carries it, and each side
                        // is judged on its OWN restrictions and sources. Wording
                        // only — the comparison above is on the raw values.
                        currentValue: ChemicalWithholdingDisplay.text(
                            days: prior.withholdingPeriodDays,
                            restrictions: prior.restrictions,
                            hasManufacturerLabelSource: currentHasLabelSource
                        ),
                        candidateValue: ChemicalWithholdingDisplay.text(
                            days: use.withholdingPeriodDays,
                            restrictions: use.restrictions,
                            hasManufacturerLabelSource: candidateHasLabelSource
                        )
                    )
                )
            }
            if prior.reEntryPeriodHours != use.reEntryPeriodHours {
                changes.append(
                    ChemicalIntelligenceChange(
                        field: .reEntryPeriod,
                        kind: kind(prior.reEntryPeriodHours == nil, use.reEntryPeriodHours == nil),
                        subject: useLabel(use),
                        currentValue: prior.reEntryPeriodHours.map { "\($0) hours" },
                        candidateValue: use.reEntryPeriodHours.map { "\($0) hours" }
                    )
                )
            }
        }

        for use in current where candidateByKey[useKey(use)] == nil {
            changes.append(
                ChemicalIntelligenceChange(
                    field: .registeredUse,
                    kind: .removed,
                    subject: nil,
                    currentValue: useLabel(use),
                    candidateValue: nil
                )
            )
        }
    }

    /// Rates within one use. A changed VALUE on the same basis is reported as a
    /// change rather than an add + remove pair, because "100 → 80–100 mL/100 L"
    /// is one decision for the operator, not two facts.
    private static func diffRates(
        _ current: [ChemicalLabelRate],
        _ candidate: [ChemicalLabelRate],
        subject: String,
        into changes: inout [ChemicalIntelligenceChange]
    ) {
        var currentByBasis: [String: ChemicalLabelRate] = [:]
        for rate in current { currentByBasis[rateKey(rate)] = rate }
        var candidateByBasis: [String: ChemicalLabelRate] = [:]
        for rate in candidate { candidateByBasis[rateKey(rate)] = rate }

        // Same basis + label on both sides: compare the numbers.
        for rate in candidate {
            if let prior = currentByBasis[rateKey(rate)] {
                if prior.displayRate != rate.displayRate {
                    changes.append(
                        ChemicalIntelligenceChange(
                            field: .labelRate,
                            kind: .changed,
                            subject: subject,
                            currentValue: prior.displayRate,
                            candidateValue: rate.displayRate
                        )
                    )
                }
                continue
            }
            // A rate on a basis the record did not have at all.
            changes.append(
                ChemicalIntelligenceChange(
                    field: .labelRate,
                    kind: .added,
                    subject: subject,
                    currentValue: nil,
                    candidateValue: rate.displayRate
                )
            )
        }
        for rate in current where candidateByBasis[rateKey(rate)] == nil {
            changes.append(
                ChemicalIntelligenceChange(
                    field: .labelRate,
                    kind: .removed,
                    subject: subject,
                    currentValue: rate.displayRate,
                    candidateValue: nil
                )
            )
        }
    }

    // MARK: - Evidence and versions

    private static func diffEvidence(
        _ current: ChemicalIntelligence,
        _ candidate: ChemicalIntelligence,
        into changes: inout [ChemicalIntelligenceChange]
    ) {
        compare(.labelVersion,
                current.registration?.labelVersion, candidate.registration?.labelVersion,
                into: &changes)

        if current.activityGroupTableVersion != candidate.activityGroupTableVersion {
            changes.append(
                ChemicalIntelligenceChange(
                    field: .activityGroupTableVersion,
                    kind: .changed,
                    subject: nil,
                    currentValue: "v\(current.activityGroupTableVersion)",
                    candidateValue: "v\(candidate.activityGroupTableVersion)"
                )
            )
        }

        // Sources compared as a SET of source identities: consulting the same
        // register twice in a different order is not new information.
        let before = Set(current.verification.sources.map(\.id))
        let after = Set(candidate.verification.sources.map(\.id))
        for source in candidate.verification.sources where !before.contains(source.id) {
            changes.append(
                ChemicalIntelligenceChange(
                    field: .source,
                    kind: .added,
                    subject: nil,
                    currentValue: nil,
                    candidateValue: source.name.isEmpty ? source.kind.label : source.name
                )
            )
        }
        for source in current.verification.sources where !after.contains(source.id) {
            changes.append(
                ChemicalIntelligenceChange(
                    field: .source,
                    kind: .removed,
                    subject: nil,
                    currentValue: source.name.isEmpty ? source.kind.label : source.name,
                    candidateValue: nil
                )
            )
        }
    }

    // MARK: - Helpers

    /// Compares two optional strings, treating `nil` and `""` as the same
    /// absence, and whitespace/case-only differences as no change.
    private static func compare(
        _ field: ChemicalIntelligenceDiffField,
        _ current: String?,
        _ candidate: String?,
        into changes: inout [ChemicalIntelligenceChange]
    ) {
        let a = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let b = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if a.isEmpty && b.isEmpty { return }
        if a.caseInsensitiveCompare(b) == .orderedSame { return }
        // A lookup that simply did not return a field must not be read as the
        // regulator having REMOVED it. Silence is not evidence of absence.
        if b.isEmpty { return }
        changes.append(
            ChemicalIntelligenceChange(
                field: field,
                kind: a.isEmpty ? .added : .changed,
                subject: nil,
                currentValue: a.isEmpty ? nil : a,
                candidateValue: b
            )
        )
    }

    private static func kind(_ currentAbsent: Bool, _ candidateAbsent: Bool) -> ChemicalIntelligenceChangeKind {
        if currentAbsent { return .added }
        if candidateAbsent { return .removed }
        return .changed
    }

    private static func concentrationText(_ active: ChemicalActiveIngredient) -> String? {
        guard let value = active.concentration else { return nil }
        let unit = active.concentrationUnit?.label ?? ""
        return "\(ChemicalActiveIngredient.formatConcentration(value)) \(unit)"
            .trimmingCharacters(in: .whitespaces)
    }

    private static func key(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func useKey(_ use: ChemicalRegisteredUse) -> String {
        "\(key(use.crop))|\(key(use.targetRaw))"
    }

    private static func useLabel(_ use: ChemicalRegisteredUse) -> String {
        let crop = use.crop.isEmpty ? "Any crop" : use.crop
        return use.targetRaw.isEmpty ? crop : "\(crop) — \(use.targetRaw)"
    }

    /// Rates are identified by basis + label, so "Low disease pressure" and
    /// "High disease pressure" on the same basis stay distinct rates.
    private static func rateKey(_ rate: ChemicalLabelRate) -> String {
        "\(rate.basis.rawValue)|\(key(rate.label))|\(key(rate.unit))"
    }
}
