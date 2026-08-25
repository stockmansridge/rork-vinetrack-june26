import SwiftUI

/// Save-contract feedback, shown WHERE the problem is (task §11).
///
/// # Why not one banner at the bottom
///
/// A disabled Save button with a generic "please complete required fields"
/// message tells the operator that something is wrong and nothing about what.
/// On a form this long — product, actives, several registered uses, labels,
/// pricing — that is a hunt. The contract already knows which section each
/// violation belongs to, so the message belongs against that section.
nonisolated struct ChemicalSaveIssue: Identifiable, Sendable, Hashable {
    let violation: ChemicalSaveViolation
    /// True when the record arrived with this fault, so it is guidance rather
    /// than a block — see `ChemicalReviewSession.baselineViolationCodes`.
    let isCarriedOver: Bool

    nonisolated var id: String { violation.id }
}

/// One or more contract issues for a single section of the form.
struct ChemicalSaveIssueNotice: View {
    let issues: [ChemicalSaveIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(issues) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: issue.isCarriedOver
                            ? "info.circle"
                            : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(issue.isCarriedOver ? Color.secondary : Color.orange)
                        Text(issue.violation.message)
                            .font(.caption)
                            .foregroundStyle(issue.isCarriedOver ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if issues.contains(where: \.isCarriedOver),
                   !issues.contains(where: { !$0.isCarriedOver }) {
                    // A legacy record is being repaired, not blocked. Saying so
                    // stops the notice reading as a refusal.
                    Text("This was already missing before you opened the product — you can still save, and fill it in when you have the label.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// The resistance classification state, as a scannable badge.
///
/// This exists because "no group shown" used to mean three different things.
/// The Resistance Planner consumes the structured state; the operator needs to
/// see the same three answers rather than inferring them from a blank.
struct ChemicalResistanceStateBadge: View {
    let state: ChemicalResistanceState

    var body: some View {
        Label(state.label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
            .accessibilityLabel("Resistance classification: \(state.label)")
    }

    private var symbol: String {
        switch state {
        case .classified: return "checkmark.seal.fill"
        case .notApplicable: return "minus.circle"
        case .unresolved: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .classified: return .green
        // Deliberately NOT red. An adjuvant with no resistance group is a
        // correct, complete record; colouring it as a fault would train the
        // operator to "fix" something that is already right.
        case .notApplicable: return .secondary
        case .unresolved: return .orange
        }
    }
}

/// The notice shown against a rate whose governing condition is unproven.
///
/// The numbers are authoritative — the label really does state them. What is
/// missing is which one applies when, and only the operator can supply that.
/// Until they do, the rate must not feed a spray calculation automatically.
struct ChemicalRateAmbiguityNotice: View {
    /// How many rates on this use still need a condition.
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(count == 1
                ? "The label states this rate alongside others and does not say which condition applies. Name the condition to use it in a spray calculation."
                : "The label states \(count) rates on the same basis without saying which condition applies to each. Name each condition to use them in a spray calculation.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

extension ChemicalReviewSession {
    /// Contract issues belonging to one section of the form.
    ///
    /// Blocking issues and carried-over issues are returned together so a
    /// section shows the whole picture; the badge distinguishes them.
    func saveIssues(forField field: String) -> [ChemicalSaveIssue] {
        let blocking = Set(blockingViolations.map(\.id))
        return saveEvaluation.violations
            .filter { $0.field == field }
            .map { ChemicalSaveIssue(violation: $0, isCarriedOver: !blocking.contains($0.id)) }
    }

    /// Rates the operator still has to attribute to a condition.
    var ratesNeedingConditionChoice: Int {
        let useRates = chemistryDraft.uses.filter(\.isViticultural).flatMap(\.rates)
        return (useRates + chemistryDraft.productRates).count { $0.needsConditionChoice }
    }
}
