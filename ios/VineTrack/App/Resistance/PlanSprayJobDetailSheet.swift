import SwiftUI

/// Detail sheet for a spray job created from a resistance plan position.
///
/// Shows WHERE the job came from ("From Resistance Plan"), the ORIGINAL
/// planned intent (frozen snapshot — never re-derived from the current plan),
/// the job's CURRENT proposal with an explicit plan-deviation flag, and the
/// LIVE Resistance Check. Deviation and compliance are deliberately separate:
/// a job may differ from the plan yet still be resistance-compliant, and the
/// live check is always recomputed against current history — plan compliance
/// at creation time guarantees nothing later.
struct PlanSprayJobDetailSheet: View {
    let job: BackendPlanSprayJob
    let planLabel: String
    let positionOrdinal: Int?
    let liveEvaluation: ResistancePlanPositionEvaluation?
    let blockName: (String) -> String
    let canRecordSpray: Bool
    let isPendingSync: Bool
    let onRecordSpray: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fromPlanCard
                    originalIntentCard
                    proposalCard
                    liveCheckCard
                    if canRecordSpray {
                        recordSection
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(job.name.isEmpty ? "Spray Job" : job.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - From Resistance Plan

    private var fromPlanCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("From Resistance Plan", systemImage: "map")
                .font(.subheadline.weight(.semibold))
            Text(planLabel)
                .font(.footnote)
            if let positionOrdinal {
                Text("Position: Spray \(positionOrdinal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This position is no longer in the current plan. The job keeps its original intent below.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let revision = job.resistancePlanSourceRevision {
                Text("Created against plan revision \(revision)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Text((job.status ?? "planned").capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: .capsule)
                if isPendingSync {
                    Label("Waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Original intent (frozen)

    private var originalIntentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Original planned intent", systemImage: "lock.doc")
                .font(.subheadline.weight(.semibold))
            if let snapshot = job.resistancePositionSnapshot {
                Text(job.originalIntentLabel ?? snapshot.groupsLabel)
                    .font(.footnote.weight(.semibold))
                ForEach(snapshot.products) { product in
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(.secondary)
                        Text("\(product.displayLabel) — \(product.groups.displayLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let note = snapshot.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No frozen intent — this job was not created from a plan position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Frozen when the job was created. Editing the plan later never rewrites this.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Current proposal + deviation

    private var proposalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Current proposal", systemImage: "flask")
                .font(.subheadline.weight(.semibold))
            Text(job.currentProposalLabel)
                .font(.footnote)
            if job.deviatesFromPlan {
                Label(
                    "Differs from the original plan — a plan deviation, not a compliance verdict.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if job.resistancePositionSnapshot != nil {
                Label("Matches the original planned intent.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("The job stays fully editable. Changing it is allowed — the deviation is simply shown, and resistance compliance is always the engine's call.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Live Resistance Check

    private var liveCheckCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live Resistance Check", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
            if let liveEvaluation {
                HStack {
                    Text("Current standing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(liveEvaluation.status.label)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor(liveEvaluation.status).opacity(0.16), in: .capsule)
                        .foregroundStyle(statusColor(liveEvaluation.status))
                }
                ForEach(liveEvaluation.blocks, id: \.blockId) { outcome in
                    HStack {
                        Text(blockName(outcome.blockId))
                            .font(.caption)
                        Spacer()
                        Text(outcome.status.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor(outcome.status))
                    }
                }
                if job.deviatesFromPlan {
                    Label(
                        "This check evaluates the position's planned chemistry. The job proposes different products — review before spraying.",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } else {
                Text("The position is no longer in the plan, so there is no live evaluation for it. Record the spray through the calculator as usual — recorded history always feeds the engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Evaluated now, against current spray history. Plan compliance when this job was created guarantees nothing later.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Record

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onRecordSpray()
            } label: {
                Label("Record this spray", systemImage: "play.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            Text("Opens the Spray Calculator prefilled from this job. The saved record will reference this job, completing the Plan → Job → Record chain.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func statusColor(_ status: ResistancePlanPositionStatus) -> Color {
        switch status {
        case .goodFit: return VineyardTheme.leafGreen
        case .reachesStrategyLimit: return .orange
        case .wouldExceedStrategy: return .red
        case .needsReview: return .orange
        case .unableToFullyAssess: return .purple
        }
    }
}
