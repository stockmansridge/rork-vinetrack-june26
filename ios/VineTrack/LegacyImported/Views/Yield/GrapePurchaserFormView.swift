import SwiftUI

/// Simple add / edit form for one saved purchaser (sql/219): winery name +
/// optional contact details. Deliberately NOT a CRM — no tags, history,
/// reminders or documents. Editing a purchaser never rewrites the snapshots
/// already stored on existing allocations.
struct GrapePurchaserFormView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(GrapeAllocationService.self) private var allocationService
    @Environment(\.dismiss) private var dismiss

    let existing: GrapePurchaser?
    let onSaved: (GrapePurchaser) -> Void

    @State private var wineryName: String = ""
    @State private var contactName: String = ""
    @State private var contactEmail: String = ""
    @State private var contactPhone: String = ""
    @State private var contactAddress: String = ""
    @State private var isSaving: Bool = false
    @State private var saveError: String?
    @State private var didLoad: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Winery / purchaser name", text: $wineryName)
                    TextField("Contact name (optional)", text: $contactName)
                    TextField("Email (optional)", text: $contactEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Phone (optional)", text: $contactPhone)
                        .keyboardType(.phonePad)
                    TextField("Address (optional)", text: $contactAddress)
                } header: {
                    Text("Purchaser")
                } footer: {
                    Text("Saved for reuse across allocations. Existing allocations keep the details they were created with.")
                }
                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Purchaser" : "Edit Purchaser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(wineryName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .onAppear { loadExisting() }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadExisting() {
        guard !didLoad else { return }
        didLoad = true
        guard let existing else { return }
        wineryName = existing.wineryName
        contactName = existing.contactName ?? ""
        contactEmail = existing.contactEmail ?? ""
        contactPhone = existing.contactPhone ?? ""
        contactAddress = existing.contactAddress ?? ""
    }

    private func save() {
        guard let vineyardId = store.selectedVineyardId else { return }
        func trimmedOrNil(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        let purchaser = GrapePurchaser(
            id: existing?.id ?? UUID(),
            vineyardId: existing?.vineyardId ?? vineyardId,
            wineryName: wineryName.trimmingCharacters(in: .whitespaces),
            contactName: trimmedOrNil(contactName),
            contactEmail: trimmedOrNil(contactEmail),
            contactPhone: trimmedOrNil(contactPhone),
            contactAddress: trimmedOrNil(contactAddress),
            updatedAt: existing?.updatedAt
        )
        isSaving = true
        saveError = nil
        Task {
            do {
                try await allocationService.savePurchaser(purchaser, createdBy: nil)
                onSaved(purchaser)
                dismiss()
            } catch {
                saveError = "Couldn't save the purchaser. Check your connection and try again."
                print("[GrapePurchaserForm] save failed: \(error)")
            }
            isSaving = false
        }
    }
}
