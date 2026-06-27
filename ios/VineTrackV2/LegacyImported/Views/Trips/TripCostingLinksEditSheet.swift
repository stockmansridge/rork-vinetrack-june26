import SwiftUI

/// Owner/manager-only override sheet for the costing-linked fields on a trip:
/// operator user, operator category and tractor. Used to correct older trips
/// where these links were never recorded, or to override an automatic
/// assignment so cost estimates reflect the real operator/equipment.
///
/// Visibility is gated by the caller (`canViewCosting`) \u2014 supervisors and
/// operators must never see or open this sheet.
struct TripCostingLinksEditSheet: View {
    let trip: Trip
    let vineyardMembers: [BackendVineyardMember]
    var onSave: (_ tractorId: UUID?, _ operatorUserId: UUID?, _ operatorCategoryId: UUID?) -> Void

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTractorId: UUID?
    @State private var selectedOperatorUserId: UUID?
    @State private var selectedOperatorCategoryId: UUID?
    /// Set to true once the operator manually picks a category, so changing
    /// the operator no longer auto-overwrites the chosen category.
    @State private var operatorCategoryManuallySet: Bool = false

    private var availableTractors: [Tractor] {
        let vineyardId = trip.vineyardId
        return store.tractors
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var availableCategories: [OperatorCategory] {
        let vineyardId = trip.vineyardId
        return store.operatorCategories
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var availableMembers: [BackendVineyardMember] {
        vineyardMembers.sorted {
            ($0.displayName ?? "").localizedCaseInsensitiveCompare($1.displayName ?? "") == .orderedAscending
        }
    }

    private var selectedTractorLabel: String {
        if let id = selectedTractorId, let t = availableTractors.first(where: { $0.id == id }) {
            return t.displayName
        }
        return availableTractors.isEmpty ? "No tractors configured" : "No tractor"
    }

    private var selectedOperatorLabel: String {
        if let id = selectedOperatorUserId,
           let member = availableMembers.first(where: { $0.userId == id }) {
            return member.displayName ?? "Member"
        }
        return availableMembers.isEmpty ? "No team members" : "Not set"
    }

    private var selectedCategoryLabel: String {
        if let id = selectedOperatorCategoryId,
           let cat = availableCategories.first(where: { $0.id == id }) {
            return cat.name
        }
        return availableCategories.isEmpty ? "No categories configured" : "Use member default"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Menu {
                        Button {
                            selectedTractorId = nil
                        } label: {
                            menuLabel("No tractor", selected: selectedTractorId == nil)
                        }
                        if !availableTractors.isEmpty {
                            Divider()
                            ForEach(availableTractors) { tractor in
                                Button {
                                    selectedTractorId = tractor.id
                                } label: {
                                    menuLabel(tractor.displayName, selected: selectedTractorId == tractor.id)
                                }
                            }
                        }
                    } label: {
                        pickerRow(
                            icon: "car.fill",
                            tint: .indigo,
                            title: "Tractor",
                            value: selectedTractorLabel
                        )
                    }
                } header: {
                    Text("Tractor")
                } footer: {
                    Text("Used to estimate fuel cost from the tractor's fuel-usage rate and vineyard fuel purchases.")
                }

                Section {
                    Menu {
                        Button {
                            selectedOperatorUserId = nil
                            if !operatorCategoryManuallySet {
                                selectedOperatorCategoryId = nil
                            }
                        } label: {
                            menuLabel("Not set", selected: selectedOperatorUserId == nil)
                        }
                        if !availableMembers.isEmpty {
                            Divider()
                            ForEach(availableMembers, id: \.userId) { member in
                                Button {
                                    selectedOperatorUserId = member.userId
                                    if !operatorCategoryManuallySet,
                                       let cid = member.operatorCategoryId {
                                        selectedOperatorCategoryId = cid
                                    }
                                } label: {
                                    menuLabel(member.displayName ?? "Member", selected: selectedOperatorUserId == member.userId)
                                }
                            }
                        }
                    } label: {
                        pickerRow(
                            icon: "person.fill",
                            tint: .orange,
                            title: "Operator",
                            value: selectedOperatorLabel
                        )
                    }

                    Menu {
                        Button {
                            selectedOperatorCategoryId = nil
                            operatorCategoryManuallySet = true
                        } label: {
                            menuLabel("Use member default", selected: selectedOperatorCategoryId == nil)
                        }
                        if !availableCategories.isEmpty {
                            Divider()
                            ForEach(availableCategories) { category in
                                Button {
                                    selectedOperatorCategoryId = category.id
                                    operatorCategoryManuallySet = true
                                } label: {
                                    menuLabel(
                                        "\(category.name) — \(formatRate(category.costPerHour))",
                                        selected: selectedOperatorCategoryId == category.id
                                    )
                                }
                            }
                        }
                    } label: {
                        pickerRow(
                            icon: "dollarsign.circle.fill",
                            tint: VineyardTheme.leafGreen,
                            title: "Operator category",
                            value: selectedCategoryLabel
                        )
                    }
                } header: {
                    Text("Operator")
                } footer: {
                    Text("Picking an operator prefills their default category from team settings. You can override the category for this trip if needed.")
                }
            }
            .navigationTitle("Edit Costing Links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(selectedTractorId, selectedOperatorUserId, selectedOperatorCategoryId)
                        dismiss()
                    }
                }
            }
            .onAppear {
                selectedTractorId = trip.tractorId
                selectedOperatorUserId = trip.operatorUserId
                selectedOperatorCategoryId = trip.operatorCategoryId
                operatorCategoryManuallySet = trip.operatorCategoryId != nil
            }
        }
    }

    @ViewBuilder
    private func menuLabel(_ text: String, selected: Bool) -> some View {
        HStack {
            Text(text)
            if selected {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
    }

    @ViewBuilder
    private func pickerRow(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func formatRate(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 2
        return (f.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)) + "/hr"
    }
}
