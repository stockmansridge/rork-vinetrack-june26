import SwiftUI

/// Encapsulates the two-step archive / permanent-delete confirmation flow for
/// a saved chemical. Backend (`soft_delete_saved_chemicals` /
/// `hard_delete_unused_saved_chemical`) is always the final authority — if it
/// reports `chemical_in_use` we surface the user-facing message and the
/// chemical is left intact.
@MainActor
@Observable
final class ChemicalDeleteCoordinator {
    /// The chemical the user has chosen to act on. Setting this triggers the
    /// confirmation dialog.
    var pending: SavedChemical?

    /// Generic alert message (errors, in-use rejections).
    var alertMessage: String?

    /// Set when the chemical has been removed remotely so the host view can
    /// react (e.g. dismiss the edit sheet).
    var didDeleteId: UUID?

    var isWorking: Bool = false

    fileprivate let service = SavedChemicalDeletionService()

    func archive(_ chemical: SavedChemical, store: MigratedDataStore) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await service.archive(id: chemical.id)
            switch outcome {
            case .archived, .notFound:
                store.removeSavedChemicalLocallyOnly(chemical.id)
                didDeleteId = chemical.id
            case .hardDeleted:
                store.removeSavedChemicalLocallyOnly(chemical.id)
                didDeleteId = chemical.id
            case .chemicalInUse(let message):
                alertMessage = message
            }
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func hardDelete(_ chemical: SavedChemical, store: MigratedDataStore) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await service.hardDelete(id: chemical.id)
            switch outcome {
            case .hardDeleted, .notFound:
                store.removeSavedChemicalLocallyOnly(chemical.id)
                didDeleteId = chemical.id
            case .archived:
                store.removeSavedChemicalLocallyOnly(chemical.id)
                didDeleteId = chemical.id
            case .chemicalInUse(let message):
                alertMessage = message
            }
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

extension View {
    /// Attaches the confirmation dialog + alert UI for the chemical delete
    /// coordinator. Call this on a view that has access to `MigratedDataStore`
    /// in its environment.
    func chemicalDeletionActions(
        coordinator: ChemicalDeleteCoordinator,
        store: MigratedDataStore
    ) -> some View {
        modifier(ChemicalDeletionActionsModifier(coordinator: coordinator, store: store))
    }
}

private struct ChemicalDeletionActionsModifier: ViewModifier {
    @Bindable var coordinator: ChemicalDeleteCoordinator
    let store: MigratedDataStore

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                coordinator.pending.map { chemical in
                    store.isSavedChemicalInUseLocally(chemical.id)
                        ? "Archive \(chemical.name)?"
                        : "Delete or archive \(chemical.name)?"
                } ?? "",
                isPresented: Binding(
                    get: { coordinator.pending != nil },
                    set: { newValue in if !newValue { coordinator.pending = nil } }
                ),
                titleVisibility: .visible,
                presenting: coordinator.pending
            ) { chemical in
                let inUseLocally = store.isSavedChemicalInUseLocally(chemical.id)
                Button("Archive Chemical") {
                    Task { await coordinator.archive(chemical, store: store) }
                }
                if !inUseLocally {
                    Button("Delete Permanently", role: .destructive) {
                        Task { await coordinator.hardDelete(chemical, store: store) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { chemical in
                if store.isSavedChemicalInUseLocally(chemical.id) {
                    Text("Archive this chemical? It will be hidden from active chemical lists but kept for historical records.")
                } else {
                    Text("Archive hides this chemical but keeps it for historical records. Delete Permanently removes it entirely — only available because it has not been used in any spray records on this device. This cannot be undone.")
                }
            }
            .alert(
                "Chemical",
                isPresented: Binding(
                    get: { coordinator.alertMessage != nil },
                    set: { newValue in if !newValue { coordinator.alertMessage = nil } }
                ),
                presenting: coordinator.alertMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
    }
}
