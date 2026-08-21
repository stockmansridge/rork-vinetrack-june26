import SwiftUI

/// Shared presentation for Chemical Intelligence.
///
/// Every screen that shows a chemical's trust state renders it through this
/// file. That is deliberate: verification is a claim about how much a grower
/// can rely on resistance data, and it must read identically in the Chemical
/// Store, the verify wizard and the spray picker. Two subtly different badges
/// would be two subtly different promises.
nonisolated enum ChemicalVerificationPresentation {

    static func icon(for status: ChemicalVerificationStatus) -> String {
        switch status {
        case .verified: return "checkmark.seal.fill"
        case .partiallyVerified: return "circle.lefthalf.filled"
        case .needsMatch: return "questionmark.circle.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        case .unverified: return "circle"
        }
    }

    static func tint(for status: ChemicalVerificationStatus) -> Color {
        switch status {
        case .verified: return VineyardTheme.success
        case .partiallyVerified: return VineyardTheme.info
        case .needsMatch: return VineyardTheme.warning
        case .conflict: return .red
        case .unverified: return .secondary
        }
    }
}

/// Compact trust chip used in lists and pickers.
struct ChemicalVerificationBadge: View {
    let status: ChemicalVerificationStatus
    var compact: Bool = false

    var body: some View {
        let tint = ChemicalVerificationPresentation.tint(for: status)
        HStack(spacing: 4) {
            Image(systemName: ChemicalVerificationPresentation.icon(for: status))
                .font(.caption2.weight(.semibold))
            if !compact {
                Text(status.label)
                    .font(.caption2.weight(.semibold))
            }
        }
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12))
        .foregroundStyle(tint)
        .clipShape(Capsule())
        .accessibilityLabel(Text(status.label))
    }
}

/// One active ingredient, rendered as its own row with its own group.
///
/// The active — not the product — is the thing that carries an activity group,
/// so a mixture shows two of these rather than one "3 + 11" line. The group
/// chip repeats per active on purpose: it is what makes "both groups apply"
/// visually obvious rather than something the reader has to infer.
struct ChemicalActiveIngredientRow: View {
    let active: ChemicalActiveIngredient
    var showSource: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(active.name.isEmpty ? "Unnamed active" : active.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active.name.isEmpty ? .secondary : .primary)

            if let concentration = active.concentration, let unit = active.concentrationUnit {
                Text("\(ChemicalActiveIngredient.formatConcentration(concentration)) \(unit.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Concentration not confirmed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                if let group = active.activityGroup, group.isResistanceRelevant {
                    Text(group.displayLabel)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(VineyardTheme.olive.opacity(0.12))
                        .foregroundStyle(VineyardTheme.olive)
                        .clipShape(Capsule())
                } else {
                    Text("Activity group unknown")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(VineyardTheme.warning.opacity(0.12))
                        .foregroundStyle(VineyardTheme.warning)
                        .clipShape(Capsule())
                }
            }

            if showSource, let source = active.groupSource {
                // Never let an AI reading masquerade as a regulator's word.
                Text(source.isAuthoritative
                     ? "Source: \(source.label)"
                     : "Source: \(source.label) — not independently verified")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// The derived `FRAC 3 + 11` display line.
///
/// Derived from structured actives every time it is drawn. Nothing here ever
/// reads the legacy `chemical_group` text, which is why a verified record can
/// never display a group the structured data does not actually contain.
struct ChemicalGroupSummaryLine: View {
    let groups: [ChemicalActivityGroup]

    var body: some View {
        if !groups.isEmpty {
            Text(groups.legacyGroupProjection)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(VineyardTheme.olive.opacity(0.12))
                .foregroundStyle(VineyardTheme.olive)
                .clipShape(Capsule())
        }
    }
}

/// Surfaces a source disagreement in full, without picking a winner.
struct ChemicalConflictCard: View {
    let conflicts: [ChemicalVerificationConflict]

    var body: some View {
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Verification conflict", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.red)

                Text("The extracted product information and the activity-group classification do not agree. This product cannot be verified until the disagreement is resolved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 3) {
                        if let name = conflict.activeIngredientName, !name.isEmpty {
                            Text(name)
                                .font(.caption.weight(.semibold))
                        }
                        HStack(alignment: .top, spacing: 6) {
                            Text("Extracted:")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(conflict.extractedValue)
                                .font(.caption2.weight(.medium))
                        }
                        HStack(alignment: .top, spacing: 6) {
                            Text("Reference classification:")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(conflict.authoritativeValue)
                                .font(.caption2.weight(.medium))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.07))
            .clipShape(.rect(cornerRadius: 10))
        }
    }
}

/// Expandable provenance. Enough transparency to justify the trust claim,
/// without turning the screen into a debugging dump.
struct ChemicalVerificationEvidenceView: View {
    let verification: ChemicalVerification
    let resolvedStatus: ChemicalVerificationStatus
    @State private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(resolvedStatus.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !verification.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sources")
                            .font(.caption.weight(.semibold))
                        ForEach(verification.sources) { source in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Image(systemName: source.kind.isAuthoritative
                                          ? "checkmark.shield.fill" : "sparkles")
                                        .font(.caption2)
                                        .foregroundStyle(source.kind.isAuthoritative
                                                         ? VineyardTheme.success : .secondary)
                                    Text(source.name.isEmpty ? source.kind.label : source.name)
                                        .font(.caption)
                                }
                                Text(source.kind.isAuthoritative
                                     ? source.kind.label
                                     : "\(source.kind.label) — not independently verified")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if let reference = source.reference, !reference.isEmpty {
                                    Text(reference)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }

                if !verification.unresolvedFields.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not confirmed")
                            .font(.caption.weight(.semibold))
                        ForEach(verification.unresolvedFields, id: \.self) { field in
                            Text("• \(field)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let verifiedAt = verification.verifiedAt {
                    Text("Last checked \(verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("Verification details")
                    .font(.subheadline)
                Spacer()
                ChemicalVerificationBadge(status: resolvedStatus)
            }
        }
    }
}

/// Registered/label rates.
///
/// Titled "Product label rate" and never merged with carrier settings: the
/// label rate is a legal instruction attached to the product, while carrier
/// volume is how this vineyard chooses to apply water. An NZ block spraying on
/// L/100 m still applies a 1.5 L/ha label product.
struct ChemicalLabelRatesView: View {
    let uses: [ChemicalRegisteredUse]

    private var rates: [ChemicalLabelRate] {
        uses.flatMap(\.rates)
    }

    var body: some View {
        if !rates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Product label rate")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    // Shown only when every rate-owning use proves the same
                    // authoritative tier — read from stored provenance,
                    // never inferred from the values themselves.
                    if let badge = uses.uniformRatesBadge {
                        ChemicalProvenanceTagView(badge: badge)
                    }
                }
                ForEach(rates) { rate in
                    HStack(spacing: 8) {
                        Text(rate.displayRate)
                            .font(.subheadline.weight(.semibold))
                        Text(rate.basis.label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text("Label rates are set by the product registration. They are separate from this vineyard's carrier volume method.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Display rule for a registered use's withholding period line.
///
/// The resolver only ever parses a label's "NOT REQUIRED WHEN USED AS
/// DIRECTED" statement to 0 days — it never derives 0 from anything else
/// (`chemical-info-lookup` contract). So a zero is shown with that label
/// wording ONLY when the evidence says the label was actually consulted:
/// either the use's own verbatim statements carry the phrase, or the payload
/// cites the manufacturer's approved label as a source. An operator-typed or
/// AI-only zero has no such wording behind it and stays a plain "0 days"; a
/// missing value stays missing. Nothing here fabricates or upgrades evidence
/// — it only chooses wording for evidence already present.
nonisolated enum ChemicalWithholdingDisplay {
    /// The exact label phrase that authorises the friendly wording.
    nonisolated static let notRequiredPhrase = "not required when used as directed"

    /// Human wording for a use's withholding period, or `nil` when none is
    /// stated (an unresolved withholding period is never invented).
    nonisolated static func text(
        days: Int?,
        restrictions: String?,
        hasManufacturerLabelSource: Bool
    ) -> String? {
        guard let days else { return nil }
        if days == 0 {
            let wordingPresent = restrictions?.lowercased().contains(notRequiredPhrase) ?? false
            if wordingPresent || hasManufacturerLabelSource {
                return "Not required when used as directed"
            }
        }
        return "\(days) days"
    }
}

/// Registered uses, with an explicit statement when grape use is unconfirmed.
struct ChemicalRegisteredUsesView: View {
    let uses: [ChemicalRegisteredUse]
    /// Whether the payload cites the manufacturer's approved label as a data
    /// source. Drives only the withholding "not required" wording — see
    /// `ChemicalWithholdingDisplay`. Defaults to false so a call site that
    /// cannot prove label evidence fails closed to plain day counts.
    var hasManufacturerLabelSource: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if uses.isEmpty {
                Label("Grape registration not verified", systemImage: "exclamationmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(VineyardTheme.warning)
                Text("No registered uses were confirmed for this product. Check the label before applying.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(uses) { use in
                    // Tags come from STORED per-use provenance only: one badge
                    // for the card when every fact shares a tier, per-fact
                    // badges only when trust is mixed, nothing for legacy or
                    // unproven records. See ChemicalUseProvenancePlan.
                    let plan = use.provenancePlan
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(use.crop.isEmpty ? "Crop not stated" : use.crop)
                                .font(.subheadline.weight(.semibold))
                            if let badge = plan.headerBadge {
                                ChemicalProvenanceTagView(badge: badge)
                            }
                        }
                        Text("• \(use.targetRaw.isEmpty ? "Target not stated" : use.targetRaw)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let whp = ChemicalWithholdingDisplay.text(
                            days: use.withholdingPeriodDays,
                            restrictions: use.restrictions,
                            hasManufacturerLabelSource: hasManufacturerLabelSource
                        ) {
                            HStack(spacing: 6) {
                                Text("Withholding period: \(whp)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if let badge = plan.badge(for: .withholdingPeriod) {
                                    ChemicalProvenanceTagView(badge: badge)
                                }
                            }
                        }
                        if let reEntry = use.reEntryPeriodHours {
                            HStack(spacing: 6) {
                                Text("Re-entry: \(reEntry) hours")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if let badge = plan.badge(for: .reEntry) {
                                    ChemicalProvenanceTagView(badge: badge)
                                }
                            }
                        }
                        if let restrictions = use.restrictions, !restrictions.isEmpty {
                            ChemicalUseRestrictionsView(
                                text: restrictions,
                                badge: plan.badge(for: .restrictions)
                            )
                        }
                    }
                }
                if !uses.contains(where: \.isViticultural) {
                    Label("Grape registration not verified", systemImage: "exclamationmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(VineyardTheme.warning)
                }
            }
        }
    }
}

/// Tiny capsule naming the evidence tier behind a displayed fact.
///
/// Rendered exclusively from STORED provenance (`ChemicalProvenanceBadge`):
/// it never derives a tier from the value it sits beside, and it simply does
/// not exist for records without recorded provenance.
struct ChemicalProvenanceTagView: View {
    let badge: ChemicalProvenanceBadge

    var body: some View {
        Label(badge.text, systemImage: badge.symbolName)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .accessibilityLabel("Source: \(badge.text)")
    }
}

/// A registered use's verbatim label restriction statements.
///
/// The wording is legal text: it renders exactly as the label states it,
/// never paraphrased or summarised. Long statements collapse to a few lines
/// with an explicit expand control, so the full wording stays one tap away
/// without dominating the product summary.
struct ChemicalUseRestrictionsView: View {
    let text: String
    /// Optional provenance tag for the restrictions statement, shown only in
    /// mixed-trust cards. Defaults to none so existing call sites render
    /// exactly as before.
    var badge: ChemicalProvenanceBadge? = nil

    @State private var isExpanded = false

    private static let collapsedLineLimit = 3

    /// Whether the statement plausibly exceeds the collapsed window and
    /// deserves an expand control. A cheap display heuristic — it never
    /// alters the text itself.
    private var isLong: Bool {
        text.count > 160
            || text.components(separatedBy: .newlines).count > Self.collapsedLineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Label restrictions")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let badge {
                    ChemicalProvenanceTagView(badge: badge)
                }
            }
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
            if isLong {
                Button(isExpanded ? "Show less" : "Show full restrictions") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .font(.caption2.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(.top, 2)
    }
}

/// Full-width jurisdiction warning: this product is registered under another
/// country's law than the vineyard it is being viewed in.
///
/// Identity and chemistry stand — the record is never re-keyed — but its
/// registered uses, label rates, withholding and re-entry periods are not
/// vineyard-authoritative. Mirrors `ChemicalJurisdictionMismatchBanner` on
/// Android.
struct ChemicalJurisdictionMismatchBanner: View {
    let registrationCountry: String
    let vineyardCountry: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                ChemicalJurisdiction.mismatchHeadline(
                    registrationCountry: registrationCountry,
                    vineyardCountry: vineyardCountry
                ),
                systemImage: "globe"
            )
            .font(.caption.weight(.bold))
            .foregroundStyle(VineyardTheme.warning)

            Text(ChemicalJurisdiction.mismatchGuidance(
                registrationCountry: registrationCountry,
                vineyardCountry: vineyardCountry
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.warning.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
    }
}

/// Compact foreign-label mark shown next to the trust badge in lists and
/// pickers — e.g. "AU label — not NZ".
///
/// Deliberately NOT a block: the product stays selectable (there may be a
/// legitimate local reason to use it), but its label information can never
/// silently read as valid for this vineyard's jurisdiction.
struct ChemicalJurisdictionChip: View {
    let registrationCountry: String
    let vineyardCountry: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.caption2.weight(.semibold))
            Text("\(registrationCountry) label — not \(vineyardCountry)")
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(VineyardTheme.warning.opacity(0.12))
        .foregroundStyle(VineyardTheme.warning)
        .clipShape(Capsule())
        .accessibilityLabel(Text(ChemicalJurisdiction.mismatchHeadline(
            registrationCountry: registrationCountry,
            vineyardCountry: vineyardCountry
        )))
    }
}

/// Product identity block used by both Match and Verify.
struct ChemicalIdentityView: View {
    let productName: String
    let registration: ChemicalRegistration?
    let productCategory: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(productName.isEmpty ? "Unnamed product" : productName)
                .font(.headline)

            if let registration {
                if let registrant = registration.registrant, !registrant.isEmpty {
                    labelled("Registrant", registrant)
                }
                if !registration.countryCode.isEmpty {
                    labelled("Country", registration.countryCode)
                }
                if let identifier = registration.displayIdentifier {
                    labelled("Registration", identifier)
                } else {
                    Text("No registration identifier found")
                        .font(.caption)
                        .foregroundStyle(VineyardTheme.warning)
                }
            } else {
                Text("No registered identity found for this product")
                    .font(.caption)
                    .foregroundStyle(VineyardTheme.warning)
            }

            if !productCategory.isEmpty {
                labelled("Type", productCategory.capitalized)
            }
        }
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.caption.weight(.medium))
        }
    }
}
