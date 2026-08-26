import SwiftUI

/// The Default rates decision, per basis (task §5, §6, §7).
///
/// # Why this is a decision and not a display
///
/// The registered rates above it are the label's. This is the one place the
/// operator says which of them THIS vineyard doses by — and the whole reason it
/// exists is that a label can state several, each under a condition, and
/// silently adopting the first is how a Tasmanian rate ends up on a NSW block.
///
/// Three answers, and they are genuinely different:
///
/// ```text
/// nothing registered   state so, plainly. Never convert from the other basis.
/// exactly one          mark it Recommended and move on.
/// several              refuse to choose. Ask.
/// ```
struct ChemicalDefaultRatesView: View {
    let plan: ChemicalDefaultRatePlan
    /// The option in force per basis — the operator's choice, or the
    /// recommendation when they have not made one.
    let selectedIds: [ChemicalDefaultRateBasis: String]
    let onSelect: (ChemicalDefaultRateBasis, ChemicalDefaultRateOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ChemicalDefaultRateBasis.allCases, id: \.self) { basis in
                basisBlock(plan.group(basis))
            }
        }
    }

    @ViewBuilder
    private func basisBlock(_ group: ChemicalDefaultRateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.basis.label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            if group.isEmpty {
                // Case A. The label states nothing on this basis, and VineTrack
                // says exactly that rather than deriving a number from the
                // other basis — which would need a carrier volume the label
                // never mentioned.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "minus.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(group.emptyStatement)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if group.requiresChoice, selectedIds[group.basis] == nil {
                    // Case C. Several apply and nothing may be assumed.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "hand.raised")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(choicePrompt(for: group))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ForEach(group.options) { option in
                    optionRow(option, in: group)
                }
            }
        }
    }

    /// The wording that asks the operator to decide.
    ///
    /// Names the jurisdiction when one is known, because "several rates apply
    /// in NSW" is a materially different statement from "this label states
    /// several rates" — the first has already excluded the ones registered
    /// elsewhere.
    private func choicePrompt(for group: ChemicalDefaultRateGroup) -> String {
        if let jurisdiction = plan.jurisdiction {
            return "The label registers more than one \(group.basis.label.lowercased()) "
                + "rate for \(jurisdiction.displayName). Choose the one this vineyard uses."
        }
        return "The label registers more than one \(group.basis.label.lowercased()) rate. "
            + "Choose the one this vineyard uses."
    }

    @ViewBuilder
    private func optionRow(
        _ option: ChemicalDefaultRateOption,
        in group: ChemicalDefaultRateGroup
    ) -> some View {
        let isSelected = selectedIds[group.basis] == option.id
        let isRecommended = group.recommendedOptionId == option.id
        let isInForce = isSelected || (selectedIds[group.basis] == nil && isRecommended)
        let isOutsideJurisdiction = plan.jurisdiction != nil
            && !option.applies(in: plan.jurisdiction)

        Button {
            onSelect(group.basis, option)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isInForce ? "largecircle.fill.circle" : "circle")
                    .font(.body)
                    .foregroundStyle(isInForce ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        // ONE rate, printed as the label prints it. A true
                        // label range keeps BOTH bounds and stays one choice.
                        Text(option.displayRate)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if isRecommended, let badge = group.recommendation.badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        if option.isLabelRange {
                            Text("label range")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Every condition that states this rate, one per line.
                    // Never merged into a single string: "2 L/100 L 3 L/100 L"
                    // is not a rate, and a condition detached from its number
                    // is not a condition.
                    ForEach(option.conditions) { condition in
                        Text(condition.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if isOutsideJurisdiction, let jurisdiction = plan.jurisdiction {
                        Label(
                            "Not registered for \(jurisdiction.displayName)",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isInForce ? [.isSelected] : [])
        .accessibilityLabel(accessibilityLabel(option, in: group, isInForce: isInForce))
    }

    private func accessibilityLabel(
        _ option: ChemicalDefaultRateOption,
        in group: ChemicalDefaultRateGroup,
        isInForce: Bool
    ) -> String {
        var parts = [option.displayRate]
        if group.recommendedOptionId == option.id, let badge = group.recommendation.badge {
            parts.append(badge)
        }
        parts.append(contentsOf: option.conditions.map(\.summary))
        if isInForce { parts.append("Selected default") }
        return parts.joined(separator: ", ")
    }
}
