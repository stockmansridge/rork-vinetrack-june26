import SwiftUI
import PhotosUI

/// Backend-aware vineyard detail sheet. Supports rename, country, logo
/// upload/change/remove (synced via Supabase Storage), and soft-delete.
struct BackendVineyardDetailSheet: View {
    let initialVineyard: Vineyard
    let vineyardRepository: any VineyardRepositoryProtocol
    private let logoStorage: VineyardLogoStorageService

    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(\.dismiss) private var dismiss

    @State private var showEditName: Bool = false
    @State private var editedName: String = ""
    @State private var selectedCountry: String = ""
    @State private var showDeleteConfirm: Bool = false
    @State private var deleteConfirmationText: String = ""
    @State private var memberCount: Int = 0
    @State private var isWorking: Bool = false
    @State private var isUploadingLogo: Bool = false
    @State private var errorMessage: String?
    @State private var selectedLogoItem: PhotosPickerItem?
    @State private var showRemoveLogoConfirm: Bool = false

    init(
        vineyard: Vineyard,
        vineyardRepository: any VineyardRepositoryProtocol = SupabaseVineyardRepository(),
        logoStorage: VineyardLogoStorageService = VineyardLogoStorageService()
    ) {
        self.initialVineyard = vineyard
        self.vineyardRepository = vineyardRepository
        self.logoStorage = logoStorage
    }

    private var vineyard: Vineyard {
        store.vineyards.first(where: { $0.id == initialVineyard.id }) ?? initialVineyard
    }

    private static let wineCountries: [String] = [
        "Australia", "Argentina", "Austria", "Brazil", "Canada", "Chile", "China",
        "France", "Germany", "Greece", "Hungary", "India", "Israel", "Italy",
        "Japan", "Mexico", "New Zealand", "Portugal", "Romania", "South Africa",
        "Spain", "Switzerland", "United Kingdom", "United States", "Uruguay"
    ]

    var body: some View {
        NavigationStack {
            List {
                logoSection
                infoSection
                if accessControl.canChangeSettings {
                    dangerSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(vineyard.name)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                selectedCountry = vineyard.country
                memberCount = max(memberCount, 1)
                await ensureLogoCached()
                await loadMemberCount()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(isWorking || isUploadingLogo)
                }
            }
            .alert("Rename Vineyard", isPresented: $showEditName) {
                TextField("Vineyard name", text: $editedName)
                Button("Save") {
                    Task { await rename() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Archive Vineyard?", isPresented: $showDeleteConfirm) {
                TextField("Type DELETE to confirm", text: $deleteConfirmationText)
                Button("Archive", role: .destructive) {
                    Task { await deleteVineyard() }
                }
                .disabled(deleteConfirmationText != "DELETE")
                Button("Cancel", role: .cancel) {
                    deleteConfirmationText = ""
                }
            } message: {
                Text(deleteWarningText)
            }
            .alert("Error", isPresented: errorBinding, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var logoSection: some View {
        Section {
            HStack(spacing: 16) {
                logoPreview
                VStack(alignment: .leading, spacing: 4) {
                    Text(logoStatusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text("Logos appear on exported PDFs and reports, and sync to all members of this vineyard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isUploadingLogo {
                    ProgressView()
                }
            }

            if accessControl.canChangeSettings {
                PhotosPicker(selection: $selectedLogoItem, matching: .images) {
                    Label(vineyard.logoPath == nil ? "Add Logo" : "Change Logo",
                          systemImage: vineyard.logoPath == nil ? "photo.badge.plus" : "photo.badge.arrow.down")
                        .foregroundStyle(.primary)
                }
                .disabled(isWorking || isUploadingLogo)

                if vineyard.logoPath != nil {
                    Button(role: .destructive) {
                        showRemoveLogoConfirm = true
                    } label: {
                        Label("Remove Logo", systemImage: "trash")
                    }
                    .disabled(isWorking || isUploadingLogo)
                }
            }
        } header: {
            Text("Vineyard Logo")
        } footer: {
            if !accessControl.canChangeSettings {
                Text("Only owners and managers can change the vineyard logo.")
            } else {
                Text("The logo is shared across everyone with access to this vineyard.")
            }
        }
        .onChange(of: selectedLogoItem) { _, newItem in
            handleLogoSelection(newItem)
        }
        .alert("Remove Logo?", isPresented: $showRemoveLogoConfirm) {
            Button("Remove", role: .destructive) {
                Task { await removeLogo() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the logo for everyone in this vineyard.")
        }
    }

    private var logoStatusTitle: String {
        if vineyard.logoPath != nil && vineyard.logoData == nil {
            return "Loading logo…"
        }
        return vineyard.logoPath == nil ? "No logo" : "Logo set"
    }

    @ViewBuilder
    private var logoPreview: some View {
        if let data = vineyard.logoData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                .clipShape(.rect(cornerRadius: 10))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(VineyardTheme.leafGreen.opacity(0.15))
                    .frame(width: 64, height: 64)
                GrapeLeafIcon(size: 28, color: VineyardTheme.leafGreen)
            }
        }
    }

    private func handleLogoSelection(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { selectedLogoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                return
            }
            let maxSize: CGFloat = 512
            let scale = min(maxSize / uiImage.size.width, maxSize / uiImage.size.height, 1.0)
            let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let resized = renderer.image { _ in
                uiImage.draw(in: CGRect(origin: .zero, size: newSize))
            }
            guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return }
            await uploadLogo(jpeg)
        }
    }

    private func uploadLogo(_ jpeg: Data) async {
        isUploadingLogo = true
        defer { isUploadingLogo = false }
        do {
            let path = try await logoStorage.uploadLogo(vineyardId: vineyard.id, imageData: jpeg)
            let updatedAt = try await vineyardRepository.updateVineyardLogoPath(
                vineyardId: vineyard.id,
                logoPath: path
            )
            // Re-stamp the cache with the authoritative server timestamp so the
            // next sync doesn't think the cached copy is stale.
            SharedImageCache.shared.saveImageData(
                jpeg,
                for: .vineyardLogo(vineyardId: vineyard.id),
                remotePath: path,
                remoteUpdatedAt: updatedAt
            )
            var updated = vineyard
            updated.logoData = jpeg
            updated.logoPath = path
            updated.logoUpdatedAt = updatedAt
            store.upsertLocalVineyard(updated)
        } catch {
            errorMessage = "Could not upload logo: \(error.localizedDescription)"
        }
    }

    private func removeLogo() async {
        isUploadingLogo = true
        defer { isUploadingLogo = false }
        let existingPath = vineyard.logoPath
        do {
            _ = try await vineyardRepository.updateVineyardLogoPath(
                vineyardId: vineyard.id,
                logoPath: nil
            )
            if let existingPath {
                try? await logoStorage.deleteLogo(path: existingPath, vineyardId: vineyard.id)
            } else {
                SharedImageCache.shared.removeCachedImage(for: .vineyardLogo(vineyardId: vineyard.id))
            }
            var updated = vineyard
            updated.logoData = nil
            updated.logoPath = nil
            updated.logoUpdatedAt = nil
            store.upsertLocalVineyard(updated)
        } catch {
            errorMessage = "Could not remove logo: \(error.localizedDescription)"
        }
    }

    private func ensureLogoCached() async {
        guard let path = vineyard.logoPath else { return }
        let key = SharedImageCacheKey.vineyardLogo(vineyardId: vineyard.id)

        // Hydrate from disk cache first if needed — this avoids the empty
        // logo flash on cold launch before any sync has run.
        if vineyard.logoData == nil, let cached = SharedImageCache.shared.cachedImageData(for: key) {
            var updated = vineyard
            updated.logoData = cached
            store.upsertLocalVineyard(updated)
        }

        // Skip the network round-trip if the cache is already current.
        if SharedImageCache.shared.isCacheCurrent(
            for: key,
            remotePath: path,
            remoteUpdatedAt: vineyard.logoUpdatedAt
        ), vineyard.logoData != nil {
            return
        }

        do {
            let data = try await logoStorage.downloadLogo(
                path: path,
                vineyardId: vineyard.id,
                remoteUpdatedAt: vineyard.logoUpdatedAt
            )
            var updated = vineyard
            updated.logoData = data
            store.upsertLocalVineyard(updated)
        } catch {
            #if DEBUG
            print("[VineyardLogo] download failed:", error.localizedDescription)
            #endif
            // Keep showing whatever cached data we already have.
        }
    }

    private var infoSection: some View {
        Section {
            LabeledContent("Name", value: vineyard.name)
            LabeledContent("Created", value: vineyard.createdAt.formatted(date: .abbreviated, time: .omitted))

            Picker("Country", selection: $selectedCountry) {
                Text("Not Set").tag("")
                ForEach(Self.wineCountries, id: \.self) { c in
                    Text(c).tag(c)
                }
            }
            .disabled(!accessControl.canChangeSettings)
            .onChange(of: selectedCountry) { _, newValue in
                Task { await updateCountry(newValue) }
            }

            if accessControl.canChangeSettings {
                Button {
                    editedName = vineyard.name
                    showEditName = true
                } label: {
                    Label("Rename Vineyard", systemImage: "pencil")
                }
                .disabled(isWorking)
            }
        } header: {
            Text("Vineyard Info")
        } footer: {
            if !selectedCountry.isEmpty {
                Text("Chemical searches will prioritize products available in \(selectedCountry).")
            }
        }
    }

    private var isOwner: Bool {
        accessControl.currentRole == .owner
    }

    private var deleteWarningText: String {
        let others = max(0, memberCount - 1)
        if others > 0 {
            return "\(others) other member\(others == 1 ? "" : "s") will lose access to this vineyard. Shared blocks, pins, trips, sprays, and history will become inaccessible. This action is reversible only by support. Type DELETE to confirm."
        }
        return "This vineyard has no other members. It will be archived and removed from your selector. Type DELETE to confirm."
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                deleteConfirmationText = ""
                showDeleteConfirm = true
            } label: {
                Label("Archive Vineyard", systemImage: "archivebox")
            }
            .disabled(isWorking || !isOwner)
        } footer: {
            if isOwner {
                Text("Archiving hides this vineyard for everyone. Operational records are kept and can be restored by support if needed. Type DELETE to confirm.")
            } else {
                Text("Only the owner can archive this vineyard.")
            }
        }
    }

    private func rename() async {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }

        let backend = BackendVineyard(
            id: vineyard.id,
            name: trimmed,
            ownerId: nil,
            country: vineyard.country.isEmpty ? nil : vineyard.country,
            logoPath: vineyard.logoPath,
            logoUpdatedAt: vineyard.logoUpdatedAt,
            createdAt: nil,
            updatedAt: nil,
            deletedAt: nil
        )
        do {
            try await vineyardRepository.updateVineyard(backend)
            var updated = vineyard
            updated.name = trimmed
            store.upsertLocalVineyard(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateCountry(_ newValue: String) async {
        guard newValue != vineyard.country else { return }
        isWorking = true
        defer { isWorking = false }

        let backend = BackendVineyard(
            id: vineyard.id,
            name: vineyard.name,
            ownerId: nil,
            country: newValue.isEmpty ? nil : newValue,
            logoPath: vineyard.logoPath,
            logoUpdatedAt: vineyard.logoUpdatedAt,
            createdAt: nil,
            updatedAt: nil,
            deletedAt: nil
        )
        do {
            try await vineyardRepository.updateVineyard(backend)
            var updated = vineyard
            updated.country = newValue
            store.upsertLocalVineyard(updated)
        } catch {
            errorMessage = error.localizedDescription
            selectedCountry = vineyard.country
        }
    }

    private func loadMemberCount() async {
        let team = SupabaseTeamRepository()
        if let members = try? await team.listMembers(vineyardId: vineyard.id) {
            memberCount = members.count
        }
    }

    private func deleteVineyard() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await vineyardRepository.archiveVineyard(id: vineyard.id)
            let remaining = store.vineyards.filter { $0.id != vineyard.id }
            let mapped: [BackendVineyard] = remaining.map { local in
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
            }
            store.mapBackendVineyardsIntoLocal(mapped)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
