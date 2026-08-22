import SwiftUI

/// One row in the Program tab.
///
/// Deliberately NOT the operational record row. A Program Step has no date, no
/// tank count, no trip, no operator, no cost and no sync state — rendering
/// those was the central defect of the old shared row, because it dressed
/// reusable configuration up as an application that had happened.
///
/// The hierarchy is the one an operator reads a spray program in:
/// stage → name → target → products/rates → application method.
struct SprayProgramStepRow: View {
    @Environment(\.accessControl) private var accessControl

    let step: SprayProgramStep
    /// Region formatter for the programmed rate. Display only — the Program
    /// screen performs no spray arithmetic.
    let formatter: RegionFormatter

    private var productLines: [SprayChemical] {
        step.products.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var canEdit: Bool {
        SprayProgramStepPermissions.canEdit(
            step: step,
            canManageSprayProgram: accessControl?.canManageSprayProgram ?? false,
            canEditRecords: accessControl?.canEditRecords ?? false
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            stageBadge

            VStack(alignment: .leading, spacing: 5) {
                Text(step.name.isEmpty ? "Untitled Program Step" : step.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let target = step.targetDisplay {
                    Text(target)
                        .font(.caption)
                        .foregroundStyle(VineyardTheme.info)
                        .lineLimit(2)
                }

                if !productLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(productLines) { product in
                            Text(productSummary(product))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Label(step.operationType.rawValue, systemImage: step.operationType.iconName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if step.isPortalManaged {
                        // The lock is reserved for a reader who genuinely
                        // cannot change this step. For an owner/manager it is
                        // the shared Program Step, not a locked portal object.
                        Label(
                            SprayProgramTerminology.portalSyncBanner,
                            systemImage: canEdit ? "arrow.triangle.2.circlepath" : "lock"
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// `"Greenshield Copper · 1 kg/ha"`. The rate is read straight off the
    /// stored line through P10's basis-aware reporting, so a per-100 L step
    /// states per-100 L instead of a fabricated zero per hectare.
    private func productSummary(_ product: SprayChemical) -> String {
        guard product.reportedRateBaseValue > 0 else { return product.name }
        return "\(product.name) · \(product.reportedRateText(formatter: formatter))"
    }

    @ViewBuilder
    private var stageBadge: some View {
        if let label = step.elStageLabel {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(VineyardTheme.leafGreen)
                .frame(minWidth: 46)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(VineyardTheme.leafGreen.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        } else {
            // An unknown stage says so. Inventing "EL1" would place the step at
            // the head of the program.
            Text("—")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 46)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
