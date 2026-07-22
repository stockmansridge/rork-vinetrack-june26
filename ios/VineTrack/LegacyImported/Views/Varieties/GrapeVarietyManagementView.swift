import SwiftUI

struct GrapeVarietyManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @State private var showAddSheet: Bool = false
    @State private var editingVariety: GrapeVariety?
    @State private var pendingDelete: GrapeVariety?
    @State private var pendingArchive: GrapeVariety?
    @State private var deletingVarietyId: UUID?
    @State private var alertMessage: AlertMessage?

    private let catalogRepository = SupabaseGrapeVarietyCatalogRepository()

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    private var sortedVarieties: [GrapeVariety] {
        store.grapeVarieties.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Custom = vineyard-scoped row with a `custom:` key. Only these may be
    /// hard-deleted. Built-ins (no key prefix, `isBuiltIn == true`) never get
    /// a delete affordance.
    private func isCustom(_ variety: GrapeVariety) -> Bool {
        if variety.isBuiltIn { return false }
        if let key = variety.key, key.hasPrefix("custom:") { return true }
        // Defensive: a non-built-in row with no key is treated as custom so
        // the user can still tidy it up.
        return !variety.isBuiltIn
    }

    var body: some View {
        List {
            Section {
                ForEach(sortedVarieties) { variety in
                    Group {
                        if canManageSetup {
                            Button { editingVariety = variety } label: { varietyRow(variety) }
                        } else {
                            varietyRow(variety, showChevron: false)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if canManageSetup && isCustom(variety) {
                            Button(role: .destructive) {
                                pendingDelete = variety
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(deletingVarietyId != nil)
                        }
                    }
                }
            } header: {
                Text("Master Variety List")
            } footer: {
                if canManageSetup {
                    Text("Optimal GDD (base 10°C) is the heat units typically needed for a variety to reach harvest ripeness. Built-in varieties cannot be deleted. Custom varieties can be permanently deleted only when not used by any vineyard records.")
                } else {
                    Text("Setup data is managed by vineyard owners and managers.")
                }
            }
        }
        .navigationTitle("Grape Varieties")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManageSetup {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            EditGrapeVarietySheet(variety: nil)
        }
        .sheet(item: $editingVariety) { variety in
            EditGrapeVarietySheet(variety: variety)
        }
        .confirmationDialog(
            "Permanently delete this custom variety?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { variety in
            Button("Delete Permanently", role: .destructive) {
                Task { await hardDelete(variety) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This will remove the custom grape variety from your library. It can only be deleted if it is not used by any vineyard records or historical data.")
        }
        .confirmationDialog(
            "Archive this grape variety?",
            isPresented: Binding(
                get: { pendingArchive != nil },
                set: { if !$0 { pendingArchive = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingArchive
        ) { variety in
            Button("Archive", role: .destructive) {
                Task { await archive(variety) }
            }
            Button("Cancel", role: .cancel) { pendingArchive = nil }
        } message: { _ in
            Text("It will be hidden from the active variety list but kept for historical records.")
        }
        .alert(item: $alertMessage) { msg in
            if let archive = msg.archiveCandidate {
                return Alert(
                    title: Text(msg.title),
                    message: Text(msg.body),
                    primaryButton: .default(Text("Archive Instead")) {
                        pendingArchive = archive
                    },
                    secondaryButton: .cancel(Text("OK"))
                )
            }
            return Alert(title: Text(msg.title), message: Text(msg.body), dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder
    private func varietyRow(_ variety: GrapeVariety, showChevron: Bool = true) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(variety.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if isCustom(variety) {
                        Text("Custom")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: .capsule)
                    }
                }
                Text("Optimal: \(Int(variety.optimalGDD)) GDD")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if deletingVarietyId == variety.id {
                ProgressView()
            } else if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Actions

    private func hardDelete(_ variety: GrapeVariety) async {
        pendingDelete = nil
        deletingVarietyId = variety.id
        defer { deletingVarietyId = nil }

        do {
            let result = try await catalogRepository.hardDeleteUnusedCustomGrapeVariety(id: variety.id)
            let outcome = CustomGrapeVarietyDeletionOutcome.map(result)
            switch outcome {
            case .hardDeleted:
                store.deleteGrapeVariety(variety)
                alertMessage = AlertMessage(
                    title: "Variety Deleted",
                    body: "Custom grape variety deleted."
                )
            case .varietyInUse(let message):
                alertMessage = AlertMessage(
                    title: "Cannot Delete",
                    body: message,
                    archiveCandidate: variety
                )
            case .notFound:
                // Already gone server-side — clean up locally.
                store.deleteGrapeVariety(variety)
                alertMessage = AlertMessage(
                    title: "Already Removed",
                    body: "This grape variety was already deleted."
                )
            case .notCustom, .systemVariety:
                alertMessage = AlertMessage(
                    title: "Cannot Delete",
                    body: "Built-in grape varieties cannot be deleted."
                )
            case .notAuthorised:
                alertMessage = AlertMessage(
                    title: "Not Permitted",
                    body: "You don't have permission to delete grape varieties for this vineyard."
                )
            case .failed(let message):
                alertMessage = AlertMessage(title: "Delete Failed", body: message)
            }
        } catch {
            alertMessage = AlertMessage(
                title: "Delete Failed",
                body: "Couldn't reach Supabase: \(error.localizedDescription). Please try again."
            )
        }
    }

    private func archive(_ variety: GrapeVariety) async {
        pendingArchive = nil
        deletingVarietyId = variety.id
        defer { deletingVarietyId = nil }

        do {
            _ = try await catalogRepository.archiveVineyardVariety(id: variety.id)
            store.deleteGrapeVariety(variety)
            alertMessage = AlertMessage(
                title: "Variety Archived",
                body: "The grape variety has been hidden from active lists. Historical records continue to display its name."
            )
        } catch {
            alertMessage = AlertMessage(
                title: "Archive Failed",
                body: "Couldn't archive this grape variety: \(error.localizedDescription). Please try again."
            )
        }
    }
}

private struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    var archiveCandidate: GrapeVariety?
}

struct EditGrapeVarietySheet: View {
    let variety: GrapeVariety?
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var optimalGDDText: String = "1400"
    @State private var isSaving: Bool = false
    @State private var saveError: String?
    private let catalogRepository = SupabaseGrapeVarietyCatalogRepository()

    private var isEditing: Bool { variety != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Chardonnay", text: $name)
                        .autocorrectionDisabled()
                }

                Section {
                    HStack {
                        Text("Optimal GDD")
                        Spacer()
                        TextField("1400", text: $optimalGDDText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                        Text("°C·days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Ripeness Target")
                } footer: {
                    Text("Growing Degree Days (base 10°C) required to reach harvest ripeness.")
                }
            }
            .navigationTitle(isEditing ? "Edit Variety" : "New Variety")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .onAppear {
                if let variety {
                    name = variety.name
                    optimalGDDText = "\(Int(variety.optimalGDD))"
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let gdd = Double(optimalGDDText) ?? 1400
        isSaving = true
        defer { isSaving = false }
        saveError = nil

        if var existing = variety {
            existing.name = trimmedName
            existing.optimalGDD = gdd
            store.updateGrapeVariety(existing)
            // Best-effort: mirror the rename / GDD override to the shared
            // vineyard_grape_varieties table so other clients see it.
            if let vid = store.selectedVineyardId {
                let key: String? = existing.key
                _ = try? await catalogRepository.upsertVineyardVariety(
                    vineyardId: vid,
                    key: key,
                    displayName: trimmedName,
                    optimalGDDOverride: existing.isBuiltIn ? nil : gdd,
                    isActive: true
                )
            }
            dismiss()
            return
        }

        // New variety. If the name matches a built-in catalog entry, the
        // local add helper will stamp the catalog key + deterministic id.
        // Otherwise we route through `upsert_vineyard_grape_variety` so the
        // server mints a stable `custom:<vineyardId>:<slug>` key — this is
        // what keeps custom varieties resolvable across devices.
        let catalogEntry = BuiltInGrapeVarietyCatalog.entry(matching: trimmedName)
        if catalogEntry != nil {
            let new = GrapeVariety(name: trimmedName, optimalGDD: gdd)
            store.addGrapeVariety(new)
            dismiss()
            return
        }

        guard let vid = store.selectedVineyardId else {
            saveError = "No vineyard selected. Open a vineyard before adding a custom variety so it can sync to Lovable."
            return
        }

        do {
            let row = try await catalogRepository.upsertVineyardVariety(
                vineyardId: vid,
                key: nil,
                displayName: trimmedName,
                optimalGDDOverride: gdd,
                isActive: true
            )
            // Mirror the server row locally with the stable key so the
            // resolver can use it.
            let new = GrapeVariety(
                vineyardId: vid,
                name: row.displayName,
                optimalGDD: row.optimalGDDOverride ?? gdd,
                isBuiltIn: false,
                key: row.varietyKey
            )
            store.addGrapeVariety(new)
            dismiss()
        } catch {
            // RPC failed (offline, auth, or RLS). Surface a sticky error and
            // do NOT fall back to a local-only row — a local row would silently
            // diverge from Lovable, which is exactly the bug we're guarding
            // against. User can retry once connectivity / role is fixed.
            #if DEBUG
            print("[GrapeVariety] upsert_vineyard_grape_variety failed: \(error)")
            #endif
            saveError = "Couldn't save to shared catalogue: \(error.localizedDescription). Tap Save to retry."
        }
    }
}
