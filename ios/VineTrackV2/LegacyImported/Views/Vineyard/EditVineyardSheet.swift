import SwiftUI

/// Phase 6A — backend-aware create / rename vineyard sheet.
///
/// Creating a vineyard goes through `SupabaseVineyardRepository.createVineyard`,
/// then the resulting `BackendVineyard` is mapped into `MigratedDataStore`.
/// Renaming an existing vineyard updates the backend then the local store.
struct EditVineyardSheet: View {
    let vineyard: Vineyard?
    let vineyardRepository: any VineyardRepositoryProtocol

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var country: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    private var isEditing: Bool { vineyard != nil }

    private static let wineCountries: [String] = [
        "Australia", "Argentina", "Austria", "Brazil", "Canada", "Chile", "China",
        "France", "Germany", "Greece", "Hungary", "India", "Israel", "Italy",
        "Japan", "Mexico", "New Zealand", "Portugal", "Romania", "South Africa",
        "Spain", "Switzerland", "United Kingdom", "United States", "Uruguay"
    ]

    init(
        vineyard: Vineyard?,
        vineyardRepository: any VineyardRepositoryProtocol = SupabaseVineyardRepository()
    ) {
        self.vineyard = vineyard
        self.vineyardRepository = vineyardRepository
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Vineyard Name") {
                    TextField("e.g. Barossa Valley Estate", text: $name)
                }

                Section("Country") {
                    Picker("Country", selection: $country) {
                        Text("Not Set").tag("")
                        ForEach(Self.wineCountries, id: \.self) { c in
                            Text(c).tag(c)
                        }
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
            .navigationTitle(isEditing ? "Edit Vineyard" : "New Vineyard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if let vineyard {
                    name = vineyard.name
                    country = vineyard.country
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let trimmedCountry = country.trimmingCharacters(in: .whitespaces)
        let countryParam: String? = trimmedCountry.isEmpty ? nil : trimmedCountry

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            if let existing = vineyard {
                let backend = BackendVineyard(
                    id: existing.id,
                    name: trimmedName,
                    ownerId: nil,
                    country: countryParam,
                    logoPath: existing.logoPath,
                    logoUpdatedAt: existing.logoUpdatedAt,
                    createdAt: nil,
                    updatedAt: nil,
                    deletedAt: nil
                )
                try await vineyardRepository.updateVineyard(backend)
                var updated = existing
                updated.name = trimmedName
                updated.country = trimmedCountry
                store.upsertLocalVineyard(updated)
            } else {
                let backend = try await vineyardRepository.createVineyard(
                    name: trimmedName,
                    country: countryParam
                )
                store.mapBackendVineyardsIntoLocal([backend] + store.vineyards.compactMap { local in
                    BackendVineyard(
                        id: local.id,
                        name: local.name,
                        ownerId: nil,
                        country: local.country.isEmpty ? nil : local.country,
                        logoPath: local.logoPath,
                        logoUpdatedAt: local.logoUpdatedAt,
                        createdAt: local.createdAt,
                        updatedAt: nil,
                        deletedAt: nil
                    )
                })
                if let created = store.vineyards.first(where: { $0.id == backend.id }) {
                    store.selectVineyard(created)
                }
                // First-vineyard milestone: request the portal-awareness
                // prompt. The global listener decides whether to actually
                // present it based on role and previous interactions.
                if store.vineyards.count <= 1 {
                    PortalPromptTracker.requestIfUnseen(.firstVineyard)
                }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
