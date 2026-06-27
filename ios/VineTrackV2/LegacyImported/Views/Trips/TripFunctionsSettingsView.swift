import SwiftUI

/// Settings → Trip Functions: Owner/Manager can add, rename, and archive
/// vineyard-scoped custom Trip Functions. Supervisor/Operator see a
/// read-only list.
struct TripFunctionsSettingsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(VineyardTripFunctionService.self) private var service
    @Environment(BackendAccessControl.self) private var accessControl

    @State private var showAdd: Bool = false
    @State private var editing: VineyardTripFunction?
    @State private var pendingArchive: VineyardTripFunction?
    @State private var showError: Bool = false

    private var canManage: Bool { accessControl.canChangeSettings }

    private var activeFunctions: [VineyardTripFunction] {
        service.activeSortedByLabel
    }

    private var archivedFunctions: [VineyardTripFunction] {
        service.functions
            .filter { !$0.isActive || $0.deletedAt != nil }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                ForEach(TripFunction.allCases) { fn in
                    HStack(spacing: 12) {
                        Image(systemName: fn.icon)
                            .foregroundStyle(VineyardTheme.earthBrown)
                            .frame(width: 24)
                        Text(fn.displayName)
                        Spacer()
                        Text("Built-in")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Built-in functions")
            } footer: {
                Text("Built-in functions are always available and can't be removed.")
            }

            Section {
                if activeFunctions.isEmpty {
                    Text(canManage
                         ? "No custom trip functions yet. Tap + to add one."
                         : "No custom trip functions yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeFunctions) { fn in
                        customFunctionRow(fn)
                    }
                }
            } header: {
                HStack {
                    Text("Custom functions")
                    Spacer()
                    if canManage {
                        Button {
                            showAdd = true
                        } label: {
                            Label("Add", systemImage: "plus.circle.fill")
                                .labelStyle(.iconOnly)
                                .font(.title3)
                        }
                        .accessibilityLabel("Add custom trip function")
                    }
                }
            } footer: {
                if !canManage {
                    Text("Only Owners and Managers can add or change custom trip functions.")
                } else {
                    Text("Custom functions appear in the Start Maintenance Trip Function list. Archived functions stay attached to historical trips.")
                }
            }

            if !archivedFunctions.isEmpty {
                Section("Archived") {
                    ForEach(archivedFunctions) { fn in
                        HStack(spacing: 12) {
                            Image(systemName: "archivebox")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fn.label)
                                Text("custom:\(fn.slug)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if canManage {
                                Button("Restore") {
                                    Task { await service.restore(id: fn.id) }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Trip Functions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .task {
            if let vid = store.selectedVineyardId {
                await service.refresh(vineyardId: vid)
            }
        }
        .refreshable {
            if let vid = store.selectedVineyardId {
                await service.refresh(vineyardId: vid)
            }
        }
        .sheet(isPresented: $showAdd) {
            AddCustomTripFunctionSheet { _ in }
        }
        .sheet(item: $editing) { fn in
            EditCustomTripFunctionSheet(function: fn)
        }
        .alert("Archive function?", isPresented: Binding(
            get: { pendingArchive != nil },
            set: { if !$0 { pendingArchive = nil } }
        )) {
            Button("Archive", role: .destructive) {
                if let fn = pendingArchive {
                    Task { await service.archive(id: fn.id) }
                }
                pendingArchive = nil
            }
            Button("Cancel", role: .cancel) { pendingArchive = nil }
        } message: {
            Text("Existing trips that already use this function will keep their label. The function will no longer appear in the trip function list.")
        }
        .alert("Couldn't update", isPresented: $showError, presenting: service.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .onChange(of: service.errorMessage) { _, newValue in
            showError = newValue != nil
        }
    }

    @ViewBuilder
    private func customFunctionRow(_ fn: VineyardTripFunction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(VineyardTheme.leafGreen)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(fn.label)
                Text("custom:\(fn.slug)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if canManage {
                Menu {
                    Button {
                        editing = fn
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingArchive = fn
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if canManage {
                Button(role: .destructive) {
                    pendingArchive = fn
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        }
    }
}

// MARK: - Add custom trip function sheet

struct AddCustomTripFunctionSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(VineyardTripFunctionService.self) private var service
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    /// Called once after a successful save with the persisted function.
    var onSaved: (VineyardTripFunction) -> Void = { _ in }

    @State private var label: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return false }
        let slug = VineyardTripFunction.slugify(trimmed)
        // Reject collisions with built-in raw values.
        if TripFunction(rawValue: slug) != nil { return false }
        // Reject duplicate active slugs in this vineyard.
        if service.activeSortedByLabel.contains(where: { $0.slug == slug }) { return false }
        return accessControl.canChangeSettings
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label (e.g. Rolling)", text: $label)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                    if !label.isEmpty {
                        let slug = VineyardTripFunction.slugify(label)
                        LabeledContent("Slug") {
                            Text("custom:\(slug)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("The slug is generated from the label and stays stable if you rename later.")
                }

                if !accessControl.canChangeSettings {
                    Section {
                        Text("Ask an Owner or Manager to add trip functions.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Trip Function")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        guard let vineyardId = store.selectedVineyardId else {
            errorMessage = "No vineyard selected."
            return
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = VineyardTripFunction.slugify(trimmed)
        let nextOrder = (service.functions.map(\.sortOrder).max() ?? 0) + 10
        let item = VineyardTripFunction(
            vineyardId: vineyardId,
            label: trimmed,
            slug: slug,
            isActive: true,
            sortOrder: nextOrder
        )
        isSaving = true
        defer { isSaving = false }
        let ok = await service.upsert(item)
        if ok {
            onSaved(item)
            dismiss()
        } else {
            errorMessage = service.errorMessage ?? "Failed to save."
        }
    }
}

// MARK: - Edit (rename) custom trip function sheet

struct EditCustomTripFunctionSheet: View {
    @Environment(VineyardTripFunctionService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let function: VineyardTripFunction

    @State private var label: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedLabel.isEmpty && trimmedLabel != function.label && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Renaming updates the display label. The stable slug \"custom:\(function.slug)\" stays the same so existing trips keep their reference.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Rename Function")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if label.isEmpty { label = function.label }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        var updated = function
        updated.label = trimmedLabel
        updated.updatedAt = Date()
        isSaving = true
        defer { isSaving = false }
        let ok = await service.upsert(updated)
        if ok {
            dismiss()
        } else {
            errorMessage = service.errorMessage ?? "Failed to save."
        }
    }
}
