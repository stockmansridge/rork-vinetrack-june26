import SwiftUI

struct OperatorCategoriesView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(OperatorCategorySyncService.self) private var operatorCategorySync
    @Environment(\.accessControl) private var accessControl
    @State private var showAddSheet: Bool = false
    @State private var editingCategory: OperatorCategory?
    @State private var removedDuplicateCount: Int = 0
    @State private var showDuplicateRemovedAlert: Bool = false

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    private var vineyardCategories: [OperatorCategory] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.operatorCategories.filter { $0.vineyardId == vid }
    }

    var body: some View {
        List {
            Section {
                ForEach(vineyardCategories) { category in
                    Group {
                        if canManageSetup {
                            Button {
                                editingCategory = category
                            } label: {
                                operatorRow(category)
                            }
                        } else {
                            operatorRow(category, showChevron: false)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if canManageSetup {
                            Button(role: .destructive) {
                                store.deleteOperatorCategory(category)
                                Task { await operatorCategorySync.syncForSelectedVineyard() }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                if canManageSetup {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Category", systemImage: "plus.circle")
                    }
                }
            } header: {
                Text("Categories")
            } footer: {
                if canManageSetup {
                    Text("Define operator categories with hourly rates. Assign them to vineyard users to calculate operator costs on trip reports.")
                } else {
                    Text("Setup data is managed by vineyard owners and managers.")
                }
            }
        }
        .navigationTitle("Operator Categories")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await operatorCategorySync.syncForSelectedVineyard()
        }
        .onAppear {
            guard canManageSetup else { return }
            let removed = store.deduplicateOperatorCategories()
            if removed > 0 {
                removedDuplicateCount = removed
                showDuplicateRemovedAlert = true
            }
        }
        .alert("Duplicates Removed", isPresented: $showDuplicateRemovedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Removed \(removedDuplicateCount) duplicate operator \(removedDuplicateCount == 1 ? "category" : "categories").")
        }
        .sheet(isPresented: $showAddSheet, onDismiss: {
            Task { await operatorCategorySync.syncForSelectedVineyard() }
        }) {
            OperatorCategoryFormSheet(category: nil)
        }
        .sheet(item: $editingCategory, onDismiss: {
            Task { await operatorCategorySync.syncForSelectedVineyard() }
        }) { category in
            OperatorCategoryFormSheet(category: category)
        }
    }
    @ViewBuilder
    private func operatorRow(_ category: OperatorCategory, showChevron: Bool = true) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if accessControl?.canViewFinancials ?? false {
                    Text(String(format: "$%.2f /hr", category.costPerHour))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct OperatorCategoryFormSheet: View {
    let category: OperatorCategory?
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var costString: String = ""
    @State private var assignedUserIds: Set<UUID> = []

    private var isEditing: Bool { category != nil }

    private var vineyardUsers: [VineyardUser] {
        guard let vineyardId = store.selectedVineyardId,
              let vineyard = store.vineyards.first(where: { $0.id == vineyardId }) else { return [] }
        return vineyard.users
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Category Name", text: $name)
                    HStack {
                        Text("$")
                            .foregroundStyle(.secondary)
                        TextField("Cost per hour", text: $costString)
                            .keyboardType(.decimalPad)
                        Text("/hr")
                            .foregroundStyle(.secondary)
                    }
                }

                if !vineyardUsers.isEmpty {
                    Section {
                        ForEach(vineyardUsers) { user in
                            Button {
                                toggleUser(user.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: assignedUserIds.contains(user.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(assignedUserIds.contains(user.id) ? .blue : .secondary)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(user.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        Text(user.role.rawValue)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    } header: {
                        Text("Assign Users")
                    } footer: {
                        Text("Select users to assign to this operator category.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Category" : "Add Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let category {
                    name = category.name
                    costString = category.costPerHour > 0 ? String(format: "%.2f", category.costPerHour) : ""
                    assignedUserIds = Set(vineyardUsers.filter { $0.operatorCategoryId == category.id }.map { $0.id })
                }
            }
        }
    }

    private func toggleUser(_ userId: UUID) {
        if assignedUserIds.contains(userId) {
            assignedUserIds.remove(userId)
        } else {
            assignedUserIds.insert(userId)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let cost = Double(costString) ?? 0

        let categoryId: UUID
        if var existing = category {
            existing.name = trimmedName
            existing.costPerHour = cost
            store.updateOperatorCategory(existing)
            categoryId = existing.id
        } else {
            let newCategory = OperatorCategory(
                vineyardId: store.selectedVineyardId ?? UUID(),
                name: trimmedName,
                costPerHour: cost
            )
            store.addOperatorCategory(newCategory)
            categoryId = newCategory.id
        }

        guard let vineyardId = store.selectedVineyardId,
              let vineyardIndex = store.vineyards.firstIndex(where: { $0.id == vineyardId }) else {
            dismiss()
            return
        }
        var updated = store.vineyards[vineyardIndex]
        for i in updated.users.indices {
            if assignedUserIds.contains(updated.users[i].id) {
                updated.users[i].operatorCategoryId = categoryId
            } else if updated.users[i].operatorCategoryId == categoryId {
                updated.users[i].operatorCategoryId = nil
            }
        }
        store.updateVineyard(updated)
        dismiss()
    }
}
