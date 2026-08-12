import SwiftUI

/// Clones + Rootstocks tabs of the Grape Varieties settings area (sql/182).
/// Shows the shared built-in catalogue plus this vineyard's custom records,
/// searchable, with block-allocation usage counts and drill-in detail sheets.
/// Built-in records are read-only; owner/manager can add and archive custom
/// records via the existing sql/182 RPCs. Mirrors the Android
/// `CloneRootstockCatalogScreens`.

// MARK: - Selection models

enum CloneCatalogueSelection: Identifiable {
    case builtin(SharedGrapeCloneCatalogEntry)
    case custom(VineyardGrapeCloneRow)

    var id: String {
        switch self {
        case .builtin(let e): return e.key
        case .custom(let r): return r.cloneKey
        }
    }
}

enum RootstockCatalogueSelection: Identifiable {
    case builtin(SharedRootstockCatalogEntry)
    case custom(VineyardRootstockRow)

    var id: String {
        switch self {
        case .builtin(let e): return e.key
        case .custom(let r): return r.rootstockKey
        }
    }
}

/// One block allocation using a clone/rootstock, for detail drill-ins.
struct CatalogueAllocationUsage: Identifiable {
    let id: UUID
    let blockName: String
    let detail: String
}

// MARK: - Shared helpers

@MainActor
private func varietyDisplayName(_ key: String, store: MigratedDataStore) -> String {
    if let builtin = BuiltInGrapeVarietyCatalog.entries.first(where: { $0.key == key }) {
        return builtin.name
    }
    let vid = store.selectedVineyardId
    if let row = store.grapeVarieties.first(where: { $0.key == key && (vid == nil || $0.vineyardId == vid) }) {
        return row.name
    }
    return key
}

@MainActor
private func cloneUsages(
    store: MigratedDataStore,
    entryKey: String,
    matchNames: [String]
) -> [CatalogueAllocationUsage] {
    store.paddocks.flatMap { paddock in
        paddock.varietyAllocations
            .filter {
                CloneRootstockBrowse.allocationUsesClone(
                    allocationCloneKey: $0.cloneKey,
                    allocationCloneText: $0.clone,
                    entryKey: entryKey,
                    matchNames: matchNames
                )
            }
            .map { alloc in
                CatalogueAllocationUsage(
                    id: alloc.id,
                    blockName: paddock.name,
                    detail: allocationDetail(alloc)
                )
            }
    }
}

@MainActor
private func rootstockUsages(
    store: MigratedDataStore,
    entryKey: String,
    matchNames: [String]
) -> [CatalogueAllocationUsage] {
    store.paddocks.flatMap { paddock in
        paddock.varietyAllocations
            .filter {
                CloneRootstockBrowse.allocationUsesRootstock(
                    allocationRootstockKey: $0.rootstockKey,
                    allocationRootstockText: $0.rootstock,
                    entryKey: entryKey,
                    matchNames: matchNames
                )
            }
            .map { alloc in
                CatalogueAllocationUsage(
                    id: alloc.id,
                    blockName: paddock.name,
                    detail: allocationDetail(alloc)
                )
            }
    }
}

private func allocationDetail(_ alloc: PaddockVarietyAllocation) -> String {
    var parts: [String] = []
    if let name = alloc.name, !name.isEmpty { parts.append(name) }
    if alloc.percent > 0 { parts.append("\(Int(alloc.percent))%") }
    return parts.joined(separator: " · ")
}

// MARK: - Clones tab

struct CloneCatalogueListView: View {
    @Environment(MigratedDataStore.self) private var store
    let canManage: Bool
    @Binding var showAddSheet: Bool

    @State private var search: String = ""
    @State private var varietyFilterKey: String?
    @State private var selection: CloneCatalogueSelection?

    private var catalog: CloneRootstockCatalogStore { .shared }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var builtinRows: [SharedGrapeCloneCatalogEntry] {
        CloneRootstockBrowse.systemClones(catalog.effectiveSystemClones, varietyKey: varietyFilterKey, query: trimmedSearch)
            .sorted {
                let l = varietyDisplayName($0.varietyKey, store: store)
                let r = varietyDisplayName($1.varietyKey, store: store)
                if l != r { return l.localizedCaseInsensitiveCompare(r) == .orderedAscending }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private var customRows: [VineyardGrapeCloneRow] {
        let vid = store.selectedVineyardId
        let scoped = catalog.customClones.filter { vid == nil || $0.vineyardId == vid }
        return CloneRootstockBrowse.customClones(scoped, varietyKey: varietyFilterKey, query: trimmedSearch)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Variety keys offered in the filter: everything with at least one clone.
    private var filterKeys: [String] {
        let vid = store.selectedVineyardId
        let keys = Set(catalog.effectiveSystemClones.filter { $0.isActive }.map { $0.varietyKey })
            .union(catalog.customClones.filter { $0.isActive && (vid == nil || $0.vineyardId == vid) }.map { $0.varietyKey })
        return keys.sorted {
            varietyDisplayName($0, store: store)
                .localizedCaseInsensitiveCompare(varietyDisplayName($1, store: store)) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                CatalogueSearchField(text: $search, prompt: "Search clones")
                Menu {
                    Button("All varieties") { varietyFilterKey = nil }
                    ForEach(filterKeys, id: \.self) { key in
                        Button(varietyDisplayName(key, store: store)) { varietyFilterKey = key }
                    }
                } label: {
                    HStack {
                        Image(systemName: "leaf")
                            .foregroundStyle(VineyardTheme.leafGreen)
                        Text(varietyFilterKey.map { varietyDisplayName($0, store: store) } ?? "All varieties")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if builtinRows.isEmpty && customRows.isEmpty {
                Section {
                    Text(trimmedSearch.isEmpty
                        ? "The shared clone catalogue is loading, or no clones match the selected variety."
                        : "No clones match “\(trimmedSearch)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !builtinRows.isEmpty {
                Section("Built-in · \(builtinRows.count)") {
                    ForEach(builtinRows) { entry in
                        CatalogueRow(
                            title: entry.displayName,
                            subtitle: cloneSubtitle(entry),
                            isCustom: false,
                            usageCount: cloneUsages(store: store, entryKey: entry.key, matchNames: CloneRootstockBrowse.cloneMatchNames(entry)).count
                        ) {
                            selection = .builtin(entry)
                        }
                    }
                }
            }

            if !customRows.isEmpty {
                Section("Custom — this vineyard · \(customRows.count)") {
                    ForEach(customRows, id: \.cloneKey) { row in
                        CatalogueRow(
                            title: row.displayName,
                            subtitle: "\(varietyDisplayName(row.varietyKey, store: store)) · Custom · this vineyard",
                            isCustom: true,
                            usageCount: cloneUsages(store: store, entryKey: row.cloneKey, matchNames: [row.displayName]).count
                        ) {
                            selection = .custom(row)
                        }
                    }
                }
            }

            Section {
            } footer: {
                Text("Built-in clones come from the shared catalogue and are read-only. Custom clones belong to this vineyard and sync to every member. “Mass selection” is recorded directly on block allocations — it is not a catalogue entry.")
            }
        }
        .sheet(item: $selection) { sel in
            CloneCatalogueDetailSheet(selection: sel, canManage: canManage)
        }
        .sheet(isPresented: $showAddSheet) {
            AddCustomCloneSheet()
        }
        .task {
            await catalog.refresh(vineyardId: store.selectedVineyardId)
        }
    }

    private func cloneSubtitle(_ entry: SharedGrapeCloneCatalogEntry) -> String {
        var parts: [String] = [varietyDisplayName(entry.varietyKey, store: store)]
        if let system = entry.selectionSystem { parts.append(system) }
        if let country = entry.sourceCountry { parts.append(country) }
        return parts.joined(separator: " · ")
    }
}

/// Detail drill-in for one clone: metadata, linked block allocations, and
/// archive (custom records, owner/manager only).
private struct CloneCatalogueDetailSheet: View {
    let selection: CloneCatalogueSelection
    let canManage: Bool

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmArchive: Bool = false
    @State private var isArchiving: Bool = false
    @State private var archiveError: String?

    private var catalog: CloneRootstockCatalogStore { .shared }

    private var title: String {
        switch selection {
        case .builtin(let e): return e.displayName
        case .custom(let r): return r.displayName
        }
    }

    private var isCustom: Bool {
        if case .custom = selection { return true }
        return false
    }

    private var metadata: [(String, String)] {
        switch selection {
        case .builtin(let e):
            var rows: [(String, String)] = [
                ("Variety", varietyDisplayName(e.varietyKey, store: store)),
                ("Clone code", e.cloneCode)
            ]
            if let system = e.selectionSystem { rows.append(("Selection system", system)) }
            if let country = e.sourceCountry { rows.append(("Source", country)) }
            if !e.aliases.isEmpty { rows.append(("Also known as", e.aliases.joined(separator: ", "))) }
            if let ref = e.sourceReference { rows.append(("Reference", ref)) }
            return rows
        case .custom(let r):
            return [
                ("Variety", varietyDisplayName(r.varietyKey, store: store)),
                ("Scope", "Custom · this vineyard")
            ]
        }
    }

    private var usages: [CatalogueAllocationUsage] {
        switch selection {
        case .builtin(let e):
            return cloneUsages(store: store, entryKey: e.key, matchNames: CloneRootstockBrowse.cloneMatchNames(e))
        case .custom(let r):
            return cloneUsages(store: store, entryKey: r.cloneKey, matchNames: [r.displayName])
        }
    }

    var body: some View {
        NavigationStack {
            CatalogueDetailList(
                badgeLabel: isCustom ? "Custom" : "Built-in",
                badgeColor: isCustom ? .orange : VineyardTheme.leafGreen,
                metadata: metadata,
                usages: usages,
                usageNoun: "clone",
                readOnlyNote: isCustom ? nil : "Built-in catalogue records are read-only.",
                archiveVisible: isCustom && canManage,
                isArchiving: isArchiving,
                archiveError: archiveError,
                onArchive: { confirmArchive = true }
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Archive this custom clone?",
                isPresented: $confirmArchive,
                titleVisibility: .visible
            ) {
                Button("Archive", role: .destructive) {
                    Task { await archive() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It will be hidden from pickers and this list. Blocks that already use it keep their records.")
            }
        }
    }

    private func archive() async {
        guard case .custom(let row) = selection, let vid = store.selectedVineyardId else { return }
        isArchiving = true
        defer { isArchiving = false }
        archiveError = nil
        do {
            _ = try await catalog.archiveCustomClone(id: row.id, vineyardId: vid)
            dismiss()
        } catch {
            archiveError = "Couldn't archive this clone. Check your connection and try again."
        }
    }
}

/// Owner/manager sheet creating a vineyard-scoped custom clone through the
/// sql/182 `upsert_vineyard_grape_clone` RPC. A clone always belongs to one
/// variety, so a variety selection is required.
private struct AddCustomCloneSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var varietyKey: String?
    @State private var name: String = ""
    @State private var isSaving: Bool = false
    @State private var saveError: String?

    private var catalog: CloneRootstockCatalogStore { .shared }

    /// Varieties this vineyard can attach a clone to — anything with a
    /// stable key (built-in catalogue key or the vineyard's `custom:` key).
    private var varietyOptions: [GrapeVariety] {
        let vid = store.selectedVineyardId
        return store.grapeVarieties
            .filter { $0.key != nil && (vid == nil || $0.vineyardId == vid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Variety") {
                    Menu {
                        ForEach(varietyOptions) { variety in
                            Button(variety.name) { varietyKey = variety.key }
                        }
                    } label: {
                        HStack {
                            Text(varietyKey.map { varietyDisplayName($0, store: store) } ?? "Select variety")
                                .foregroundStyle(varietyKey == nil ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    TextField("e.g. BVRC 17", text: $name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Clone name / code")
                } footer: {
                    Text("Saved to this vineyard under the selected variety and synced to every member. A clone always belongs to one variety.")
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Custom Clone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(varietyKey == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }

    private func save() async {
        guard let vid = store.selectedVineyardId, let varietyKey else { return }
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        do {
            _ = try await catalog.addCustomClone(
                vineyardId: vid,
                varietyKey: varietyKey,
                displayName: name.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            saveError = "Couldn't save this clone. You need owner/manager access and a connection — reserved or duplicate names are also rejected."
        }
    }
}

// MARK: - Rootstocks tab

struct RootstockCatalogueListView: View {
    @Environment(MigratedDataStore.self) private var store
    let canManage: Bool
    @Binding var showAddSheet: Bool

    @State private var search: String = ""
    @State private var selection: RootstockCatalogueSelection?

    private var catalog: CloneRootstockCatalogStore { .shared }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var builtinRows: [SharedRootstockCatalogEntry] {
        CloneRootstockBrowse.systemRootstocks(catalog.effectiveSystemRootstocks, query: trimmedSearch)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var customRows: [VineyardRootstockRow] {
        let vid = store.selectedVineyardId
        let scoped = catalog.customRootstocks.filter { vid == nil || $0.vineyardId == vid }
        return CloneRootstockBrowse.customRootstocks(scoped, query: trimmedSearch)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                CatalogueSearchField(text: $search, prompt: "Search rootstocks")
            }

            if builtinRows.isEmpty && customRows.isEmpty {
                Section {
                    Text(trimmedSearch.isEmpty
                        ? "The shared rootstock catalogue is loading."
                        : "No rootstocks match “\(trimmedSearch)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !builtinRows.isEmpty {
                Section("Built-in · \(builtinRows.count)") {
                    ForEach(builtinRows) { entry in
                        CatalogueRow(
                            title: entry.displayName,
                            subtitle: rootstockSubtitle(entry),
                            isCustom: false,
                            usageCount: rootstockUsages(store: store, entryKey: entry.key, matchNames: CloneRootstockBrowse.rootstockMatchNames(entry)).count
                        ) {
                            selection = .builtin(entry)
                        }
                    }
                }
            }

            if !customRows.isEmpty {
                Section("Custom — this vineyard · \(customRows.count)") {
                    ForEach(customRows, id: \.rootstockKey) { row in
                        CatalogueRow(
                            title: row.displayName,
                            subtitle: "Custom · this vineyard",
                            isCustom: true,
                            usageCount: rootstockUsages(store: store, entryKey: row.rootstockKey, matchNames: [row.displayName]).count
                        ) {
                            selection = .custom(row)
                        }
                    }
                }
            }

            Section {
            } footer: {
                Text("Built-in rootstocks come from the shared catalogue and are read-only. Custom rootstocks belong to this vineyard and sync to every member. “Own roots / ungrafted” is recorded directly on block allocations — it is not a catalogue entry.")
            }
        }
        .sheet(item: $selection) { sel in
            RootstockCatalogueDetailSheet(selection: sel, canManage: canManage)
        }
        .sheet(isPresented: $showAddSheet) {
            AddCustomRootstockSheet()
        }
        .task {
            await catalog.refresh(vineyardId: store.selectedVineyardId)
        }
    }

    private func rootstockSubtitle(_ entry: SharedRootstockCatalogEntry) -> String {
        var parts: [String] = []
        if let parentage = entry.parentage { parts.append(parentage) }
        if !entry.aliases.isEmpty { parts.append("aka \(entry.aliases.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

private struct RootstockCatalogueDetailSheet: View {
    let selection: RootstockCatalogueSelection
    let canManage: Bool

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmArchive: Bool = false
    @State private var isArchiving: Bool = false
    @State private var archiveError: String?

    private var catalog: CloneRootstockCatalogStore { .shared }

    private var title: String {
        switch selection {
        case .builtin(let e): return e.displayName
        case .custom(let r): return r.displayName
        }
    }

    private var isCustom: Bool {
        if case .custom = selection { return true }
        return false
    }

    private var metadata: [(String, String)] {
        switch selection {
        case .builtin(let e):
            var rows: [(String, String)] = []
            if let parentage = e.parentage { rows.append(("Parentage", parentage)) }
            if !e.aliases.isEmpty { rows.append(("Also known as", e.aliases.joined(separator: ", "))) }
            if let ref = e.sourceReference { rows.append(("Reference", ref)) }
            return rows
        case .custom:
            return [("Scope", "Custom · this vineyard")]
        }
    }

    private var usages: [CatalogueAllocationUsage] {
        switch selection {
        case .builtin(let e):
            return rootstockUsages(store: store, entryKey: e.key, matchNames: CloneRootstockBrowse.rootstockMatchNames(e))
        case .custom(let r):
            return rootstockUsages(store: store, entryKey: r.rootstockKey, matchNames: [r.displayName])
        }
    }

    var body: some View {
        NavigationStack {
            CatalogueDetailList(
                badgeLabel: isCustom ? "Custom" : "Built-in",
                badgeColor: isCustom ? .orange : .indigo,
                metadata: metadata,
                usages: usages,
                usageNoun: "rootstock",
                readOnlyNote: isCustom ? nil : "Built-in catalogue records are read-only.",
                archiveVisible: isCustom && canManage,
                isArchiving: isArchiving,
                archiveError: archiveError,
                onArchive: { confirmArchive = true }
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Archive this custom rootstock?",
                isPresented: $confirmArchive,
                titleVisibility: .visible
            ) {
                Button("Archive", role: .destructive) {
                    Task { await archive() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It will be hidden from pickers and this list. Blocks that already use it keep their records.")
            }
        }
    }

    private func archive() async {
        guard case .custom(let row) = selection, let vid = store.selectedVineyardId else { return }
        isArchiving = true
        defer { isArchiving = false }
        archiveError = nil
        do {
            _ = try await catalog.archiveCustomRootstock(id: row.id, vineyardId: vid)
            dismiss()
        } catch {
            archiveError = "Couldn't archive this rootstock. Check your connection and try again."
        }
    }
}

private struct AddCustomRootstockSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var isSaving: Bool = false
    @State private var saveError: String?

    private var catalog: CloneRootstockCatalogStore { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Trial Stock 7", text: $name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Rootstock name")
                } footer: {
                    Text("Saved to this vineyard and synced to every member. Names that duplicate a built-in rootstock are rejected — pick the catalogue record instead.")
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Custom Rootstock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }

    private func save() async {
        guard let vid = store.selectedVineyardId else { return }
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        do {
            _ = try await catalog.addCustomRootstock(
                vineyardId: vid,
                displayName: name.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            saveError = "Couldn't save this rootstock. You need owner/manager access and a connection — reserved names and duplicates of built-ins are rejected."
        }
    }
}

// MARK: - Shared subviews

private struct CatalogueSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct CatalogueRow: View {
    let title: String
    let subtitle: String
    let isCustom: Bool
    let usageCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(isCustom ? "Custom" : "Built-in")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isCustom ? Color.orange : VineyardTheme.leafGreen)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((isCustom ? Color.orange : VineyardTheme.leafGreen).opacity(0.15), in: .capsule)
                    }
                    Text(subtitleLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var subtitleLine: String {
        let usage = usageCount == 0 ? "No allocations" : "\(usageCount) allocation\(usageCount == 1 ? "" : "s")"
        return subtitle.isEmpty ? usage : "\(subtitle) · \(usage)"
    }
}

private struct CatalogueDetailList: View {
    let badgeLabel: String
    let badgeColor: Color
    let metadata: [(String, String)]
    let usages: [CatalogueAllocationUsage]
    let usageNoun: String
    let readOnlyNote: String?
    let archiveVisible: Bool
    let isArchiving: Bool
    let archiveError: String?
    let onArchive: () -> Void

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Type")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(badgeLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badgeColor.opacity(0.15), in: .capsule)
                }
                ForEach(metadata, id: \.0) { row in
                    HStack(alignment: .top) {
                        Text(row.0)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.1)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.subheadline)
                }
            }

            Section {
                if usages.isEmpty {
                    Text("No block allocations currently use this \(usageNoun).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(usages) { usage in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(usage.blockName)
                                .font(.subheadline.weight(.semibold))
                            if !usage.detail.isEmpty {
                                Text(usage.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Linked blocks · \(usages.count)")
            } footer: {
                if let readOnlyNote {
                    Text(readOnlyNote)
                }
            }

            if archiveVisible {
                Section {
                    Button(role: .destructive, action: onArchive) {
                        HStack {
                            if isArchiving {
                                ProgressView()
                            } else {
                                Image(systemName: "archivebox")
                            }
                            Text("Archive Custom Record")
                        }
                    }
                    .disabled(isArchiving)
                } footer: {
                    if let archiveError {
                        Text(archiveError)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}
