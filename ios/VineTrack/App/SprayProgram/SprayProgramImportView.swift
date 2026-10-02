import SwiftUI
import UniformTypeIdentifiers

/// Existing import CSV parser and importer, kept separate from reference exports.
struct SprayProgramImportView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var access
    @Environment(\.dismiss) private var dismiss
    @State private var isPicking: Bool = false
    @State private var result: SprayProgramCSVService.ImportResult?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section { Button("Choose Import CSV") { isPicking = true } }
                if let result {
                    Section("Preview — \(result.rows.count) records") {
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in Text(row.sprayName) }
                    }
                    Section("Warnings") {
                        ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in Text(warning.message) }
                    }
                    Button("Import CSV") {
                        guard access.canEditRecords else { return }
                        _ = SprayProgramCSVService.importRows(result.rows, into: store, paddocks: store.paddocks)
                        dismiss()
                    }
                    .disabled(!access.canEditRecords)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Import CSV")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(isPresented: $isPicking, allowedContentTypes: [.commaSeparatedText, .plainText]) { selection in
                do {
                    let url = try selection.get()
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    result = try SprayProgramCSVService.parseCSV(data: Data(contentsOf: url))
                    errorMessage = nil
                } catch { errorMessage = "Unable to read this CSV. Use Download Import CSV for the expected format." }
            }
        }
    }
}
