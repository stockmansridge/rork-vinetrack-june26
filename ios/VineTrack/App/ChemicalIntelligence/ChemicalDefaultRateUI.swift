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
    /// This vineyard's exact dose per basis, in the rate's own unit, where one
    /// has been named inside a label band.
    var values: [ChemicalDefaultRateBasis: Double] = [:]
    let onSelect: (ChemicalDefaultRateBasis, ChemicalDefaultRateOption) -> Void
    /// Records an exact dose. Returns false when the label does not authorise
    /// it, which is what drives the out-of-range message.
    var onSetValue: ((ChemicalDefaultRateBasis, Double) -> Bool)?
    var onClearValue: ((ChemicalDefaultRateBasis) -> Void)?

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
                    // The exact-dose field belongs to the option in force and
                    // only when the label states a band — a single registered
                    // number is not a choice, and offering a box beside it
                    // would invite an off-label figure.
                    if option.isLabelRange,
                       isInForce(option, in: group),
                       onSetValue != nil {
                        ChemicalExactDoseField(
                            option: option,
                            value: values[group.basis],
                            onCommit: { onSetValue?(group.basis, $0) ?? false },
                            onClear: { onClearValue?(group.basis) }
                        )
                        .padding(.leading, 28)
                    }
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

    /// The option a basis is currently dosing by: the explicit choice, or the
    /// recommendation while none has been made.
    private func isInForce(
        _ option: ChemicalDefaultRateOption,
        in group: ChemicalDefaultRateGroup
    ) -> Bool {
        if let selected = selectedIds[group.basis] { return selected == option.id }
        return group.recommendedOptionId == option.id
    }

    @ViewBuilder
    private func optionRow(
        _ option: ChemicalDefaultRateOption,
        in group: ChemicalDefaultRateGroup
    ) -> some View {
        let isRecommended = group.recommendedOptionId == option.id
        let isInForce = isInForce(option, in: group)
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

/// The vineyard's own dose, taken from INSIDE a registered band.
///
/// # Why a band still needs a number
///
/// `100–200 g/100 L` is what the label authorises. It is not what anybody
/// pours. Until this existed the projection silently used the bottom of the
/// band, so a vineyard dosing 150 either lived with a spray calculation built
/// on 100, or "fixed" it by editing the registered rate — destroying the label
/// evidence for everyone who read the record afterwards.
///
/// So the decision is recorded here, beside the band and separate from it. The
/// registered rate is never edited: it still reads `100–200 g/100 L` on the
/// record, in the re-verification comparison and in every export.
struct ChemicalExactDoseField: View {
    let option: ChemicalDefaultRateOption
    /// The dose already recorded, in the rate's own unit.
    let value: Double?
    /// Returns false when the label does not authorise the value.
    let onCommit: (Double) -> Bool
    let onClear: () -> Void

    @State private var text: String = ""
    @State private var isRejected: Bool = false
    @FocusState private var isFocused: Bool

    private var bounds: (min: Double, max: Double)? { option.authorisedBounds }

    private var unit: String { option.rate.unit }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("This vineyard uses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .frame(maxWidth: 90)
                    .font(.subheadline.weight(.semibold))
                    .onSubmit(commit)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isFocused {
                    Button("Set", action: commit)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }

            if isRejected, let bounds {
                // The refusal names the band, because "invalid" tells an
                // operator nothing about what they may actually apply.
                Label(
                    "The label registers \(numberText(bounds.min))\u{2013}\(numberText(bounds.max)) \(unit). Enter a rate within it.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else if value != nil {
                HStack(spacing: 8) {
                    Text("The registered rate stays \(option.displayRate).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button("Reset", action: reset)
                        .font(.caption2)
                        .buttonStyle(.borderless)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if let bounds {
                Text("Any rate from \(numberText(bounds.min)) to \(numberText(bounds.max)) \(unit) is registered. Leave it blank to use \(numberText(bounds.min)).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .onAppear { syncFromValue() }
        .onChange(of: value) { _, _ in syncFromValue() }
    }

    private var placeholder: String {
        bounds.map { numberText($0.min) } ?? ""
    }

    private func syncFromValue() {
        guard !isFocused else { return }
        text = value.map(numberText) ?? ""
        isRejected = false
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            reset()
            return
        }
        // Comma decimal separators are what a phone keyboard offers in much of
        // the world, and rejecting them would read as an out-of-range error.
        guard let parsed = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else {
            isRejected = true
            return
        }
        if onCommit(parsed) {
            isRejected = false
            isFocused = false
        } else {
            isRejected = true
        }
    }

    private func reset() {
        onClear()
        text = ""
        isRejected = false
        isFocused = false
    }

    private func numberText(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%g", value)
    }
}
