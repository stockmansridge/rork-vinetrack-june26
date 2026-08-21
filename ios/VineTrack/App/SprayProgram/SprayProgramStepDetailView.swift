import SwiftUI

/// Detail for one reusable Program Step.
///
/// Deliberately NOT `SprayRecordDetailView`. That screen describes an
/// application that happened — timing, weather, tanks, rows sprayed, maps,
/// costs, export, sync. None of those concepts exist on reusable configuration,
/// and showing them invites an operator to read a program step as a record.
///
/// This screen answers only: which stage, what for, with what, applied how —
/// and then gets out of the way behind one action, Plan Spray.
struct SprayProgramStepDetailView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss

    let step: SprayProgramStep
    /// Opens the guided calculator with this step as prefill. Owned by the
    /// parent so the Program tab and the + menu share ONE route.
    let onPlanSpray: (SprayProgramStep) -> Void

    @State private var showEditSheet: Bool = false
    @State private var showDeleteConfirmation: Bool = false

    private var formatter: RegionFormatter { store.settings.regionFormatter }

    private var productLines: [SprayChemical] {
        step.products.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var canDelete: Bool {
        !step.isPortalManaged && (accessControl?.canDelete ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if step.isPortalManaged {
                    portalBanner
                }

                if let target = step.targetDisplay {
                    section("Targets", icon: "scope") {
                        Text(target)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !productLines.isEmpty {
                    section("Products & Rates", icon: "flask.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(productLines) { product in
                                productRow(product)
                            }
                        }
                    }
                }

                section("Application", icon: "gearshape.2") {
                    VStack(alignment: .leading, spacing: 6) {
                        detailLine("Method", step.operationType.rawValue)
                        if let stage = step.elStageLabel {
                            detailLine("Growth stage", step.growthStageDescription.map { "\(stage) — \($0)" } ?? stage)
                        }
                        if let equipment = equipmentName {
                            detailLine("Spray unit", equipment)
                        }
                        if let tractor = tractorName {
                            detailLine("Tractor", tractor)
                        }
                    }
                }

                chemistrySection

                if !step.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    section("Notes", icon: "note.text") {
                        Text(step.notes)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Blocks, carrier volume and every quantity are deliberately
                // absent: a Program Step does not know where it is going, and
                // the guided calculator owns all of that arithmetic.
                Text("Blocks, carrier volume and quantities are set when you plan the spray.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Program Step")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                onPlanSpray(step)
            } label: {
                Label("Plan Spray", systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(VineyardTheme.leafGreen, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .toolbar {
            // Portal-managed steps expose no Edit, no Delete and no template
            // toggle — the existing mobile permission boundary, unchanged.
            if !step.isPortalManaged {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showEditSheet = true
                        } label: {
                            Label("Edit Program Step", systemImage: "pencil")
                        }
                        if canDelete {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete Program Step", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            NavigationStack {
                SprayRecordFormView(
                    tripId: step.record.tripId,
                    paddockIds: [],
                    existingRecord: step.record
                )
            }
        }
        .alert("Delete Program Step", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteSprayRecord(step.record)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the step from your spray program. Sprays already recorded from it are not affected.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stage = step.elStageLabel {
                HStack(spacing: 8) {
                    Text(stage)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(VineyardTheme.leafGreen.opacity(0.14), in: Capsule())
                    if let description = step.growthStageDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(step.name.isEmpty ? "Untitled Program Step" : step.name)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var portalBanner: some View {
        Label("Managed in Admin Portal", systemImage: "lock")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Chemistry

    /// Resistance/chemistry for the products this step POINTS AT, read from
    /// today's Chemical Store.
    ///
    /// That is correct here and only here: a Program Step is reusable
    /// configuration, so it must describe the product as it is classified now,
    /// not as it was classified whenever the step was written. Completed sprays
    /// take the opposite rule and read their own frozen snapshot — nothing on
    /// this screen touches historical data.
    @ViewBuilder
    private var chemistrySection: some View {
        let resolutions = productLines.map { product in
            (
                product: product,
                saved: ChemicalSnapshotCapture.resolve(
                    savedChemicalId: product.savedChemicalId,
                    productName: product.name,
                    registrationIdentityKey: product.chemicalSnapshot?.registrationIdentityKey,
                    in: store.savedChemicals
                ).chemical
            )
        }

        if !resolutions.isEmpty {
            section("Chemical Information", icon: "cross.case") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(resolutions.enumerated()), id: \.offset) { _, entry in
                        if let saved = entry.saved {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(saved.name)
                                        .font(.subheadline.weight(.medium))
                                    ChemicalVerificationBadge(status: saved.verificationStatus, compact: true)
                                }
                                let groups = saved.resolvedIntelligence.activityGroups
                                if !groups.isEmpty {
                                    Text(groups.legacyGroupProjection)
                                        .font(.caption)
                                        .foregroundStyle(VineyardTheme.olive)
                                }
                                if !saved.activeIngredient.isEmpty {
                                    Text(saved.activeIngredient)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        } else {
                            // Named, never dropped. The operator has to
                            // re-select it when planning, and needs to know
                            // that before they get there.
                            Label(
                                "\(entry.product.name) is not in your Chemical Store",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(VineyardTheme.warning)
                        }
                    }
                    Text("Resistance is assessed against the spray you actually plan, in the calculator.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Building blocks

    private var equipmentName: String? {
        if let id = step.record.sprayEquipmentId,
           let match = store.sprayEquipment.first(where: { $0.id == id }) {
            return match.name
        }
        let typed = step.record.equipmentType.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? nil : typed
    }

    private var tractorName: String? {
        if let id = step.record.tractorId,
           let match = store.tractors.first(where: { $0.id == id }) {
            return match.displayName
        }
        let typed = step.record.tractor.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? nil : typed
    }

    private func productRow(_ product: SprayChemical) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(product.name)
                .font(.subheadline)
            Spacer()
            if product.reportedRateBaseValue > 0 {
                // Stored configuration, reported on the basis it was recorded
                // on (P10). Nothing here is recalculated.
                Text(product.reportedRateText(formatter: formatter))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VineyardTheme.olive)
            } else {
                Text("Rate set when planning")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
