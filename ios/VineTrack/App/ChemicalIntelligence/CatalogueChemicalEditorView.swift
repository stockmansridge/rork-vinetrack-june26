import SwiftUI

/// Catalogue-owned facts are read-only. The only editable field here is vineyard notes.
struct CatalogueChemicalEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    let chemical: SavedChemical
    let onSaved: ((SavedChemical) -> Void)?
    @State private var notes: String
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var deleteCoordinator = ChemicalDeleteCoordinator()

    init(chemical: SavedChemical, onSaved: ((SavedChemical) -> Void)? = nil) {
        self.chemical = chemical
        self.onSaved = onSaved
        _notes = State(initialValue: chemical.notes)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Product") { CatalogueSavedChemicalView(chemical: chemical, showsDetails: true) }
                Section("Notes") { TextField("Vineyard notes (optional)", text: $notes, axis: .vertical).lineLimit(3...8) }
                Section {
                    Text("Stock and purchases are managed in Chemical Inventory. Existing spray-cost information is retained.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Manage chemical") {
                    Button("Archive chemical") { deleteCoordinator.pending = chemical }.disabled(isSaving || deleteCoordinator.isWorking)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("Chemical details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button(isSaving ? "Saving…" : "Save") { Task { await save() } }.disabled(isSaving || deleteCoordinator.isWorking) }
            }
            .interactiveDismissDisabled(isSaving)
            .chemicalDeletionActions(coordinator: deleteCoordinator, store: store)
            .onChange(of: deleteCoordinator.didDeleteId) { _, id in if id != nil { dismiss() } }
        }
    }
    @MainActor private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await CatalogueRepository().updateNotes(for: chemical, notes: notes)
            store.applyRemoteSavedChemicalUpsert(saved)
            onSaved?(saved)
            dismiss()
        } catch {
            errorMessage = "Couldn't save notes. Check your connection and permissions, then try again."
        }
    }
}
