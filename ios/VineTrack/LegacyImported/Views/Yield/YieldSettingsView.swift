import SwiftUI

struct YieldSettingsView: View {
    @Environment(MigratedDataStore.self) private var store
    var body: some View {
        YieldBunchWeightsContent()
            .id("\(YieldMasterWeightCache.shared.scopeIdentity)/\(store.selectedVineyardId?.uuidString ?? "none")")
    }
}

private struct YieldBunchWeightsContent: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var access
    @State private var rows: [YieldBunchWeightRow]?
    @State private var expanded: Set<String> = []
    @State private var editor: EditTarget?
    @State private var pendingDelete: YieldBunchWeightRow?
    @State private var message: String?
    @State private var busy = false
    private let repository = YieldBunchWeightsRepository()
    private struct EditTarget: Identifiable {
        let key: String
        let name: String
        let block: UUID?
        let blockName: String?
        let grams: Double?
        let vineyard: UUID?
        let identity: String
        var id: String { key + (block?.uuidString ?? "master") }
    }
    private var canEdit: Bool {
        access.loadedVineyardId == store.selectedVineyardId && access.canManageBunchWeights
    }
    private var plantings: [CurrentYieldEstimate.Planting] {
        var keys = Set<String>()
        return store.orderedPaddocks.flatMap { CurrentYieldEstimate.plantings($0) }
            .filter { !$0.key.isEmpty && keys.insert($0.key).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        List {
            Section {
                Text("Shared variety masters apply to every planted block unless a block override is set. Weights are grams per bunch; no default is assumed.")
                    .font(.caption).foregroundStyle(.secondary)
                if !canEdit { Text("Owners, Managers and Supervisors can change shared bunch weights.").font(.caption).foregroundStyle(.secondary) }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("yield.weights.status") }
                Button("Refresh shared weights") { Task { await reload() } }.disabled(busy)
                if busy { ProgressView() }
            }
            if plantings.isEmpty {
                Section { Text("Add varieties to your planted blocks to configure bunch weights.").foregroundStyle(.secondary) }
            }
            ForEach(plantings, id: \.key) { planting in
                Section {
                    let master = rows?.first { $0.paddockId == nil && $0.varietyKey == planting.key }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(planting.name).font(.headline)
                            Text(planting.key).font(.caption).foregroundStyle(.secondary)
                            Text(master.map { String(format: "%.1f g · Variety master", $0.grams) } ?? (rows == nil ? "Not confirmed" : "Not configured"))
                                .font(.subheadline)
                        }
                        Spacer()
                        if canEdit {
                            Button(master == nil ? "Set" : "Edit") {
                                editor = EditTarget(key: planting.key, name: planting.name, block: nil, blockName: nil, grams: master?.grams, vineyard: store.selectedVineyardId, identity: YieldMasterWeightCache.shared.scopeIdentity)
                            }.buttonStyle(.borderless).disabled(busy || rows == nil)
                        }
                    }
                    if let master, canEdit {
                        Button("Remove variety master", role: .destructive) { pendingDelete = master }.disabled(busy)
                    }
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(planting.key) }, set: { if $0 { expanded.insert(planting.key) } else { expanded.remove(planting.key) } })) {
                        ForEach(store.orderedPaddocks.filter { CurrentYieldEstimate.plantings($0).contains { $0.key == planting.key } }) { block in
                            let override = rows?.first { $0.paddockId == block.id && $0.varietyKey == planting.key }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(block.name).font(.subheadline.weight(.semibold))
                                Text(override.map { String(format: "%.1f g · Block override", $0.grams) }
                                    ?? master.map { String(format: "%.1f g · Inherited variety master", $0.grams) }
                                    ?? (rows == nil ? "Not confirmed" : "Not configured"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if canEdit {
                                    HStack {
                                        Button(override == nil ? "Set override" : "Edit override") {
                                            editor = EditTarget(key: planting.key, name: planting.name, block: block.id, blockName: block.name, grams: override?.grams, vineyard: store.selectedVineyardId, identity: YieldMasterWeightCache.shared.scopeIdentity)
                                        }
                                        if let override { Button("Remove override", role: .destructive) { pendingDelete = override } }
                                    }.buttonStyle(.borderless).disabled(busy || rows == nil)
                                }
                            }.padding(.vertical, 4)
                        }
                    } label: { Text("Planted blocks & overrides").font(.subheadline) }
                }
            }
        }
        .navigationTitle("Bunch Weights")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let vineyard = store.selectedVineyardId { rows = repository.cached(vineyard: vineyard) }
            await reload()
        }
        .refreshable { await reload() }
        .sheet(item: $editor) { target in
            YieldBunchWeightEditor(name: target.name, block: target.blockName, initial: target.grams, confirmed: rows?.first { $0.varietyKey == target.key && $0.paddockId == target.block }.map { "Latest confirmed: \($0.grams) g" } ?? (rows == nil ? "Not confirmed" : "Not configured"), refresh: { await reload() }) { grams in
                guard let vineyard = target.vineyard, store.selectedVineyardId == vineyard,
                      target.identity == YieldMasterWeightCache.shared.scopeIdentity, canEdit else { throw CancellationError() }
                try await repository.save(vineyard: vineyard, block: target.block, key: target.key, name: target.name, grams: grams)
                await reload(afterMutation: true)
            }
        }
        .confirmationDialog("Remove shared bunch weight?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let row = pendingDelete, canEdit, row.vineyardId == store.selectedVineyardId else { return }
                let origin = YieldMasterWeightCache.shared.scopeIdentity
                Task {
                    guard origin == YieldMasterWeightCache.shared.scopeIdentity, row.vineyardId == store.selectedVineyardId, canEdit else { return }
                    busy = true
                    defer { busy = false }
                    do { try await repository.remove(row); await reload(afterMutation: true) }
                    catch { message = "Removal not confirmed. Refresh before retrying; the last confirmed weights are retained." }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("Removing an override restores the variety master. Without a master, the weight becomes Not configured.") }
    }
    private func reload(afterMutation: Bool = false) async {
        guard let vineyard = store.selectedVineyardId, !Task.isCancelled else { return }
        let origin = YieldMasterWeightCache.shared.scopeIdentity
        busy = true
        defer { busy = false }
        do {
            let fresh = try await repository.fetch(vineyard: vineyard)
            guard !Task.isCancelled, store.selectedVineyardId == vineyard, origin == YieldMasterWeightCache.shared.scopeIdentity else { return }
            rows = fresh
            YieldMasterWeightCache.shared.installConfirmedRows(fresh, vineyardId: vineyard, paddocks: store.paddocks)
            message = "Shared weights refreshed. Changes apply to current estimates, not historical trip evidence."
        } catch {
            guard !Task.isCancelled, store.selectedVineyardId == vineyard, origin == YieldMasterWeightCache.shared.scopeIdentity else { return }
            message = afterMutation
                ? "Change confirmed by the server, but the list could not refresh. Last confirmed list retained; refresh before making another change."
                : "Could not refresh. Showing only last server-confirmed weights; no offline changes are queued."
        }
    }
}

private struct YieldBunchWeightEditor: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let block: String?
    let initial: Double?
    let confirmed: String
    let refresh: () async -> Void
    let save: (Double) async throws -> Void
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?
    private var grams: Double? {
        Double(input.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite && $0 > 0 && $0 <= 5000 ? $0 : nil }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(block ?? "Vineyard variety master") {
                    Text(name)
                    Text(confirmed).font(.caption).foregroundStyle(.secondary)
                    TextField("Grams per bunch", text: $input).keyboardType(.decimalPad)
                    Text("Enter more than 0 and at most 5,000 g.").font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Section {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Button("Refresh shared weights without discarding entry") {
                            busy = true
                            Task { await refresh(); busy = false }
                        }.disabled(busy)
                    }
                }
                if busy { ProgressView("Saving shared weight…") }
            }
            .navigationTitle(block == nil ? "Variety master" : "Block override")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let grams else { return }
                        busy = true
                        Task {
                            defer { busy = false }
                            do { try await save(grams); dismiss() }
                            catch { self.error = "Save not confirmed. Your entry is retained. Refresh shared weights before retrying; a lost response may already have been applied." }
                        }
                    }.disabled(busy || grams == nil)
                }
            }
            .interactiveDismissDisabled(busy)
            .onAppear { if let initial { input = String(initial) } }
        }
    }
}
