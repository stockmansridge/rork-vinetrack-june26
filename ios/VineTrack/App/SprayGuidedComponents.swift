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

/// The reserved slot for the future Resistance Check.
///
/// Deliberately renders NOTHING when disabled: showing a fake "no resistance
/// issues" result would be worse than showing nothing, because an operator would
/// trust it. The rules engine is a separate task; this only fixes the location.
struct ResistanceCheckSlot: View {
    let isApplicable: Bool

    var body: some View {
        EmptyView()
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
