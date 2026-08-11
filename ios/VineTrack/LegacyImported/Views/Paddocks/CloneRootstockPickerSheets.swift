import SwiftUI

/// Identifies which allocation a clone/rootstock picker is editing, plus
/// the context the picker needs (variety scope + current selection).
struct AllocationCatalogPickerTarget: Identifiable {
    /// The allocation id being edited.
    let id: UUID
    /// Stable variety key when resolvable (`shiraz`, `custom:<vid>:<slug>`).
    /// nil when the allocation's variety is local-only/unresolved — the
    /// clone picker then falls back to free-text entry.
    let varietyKey: String?
    let varietyName: String
    let currentKey: String?
    let currentText: String?
}

// MARK: - Clone picker

/// Searchable clone selector for ONE variety allocation. Options are the
/// shared system catalogue (filtered to the allocation's variety), the
/// vineyard's custom clones for that variety, the `mass_selection`
/// sentinel, "Not specified", and a custom-add action. Legacy free-text
/// values are preserved via an explicit "Keep" row — never auto-mapped.
struct ClonePickerSheet: View {
    let target: AllocationCatalogPickerTarget
    let vineyardId: UUID?
    /// (cloneKey, displaySnapshot) — both nil clears the selection.
    let onSelect: (String?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""
    @State private var isAddingCustom: Bool = false
    @State private var customError: String?

    private var catalog: CloneRootstockCatalogStore { .shared }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var systemOptions: [SharedGrapeCloneCatalogEntry] {
        guard let key = target.varietyKey else { return [] }
        let all = catalog.systemClones(forVarietyKey: key)
        guard !trimmedSearch.isEmpty else { return all }
        let q = trimmedSearch
        return all.filter { e in
            e.displayName.localizedCaseInsensitiveContains(q)
                || e.cloneCode.localizedCaseInsensitiveContains(q)
                || e.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private var customOptions: [VineyardGrapeCloneRow] {
        guard let key = target.varietyKey else { return [] }
        let all = catalog.customClones(forVarietyKey: key)
        guard !trimmedSearch.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    /// Legacy free-text value with no catalogue key — always preserved.
    private var legacyText: String? {
        guard target.currentKey == nil,
              let t = target.currentText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        return t
    }

    private var canOfferCustomAdd: Bool {
        guard !trimmedSearch.isEmpty, target.varietyKey != nil, vineyardId != nil else { return false }
        let canonical = BuiltInGrapeVarietyCatalog.canonical(trimmedSearch)
        let inSystem = systemOptions.contains {
            BuiltInGrapeVarietyCatalog.canonical($0.displayName) == canonical
                || BuiltInGrapeVarietyCatalog.canonical($0.cloneCode) == canonical
        }
        let inCustom = customOptions.contains {
            BuiltInGrapeVarietyCatalog.canonical($0.displayName) == canonical
        }
        return !inSystem && !inCustom
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    optionRow(
                        title: "Not specified",
                        subtitle: "Clone unknown / not recorded",
                        isSelected: target.currentKey == nil && legacyText == nil
                    ) {
                        select(key: nil, text: nil)
                    }
                    optionRow(
                        title: CloneRootstockSentinels.massSelectionDisplay,
                        subtitle: "No certified clone — mass-selected planting material",
                        isSelected: target.currentKey == CloneRootstockSentinels.massSelectionKey
                    ) {
                        select(
                            key: CloneRootstockSentinels.massSelectionKey,
                            text: CloneRootstockSentinels.massSelectionDisplay
                        )
                    }
                }

                if let legacy = legacyText {
                    Section("Current entry") {
                        optionRow(
                            title: "Keep “\(legacy)”",
                            subtitle: "Existing entry, kept as typed",
                            isSelected: true
                        ) {
                            select(key: nil, text: legacy)
                        }
                    }
                }

                if target.varietyKey != nil {
                    if !systemOptions.isEmpty {
                        Section("Catalogue — \(target.varietyName)") {
                            ForEach(systemOptions) { entry in
                                optionRow(
                                    title: entry.displayName,
                                    subtitle: [entry.selectionSystem, entry.sourceCountry]
                                        .compactMap { $0 }
                                        .joined(separator: " · "),
                                    isSelected: target.currentKey == entry.key
                                ) {
                                    select(key: entry.key, text: entry.displayName)
                                }
                            }
                        }
                    }

                    if !customOptions.isEmpty {
                        Section("My clones") {
                            ForEach(customOptions) { row in
                                optionRow(
                                    title: row.displayName,
                                    subtitle: "Custom · this vineyard",
                                    isSelected: target.currentKey == row.cloneKey
                                ) {
                                    select(key: row.cloneKey, text: row.displayName)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text("This variety isn't in the shared catalogue yet, so catalogue clones can't be attached. You can still record the clone as text below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if canOfferCustomAdd {
                    Section {
                        Button {
                            Task { await addCustomClone(named: trimmedSearch) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add “\(trimmedSearch)” as custom clone")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(VineyardTheme.info)
                                    Text("Saved to this vineyard under \(target.varietyName) and synced to all devices.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isAddingCustom {
                                    ProgressView()
                                } else {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(VineyardTheme.info)
                                }
                            }
                        }
                        .disabled(isAddingCustom)
                    } footer: {
                        if let err = customError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                } else if !trimmedSearch.isEmpty && target.varietyKey == nil {
                    Section {
                        Button {
                            select(key: nil, text: trimmedSearch)
                        } label: {
                            Text("Use “\(trimmedSearch)” as text")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(VineyardTheme.info)
                        }
                    }
                }
            }
            .navigationTitle("Clone — \(target.varietyName)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search clones")
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await catalog.refresh(vineyardId: vineyardId)
            }
        }
    }

    private func select(key: String?, text: String?) {
        onSelect(key, text)
        dismiss()
    }

    /// Create a vineyard-scoped custom clone through the shared catalogue
    /// RPC. On failure (offline / below manager role) the entry degrades to
    /// preserved free text so the user is never blocked.
    private func addCustomClone(named raw: String) async {
        guard let vid = vineyardId, let varietyKey = target.varietyKey, !isAddingCustom else { return }
        customError = nil
        isAddingCustom = true
        defer { isAddingCustom = false }
        do {
            let row = try await catalog.addCustomClone(
                vineyardId: vid,
                varietyKey: varietyKey,
                displayName: raw
            )
            select(key: row.cloneKey, text: row.displayName)
        } catch {
            // Degrade gracefully: keep the value as free text.
            customError = "Couldn't reach the catalogue server — saved as text on this block."
            select(key: nil, text: raw)
        }
    }

    @ViewBuilder
    private func optionRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
            }
        }
    }
}

// MARK: - Rootstock picker

/// Searchable rootstock selector. The catalogue is INDEPENDENT of variety
/// — options are the full shared rootstock catalogue, the vineyard's custom
/// rootstocks, the `own_roots` sentinel, "Not recorded", and a custom-add
/// action. Legacy free-text values are preserved via an explicit "Keep" row.
struct RootstockPickerSheet: View {
    let target: AllocationCatalogPickerTarget
    let vineyardId: UUID?
    /// (rootstockKey, displaySnapshot) — both nil clears the selection.
    let onSelect: (String?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""
    @State private var isAddingCustom: Bool = false
    @State private var customError: String?

    private var catalog: CloneRootstockCatalogStore { .shared }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var systemOptions: [SharedRootstockCatalogEntry] {
        let all = catalog.effectiveSystemRootstocks.filter { $0.isActive }
        guard !trimmedSearch.isEmpty else { return all }
        let q = trimmedSearch
        return all.filter { e in
            e.displayName.localizedCaseInsensitiveContains(q)
                || e.canonicalName.localizedCaseInsensitiveContains(q)
                || e.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
                || (e.parentage?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var customOptions: [VineyardRootstockRow] {
        let all = catalog.activeCustomRootstocks()
        guard !trimmedSearch.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    private var legacyText: String? {
        guard target.currentKey == nil,
              let t = target.currentText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        return t
    }

    private var canOfferCustomAdd: Bool {
        guard !trimmedSearch.isEmpty, vineyardId != nil else { return false }
        let canonical = BuiltInGrapeVarietyCatalog.canonical(trimmedSearch)
        let inSystem = systemOptions.contains { e in
            BuiltInGrapeVarietyCatalog.canonical(e.displayName) == canonical
                || BuiltInGrapeVarietyCatalog.canonical(e.canonicalName) == canonical
                || e.aliases.contains { BuiltInGrapeVarietyCatalog.canonical($0) == canonical }
        }
        let inCustom = customOptions.contains {
            BuiltInGrapeVarietyCatalog.canonical($0.displayName) == canonical
        }
        return !inSystem && !inCustom
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    optionRow(
                        title: "Not recorded",
                        subtitle: "Rootstock unknown / not recorded",
                        isSelected: target.currentKey == nil && legacyText == nil
                    ) {
                        select(key: nil, text: nil)
                    }
                    optionRow(
                        title: "Own roots / ungrafted",
                        subtitle: "Vines growing on their own roots",
                        isSelected: target.currentKey == CloneRootstockSentinels.ownRootsKey
                    ) {
                        select(
                            key: CloneRootstockSentinels.ownRootsKey,
                            text: CloneRootstockSentinels.ownRootsDisplay
                        )
                    }
                }

                if let legacy = legacyText {
                    Section("Current entry") {
                        optionRow(
                            title: "Keep “\(legacy)”",
                            subtitle: "Existing entry, kept as typed",
                            isSelected: true
                        ) {
                            select(key: nil, text: legacy)
                        }
                    }
                }

                if !systemOptions.isEmpty {
                    Section("Rootstock catalogue") {
                        ForEach(systemOptions) { entry in
                            optionRow(
                                title: entry.displayName,
                                subtitle: entry.parentage ?? "",
                                isSelected: target.currentKey == entry.key
                            ) {
                                select(key: entry.key, text: entry.displayName)
                            }
                        }
                    }
                }

                if !customOptions.isEmpty {
                    Section("My rootstocks") {
                        ForEach(customOptions) { row in
                            optionRow(
                                title: row.displayName,
                                subtitle: "Custom · this vineyard",
                                isSelected: target.currentKey == row.rootstockKey
                            ) {
                                select(key: row.rootstockKey, text: row.displayName)
                            }
                        }
                    }
                }

                if canOfferCustomAdd {
                    Section {
                        Button {
                            Task { await addCustomRootstock(named: trimmedSearch) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add “\(trimmedSearch)” as custom rootstock")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(VineyardTheme.info)
                                    Text("Saved to this vineyard and synced to all devices.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isAddingCustom {
                                    ProgressView()
                                } else {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(VineyardTheme.info)
                                }
                            }
                        }
                        .disabled(isAddingCustom)
                    } footer: {
                        if let err = customError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Rootstock")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search rootstocks")
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await catalog.refresh(vineyardId: vineyardId)
            }
        }
    }

    private func select(key: String?, text: String?) {
        onSelect(key, text)
        dismiss()
    }

    private func addCustomRootstock(named raw: String) async {
        guard let vid = vineyardId, !isAddingCustom else { return }
        customError = nil
        isAddingCustom = true
        defer { isAddingCustom = false }
        do {
            let row = try await catalog.addCustomRootstock(vineyardId: vid, displayName: raw)
            select(key: row.rootstockKey, text: row.displayName)
        } catch {
            customError = "Couldn't reach the catalogue server — saved as text on this block."
            select(key: nil, text: raw)
        }
    }

    @ViewBuilder
    private func optionRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
            }
        }
    }
}
