import SwiftUI
import UniformTypeIdentifiers

struct BlocksHubView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @State private var showAddPaddock: Bool = false
    @State private var paddockToEdit: Paddock?
    @State private var shareURL: ShareURL?
    @State private var showImporter: Bool = false
    @State private var importSummary: PaddockJSONService.ImportSummary?
    @State private var importErrorMessage: String?
    @State private var archiveCandidate: Paddock?
    @State private var permanentDeleteCandidate: Paddock?
    @State private var referenceCheck: ReferenceCheckState = .idle
    @State private var actionError: String?

    private let repository: any PaddockSyncRepositoryProtocol = SupabasePaddockSyncRepository()

    private enum ReferenceCheckState: Equatable {
        case idle
        case loading(UUID)
        case loaded(UUID, PaddockReferenceCounts)
        case failed(UUID, String)
    }

    var body: some View {
        contentView
            .modifier(BlocksHubChromeModifier(
                showAddPaddock: $showAddPaddock,
                paddockToEdit: $paddockToEdit,
                shareURL: $shareURL,
                showImporter: $showImporter,
                importSummary: $importSummary,
                importErrorMessage: $importErrorMessage,
                paddocksEmpty: store.paddocks.isEmpty,
                canCreate: accessControl.canCreateOperationalRecords,
                canExport: accessControl.canExport,
                canChangeSettings: accessControl.canChangeSettings,
                onExport: exportPaddocks,
                onImport: handleImportResult
            ))
            .confirmationDialog(
                archiveDialogTitle,
                isPresented: archiveDialogBinding,
                presenting: archiveCandidate,
                actions: { paddock in archiveDialogActions(for: paddock) },
                message: { _ in Text(archiveDialogMessage) }
            )
            .confirmationDialog(
                permanentDeleteDialogTitle,
                isPresented: permanentDeleteDialogBinding,
                presenting: permanentDeleteCandidate,
                actions: { paddock in permanentDeleteDialogActions(for: paddock) },
                message: { _ in Text("This block has no linked records. Permanent deletion cannot be undone.") }
            )
            .alert("Action Failed", isPresented: actionErrorBinding, presenting: actionError) { _ in
                Button("OK", role: .cancel) { actionError = nil }
            } message: { message in
                Text(message)
            }
    }

    @ViewBuilder
    private var contentView: some View {
        Group {
            if store.paddocks.isEmpty {
                VineyardEmptyStateView(
                    icon: "square.grid.2x2",
                    title: "No blocks yet",
                    message: "Create your first block to start mapping rows.",
                    actionTitle: accessControl.canCreateOperationalRecords ? "Add Block" : nil,
                    action: accessControl.canCreateOperationalRecords ? { showAddPaddock = true } : nil as (() -> Void)?
                )
            } else {
                paddockList
            }
        }
    }

    @ViewBuilder
    private func archiveDialogActions(for paddock: Paddock) -> some View {
        Button("Archive block", role: .destructive) {
            archive(paddock)
        }
        if case .loaded(let id, let counts) = referenceCheck,
           id == paddock.id,
           counts.isEmpty {
            Button("Delete permanently", role: .destructive) {
                permanentDeleteCandidate = paddock
                archiveCandidate = nil
            }
        }
        Button("Cancel", role: .cancel) {
            archiveCandidate = nil
            referenceCheck = .idle
        }
    }

    @ViewBuilder
    private func permanentDeleteDialogActions(for paddock: Paddock) -> some View {
        Button("Delete permanently", role: .destructive) {
            permanentlyDelete(paddock)
        }
        Button("Cancel", role: .cancel) {
            permanentDeleteCandidate = nil
        }
    }



    private var archiveDialogBinding: Binding<Bool> {
        Binding(
            get: { archiveCandidate != nil },
            set: { if !$0 { archiveCandidate = nil; referenceCheck = .idle } }
        )
    }

    private var permanentDeleteDialogBinding: Binding<Bool> {
        Binding(
            get: { permanentDeleteCandidate != nil },
            set: { if !$0 { permanentDeleteCandidate = nil } }
        )
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private var archiveDialogTitle: String {
        if let name = archiveCandidate?.name {
            return "Archive \(name)?"
        }
        return "Archive block?"
    }

    private var permanentDeleteDialogTitle: String {
        if let name = permanentDeleteCandidate?.name {
            return "Delete \(name) permanently?"
        }
        return "Delete permanently?"
    }

    private var archiveDialogMessage: String {
        guard let paddock = archiveCandidate else { return "" }
        switch referenceCheck {
        case .loading(let id) where id == paddock.id:
            return "Checking for linked records…"
        case .loaded(let id, let counts) where id == paddock.id:
            if counts.isEmpty {
                return "This block has no linked records. You can archive it, or delete it permanently."
            }
            let preview = counts.summaryLines.prefix(4).joined(separator: ", ")
            return "This block has linked records (\(preview)). Archiving keeps it available for historical reports but hides it from active selectors."
        case .failed(let id, let message) where id == paddock.id:
            return "Couldn't check linked records (\(message)). Archiving keeps the block available for historical reports."
        default:
            return "Archiving keeps this block available for historical reports but hides it from active selectors."
        }
    }

    private var paddockList: some View {
        List {
            ForEach(store.paddocks) { paddock in
                Button {
                    paddockToEdit = paddock
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(VineyardTheme.leafGreen.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: "square.grid.2x2.fill")
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(paddock.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("\(paddock.rows.count) rows")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .onDelete { offsets in
                guard accessControl.canDeleteOperationalRecords else { return }
                promptArchive(at: offsets)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func promptArchive(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        let paddock = store.paddocks[index]
        archiveCandidate = paddock
        referenceCheck = .loading(paddock.id)
        Task { await loadReferenceCounts(for: paddock.id) }
    }

    private func loadReferenceCounts(for paddockId: UUID) async {
        do {
            let counts = try await repository.paddockReferenceCounts(id: paddockId)
            if archiveCandidate?.id == paddockId {
                referenceCheck = .loaded(paddockId, counts)
            }
        } catch {
            if archiveCandidate?.id == paddockId {
                referenceCheck = .failed(paddockId, error.localizedDescription)
            }
        }
    }

    private func archive(_ paddock: Paddock) {
        store.deletePaddock(paddock.id)
        archiveCandidate = nil
        referenceCheck = .idle
    }

    private func permanentlyDelete(_ paddock: Paddock) {
        Task {
            do {
                try await repository.hardDeletePaddock(id: paddock.id)
                store.applyRemotePaddockDelete(paddock.id)
                permanentDeleteCandidate = nil
                referenceCheck = .idle
            } catch {
                actionError = error.localizedDescription
                permanentDeleteCandidate = nil
            }
        }
    }

    // MARK: - Import / Export

    private func exportPaddocks() {
        let data = PaddockJSONService.generateJSON(paddocks: store.paddocks, vineyardId: store.selectedVineyardId)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: Date())
        let vineyardName = store.selectedVineyard?.name ?? "Vineyard"
        let safeName = vineyardName.replacingOccurrences(of: " ", with: "_")
        let url = PaddockJSONService.saveJSONToTemp(data: data, fileName: "\(safeName)_blocks_\(dateString).json")
        shareURL = ShareURL(url: url)
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importPaddocks(from: url)
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        }
    }

    private func importPaddocks(from url: URL) {
        guard let vineyardId = store.selectedVineyardId else {
            importErrorMessage = "Select a vineyard before importing."
            return
        }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let existing = store.paddocks
            let result = try PaddockJSONService.parseJSON(data: data, vineyardId: vineyardId, existing: existing)
            let existingIds = Set(existing.map(\.id))
            for paddock in result.paddocks {
                if existingIds.contains(paddock.id) {
                    store.updatePaddock(paddock)
                } else {
                    store.addPaddock(paddock)
                }
            }
            importSummary = result.summary
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Chrome modifier (extracted to keep the body type-checker happy)

private struct BlocksHubChromeModifier: ViewModifier {
    @Binding var showAddPaddock: Bool
    @Binding var paddockToEdit: Paddock?
    @Binding var shareURL: ShareURL?
    @Binding var showImporter: Bool
    @Binding var importSummary: PaddockJSONService.ImportSummary?
    @Binding var importErrorMessage: String?
    let paddocksEmpty: Bool
    let canCreate: Bool
    let canExport: Bool
    let canChangeSettings: Bool
    let onExport: () -> Void
    let onImport: (Result<[URL], Error>) -> Void

    private var importSummaryBinding: Binding<Bool> {
        Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(get: { importErrorMessage != nil }, set: { if !$0 { importErrorMessage = nil } })
    }

    func body(content: Content) -> some View {
        content
            .navigationTitle("Blocks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canCreate {
                            Button {
                                showAddPaddock = true
                            } label: {
                                Label("Add Block", systemImage: "plus")
                            }
                        }
                        if canExport && !paddocksEmpty {
                            Button {
                                onExport()
                            } label: {
                                Label("Export Blocks (JSON)", systemImage: "square.and.arrow.up")
                            }
                        }
                        if canChangeSettings {
                            Button {
                                showImporter = true
                            } label: {
                                Label("Import Blocks (JSON)", systemImage: "square.and.arrow.down")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showAddPaddock) {
                EditPaddockSheet(paddock: nil)
            }
            .sheet(item: $paddockToEdit) { paddock in
                EditPaddockSheet(paddock: paddock)
            }
            .sheet(item: $shareURL) { wrapper in
                ShareSheet(items: [wrapper.url])
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json, UTType(filenameExtension: "json") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                onImport(result)
            }
            .alert("Import Complete", isPresented: importSummaryBinding, presenting: importSummary) { _ in
                Button("OK", role: .cancel) { importSummary = nil }
            } message: { summary in
                Text(Self.summaryMessage(summary))
            }
            .alert("Import Failed", isPresented: importErrorBinding, presenting: importErrorMessage) { _ in
                Button("OK", role: .cancel) { importErrorMessage = nil }
            } message: { message in
                Text(message)
            }
    }

    private static func summaryMessage(_ summary: PaddockJSONService.ImportSummary) -> String {
        var lines: [String] = [
            "Created: \(summary.created)",
            "Updated: \(summary.updated)",
            "Skipped: \(summary.skipped)"
        ]
        if !summary.errors.isEmpty {
            lines.append("")
            lines.append(contentsOf: summary.errors.prefix(5))
            if summary.errors.count > 5 {
                lines.append("…and \(summary.errors.count - 5) more")
            }
        }
        return lines.joined(separator: "\n")
    }
}
