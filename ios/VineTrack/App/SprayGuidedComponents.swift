import SwiftUI

/// A progressively-disclosed section of the guided Spray Calculator.
///
/// Three visual states, driven entirely by `SprayGuidedFlow` so the UI cannot
/// drift from the validation rules:
///
///  - **Locked** — an earlier decision is still outstanding. Dimmed, not tappable.
///  - **Active** — the current decision. Expanded, accented.
///  - **Done** — complete and behind the active step. Collapsed to a one-line
///    summary with an Edit action, so progress is visible without scrolling
///    through the whole form.
///
/// This is a single scrolling screen rather than a rigid page-by-page wizard:
/// field operators need to jump back to a section in one tap.
struct GuidedStepCard<Content: View>: View {
    let step: SprayGuidedStep
    let index: Int
    let isLocked: Bool
    let isDone: Bool
    let isExpanded: Bool
    /// One-line recap shown when collapsed.
    let summary: String
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Content

    private var accent: Color {
        if isLocked { return .secondary }
        return isDone ? VineyardTheme.olive : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    badge
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isLocked ? .secondary : .primary)
                        if !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 8)
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if isDone && !isExpanded {
                        Text("Edit")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
            .buttonStyle(.plain)
            .disabled(isLocked)

            if isExpanded && !isLocked {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    content()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isExpanded && !isLocked ? accent.opacity(0.45) : .clear, lineWidth: 1.5)
        )
        .opacity(isLocked ? 0.55 : 1)
        .animation(.spring(duration: 0.3), value: isExpanded)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(isDone ? VineyardTheme.olive : (isLocked ? Color.secondary.opacity(0.2) : Color.accentColor.opacity(0.15)))
                .frame(width: 28, height: 28)
            if isDone {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(index)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isLocked ? Color.secondary : Color.accentColor)
            }
        }
    }
}

/// An actionable blocker banner. Never a dead end: when block setup is at fault
/// it offers the route to fix it.
struct GuidedBlockerBanner: View {
    let blocker: SprayGuidedBlocker
    var onFix: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(blocker.title, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            Text(blocker.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if blocker.needsBlockEditor, let onFix {
                Button("Edit block details", action: onFix)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(.rect(cornerRadius: 10))
    }
}

/// A selectable chip. Used for targets (multi-select) and spray head target.
struct GuidedChip: View {
    let label: String
    let icon: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.caption)
                }
                Text(label)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(isSelected ? VineyardTheme.olive : Color(.tertiarySystemGroupedBackground))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

/// A calculated figure that came out of the plan. Never editable — this is the
/// visual contract that the operator does not type derived values.
struct GuidedCalculatedRow: View {
    let label: String
    let value: String
    var emphasis: Bool = false
    var caption: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(emphasis ? .headline.weight(.bold) : .subheadline.weight(.semibold))
                .foregroundStyle(emphasis ? VineyardTheme.olive : .primary)
                .monospacedDigit()
        }
    }
}

/// A read-only panel of engine-calculated figures.
struct GuidedCalculatedPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.olive.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
    }
}

/// The Live Resistance Check for ONE product line.
///
/// Every word it shows is engine output. It receives findings already produced by
/// `SprayResistanceCheck` — which routes the spray through the same Planner and
/// Engine the standalone Resistance Planner uses — and formats them. It counts
/// nothing, compares nothing, and decides no severity of its own.
///
/// Renders NOTHING when there is no finding. A "no resistance issues" badge would
/// be trusted, and this panel is not in a position to make that claim: silence here
/// means only that no published rule fired for the groups THIS product carries.
/// Where the engine genuinely cannot reach a conclusion it says so, as a finding.
struct ResistanceCheckSlot: View {
    let isApplicable: Bool
    let findings: [ResistanceRuleResult]

    init(isApplicable: Bool, findings: [ResistanceRuleResult] = []) {
        self.isApplicable = isApplicable
        self.findings = findings
    }

    var body: some View {
        if isApplicable, !findings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(findings) { finding in
                    ResistanceFindingRow(finding: finding)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// One engine finding, shown verbatim enough to be argued with.
///
/// The published clause is always named. A resistance warning an operator cannot
/// trace back to a strategy is one they can only obey or ignore — never check.
struct ResistanceFindingRow: View {
    let finding: ResistanceRuleResult

    private var tint: Color {
        switch finding.severity {
        case .critical: return .red
        case .warning: return .orange
        case .indeterminate: return .yellow
        case .advisory, .informational: return .secondary
        }
    }

    private var icon: String {
        switch finding.severity {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .indeterminate: return "questionmark.circle.fill"
        case .advisory, .informational: return "info.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.explanation)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.sourceReference)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(tint.opacity(0.10))
        .clipShape(.rect(cornerRadius: 8))
    }
}

/// The per-product area-basis picker.
///
/// Deliberately a full-width, always-visible control on the product line rather
/// than something behind an "advanced" disclosure: on a banded pass the
/// difference between whole-block and treated-band hectares is a 4× difference
/// in product, so it is not a detail the operator should have to go looking for.
struct GuidedProductBasisPicker: View {
    let selected: SprayProductRateBasis
    let onSelect: (SprayProductRateBasis) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apply this product rate to:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(SprayProductRateBasis.areaChoices, id: \.self) { basis in
                    GuidedChip(
                        label: SprayGuidedFormat.productBasisLabel(basis),
                        icon: nil,
                        isSelected: selected == basis
                    ) {
                        onSelect(basis)
                    }
                }
            }
        }
    }
}

/// The calculated explanation for one product line.
///
/// Shows the arithmetic in the operator's own terms — rate × measured amount —
/// then the requirement. When the line cannot resolve it names the ONE missing
/// input instead of showing a zero.
struct GuidedProductCalculationRow: View {
    let line: SprayProductLineResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let calculation = SprayGuidedFormat.productCalculation(line) {
                Text(calculation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(SprayGuidedFormat.productRequirement(line))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(VineyardTheme.olive)
                    .monospacedDigit()
            } else if let reason = line.unresolvedReason {
                Text(reason.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(reason.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            (line.isUnresolved ? Color.orange : VineyardTheme.olive).opacity(0.08)
        )
        .clipShape(.rect(cornerRadius: 8))
    }
}

/// One line of the Review step.
struct GuidedReviewRow: View {
    let label: String
    let value: String
    var isMuted: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
            Text(value)
                .font(.footnote.weight(.medium))
                .foregroundStyle(isMuted ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled group of Review rows with a jump-back Edit action.
struct GuidedReviewGroup<Content: View>: View {
    let title: String
    var onEdit: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                if let onEdit {
                    Button("Edit", action: onEdit)
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

/// Formatting helpers so both the live sections and Review render engine values
/// identically. Pure presentation — no arithmetic beyond rounding.
enum SprayGuidedFormat {
    static func hectares(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f ha", value)
    }

    static func metres(_ value: Double?, decimals: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(number(value, decimals: decimals)) m"
    }

    static func litres(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(number(value, decimals: 0)) L"
    }

    static func litresPerHectare(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(number(value, decimals: 0)) L/ha"
    }

    static func litresPer100m(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(number(value, decimals: value < 10 ? 1 : 0)) L/100 m"
    }

    static func factor(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f×", value)
    }

    /// Group-separated number, so 6250 reads as "6,250".
    static func number(_ value: Double, decimals: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = decimals
        formatter.minimumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// A product quantity in the line's own unit, or an explicit unavailable
    /// marker — never a fabricated zero.
    static func quantity(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        let decimals: Int = value < 10 ? 2 : (value < 100 ? 1 : 0)
        return "\(number(value, decimals: decimals)) \(unit)"
    }

    static func carrierBasisLabel(_ basis: SprayCarrierBasis) -> String {
        switch basis {
        case .litresPerHectare: return "L/ha"
        case .litresPer100Metres: return "L/100 m"
        }
    }

    /// The rate as written on the label, e.g. `2 L/ha` or `100 mL/100 L`.
    static func productRate(_ line: SprayProductLineResult) -> String {
        let decimals: Int = line.rate < 10 ? 1 : 0
        return "\(number(line.rate, decimals: decimals)) \(line.unit)\(line.basis.rateSuffix)"
    }

    /// The MEASURED half of the calculation, e.g. `10.00 ha whole block`.
    ///
    /// Reads `basisInput` straight off the planner's line — the screen never
    /// substitutes its own hectares or litres here, so the explanation and the
    /// quantity can never describe different arithmetic.
    static func productMeasuredInput(_ line: SprayProductLineResult) -> String? {
        guard let input = line.basisInput, input.isFinite else { return nil }
        let decimals = line.basis.measuredUnit == "ha" ? 2 : 0
        return "\(number(input, decimals: decimals)) \(line.basis.measuredUnit) \(line.basis.measuredNoun)"
    }

    /// The full one-line explanation, e.g. `2 L/ha × 10.00 ha whole block`.
    ///
    /// Suppressed entirely when the line has no rate. A product whose label
    /// band the operator has not yet resolved was rendering as
    /// `0.0 Kg/100 L × 351 L carrier`, which states two things that are not
    /// true: that a rate of zero has been chosen, and that an arithmetic is
    /// under way. There is no calculation to explain until there is a rate.
    static func productCalculation(_ line: SprayProductLineResult) -> String? {
        guard line.rate.isFinite, line.rate > 0 else { return nil }
        guard let measured = productMeasuredInput(line) else { return nil }
        return "\(productRate(line)) × \(measured)"
    }

    /// The resulting requirement, e.g. `20.0 L required`.
    ///
    /// Never a bare "Unavailable". The engine already knows WHICH single input
    /// is missing — `SprayProductUnresolvedReason` has distinguished a missing
    /// product rate from a missing carrier volume from missing band geometry
    /// since it was written — and nothing was rendering it. An operator told
    /// only "Unavailable" has to guess between the rate they have not picked
    /// and the canopy they have not set.
    static func productRequirement(_ line: SprayProductLineResult) -> String {
        guard let total = line.totalQuantity else {
            return line.unresolvedReason?.title ?? "Unavailable"
        }
        return "\(quantity(total, unit: line.unit)) required"
    }

    /// The action that would make an unresolved line calculable, in the
    /// operator's own terms. `nil` once the line resolves.
    static func productBlockerPrompt(_ line: SprayProductLineResult) -> String? {
        line.unresolvedReason?.message
    }

    /// User-facing wording for a product's label rate basis.
    static func productBasisLabel(_ basis: SprayProductRateBasis) -> String {
        switch basis {
        case .wholeBlockArea: return "Whole Block Area"
        case .treatedArea: return "Treated Band Area"
        case .per100Litres: return "Per 100 L Carrier"
        case .per100Metres: return "Per 100 m Row"
        }
    }

    static func geometrySourceLabel(_ source: SprayGeometrySource) -> String {
        switch source {
        case .operatorOverride: return "Manual row-length override"
        case .mappedRows, .storedRowLength: return "Mapped rows"
        case .derivedFromAreaAndSpacing: return "Derived from area & row spacing"
        case .unavailable: return "Unavailable"
        }
    }
}
