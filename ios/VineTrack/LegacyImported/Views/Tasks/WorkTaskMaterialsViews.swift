import Foundation
import SwiftUI

nonisolated enum MaterialCostDisplay {
    static func currency(_ value: Decimal, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(code) \(decimal(value, fractionDigits: 2))"
    }

    static func decimal(_ value: Decimal, fractionDigits: Int = 4) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }

    static func parse(_ text: String) -> Decimal? {
        Decimal(string: text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct WorkTaskMaterialsSection: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(WorkTaskMaterialSyncService.self) private var sync

    let workTaskId: UUID?
    let vineyardId: UUID?
    /// Optional host-owned routing used by the Work Task editor. Standalone
    /// callers retain the section's self-contained presentation behavior.
    let onAdd: (() -> Void)?
    let onEdit: ((WorkTaskMaterial) -> Void)?

    @State private var isSelecting: Bool = false
    @State private var selectedEntry: MaterialLibraryEntry?
    @State private var editingLine: WorkTaskMaterial?
    @State private var deletingLine: WorkTaskMaterial?

    init(
        workTaskId: UUID?,
        vineyardId: UUID?,
        onAdd: (() -> Void)? = nil,
        onEdit: ((WorkTaskMaterial) -> Void)? = nil
    ) {
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.onAdd = onAdd
        self.onEdit = onEdit
    }

    private var lines: [WorkTaskMaterial] {
        guard let workTaskId else { return [] }
        return store.materials(forWorkTask: workTaskId)
    }

    private var total: Decimal {
        guard let workTaskId else { return 0 }
        return store.materialTotal(forWorkTask: workTaskId)
    }

    var body: some View {
        Section {
            if workTaskId == nil || vineyardId == nil {
                Text("Save this task first to add materials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if lines.isEmpty {
                    Text("No materials added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(lines) { line in
                        Button {
                            if let onEdit { onEdit(line) } else { editingLine = line }
                        } label: { lineRow(line) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deletingLine = line } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }

                Button {
                    if let onAdd { onAdd() } else { isSelecting = true }
                } label: {
                    Label("Add Material", systemImage: "plus.circle.fill")
                }

                HStack {
                    Text("Material Total").font(.headline)
                    Spacer()
                    Text(MaterialCostDisplay.currency(total, code: store.settings.regionFormatter.currencyCode))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
                .padding(.vertical, 4)

                if let message = sync.errorMessage, !lines.isEmpty {
                    Label("Using saved materials. Refresh failed; changes remain queued.", systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityHint(message)
                }
            }
        } header: {
            Text("Material Costs")
        } footer: {
            Text("Task prices are frozen snapshots. Editing a line never changes the vineyard material library.")
        }
        .sheet(isPresented: $isSelecting) {
            MaterialSelectorView(entries: store.materialLibrary()) { entry in
                isSelecting = false
                selectedEntry = entry
            }
        }
        .sheet(item: $selectedEntry) { entry in
            if let workTaskId, let vineyardId {
                WorkTaskMaterialEditorView(workTaskId: workTaskId, vineyardId: vineyardId, entry: entry)
            }
        }
        .sheet(item: $editingLine) { line in
            WorkTaskMaterialEditorView(workTaskId: line.workTaskId, vineyardId: line.vineyardId, existingLine: line)
        }
        .confirmationDialog(
            "Remove material?",
            isPresented: Binding(get: { deletingLine != nil }, set: { if !$0 { deletingLine = nil } }),
            presenting: deletingLine
        ) { line in
            Button("Remove Material", role: .destructive) {
                store.deleteWorkTaskMaterial(line.id)
                deletingLine = nil
            }
            Button("Cancel", role: .cancel) { deletingLine = nil }
        } message: { line in
            Text("\(line.materialName) will be removed from this task. The vineyard library will not be changed.")
        }
    }

    private func lineRow(_ line: WorkTaskMaterial) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.materialName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                Text(MaterialCostDisplay.currency(line.totalCost, code: store.settings.regionFormatter.currencyCode))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
            }
            Text("\(MaterialCostDisplay.decimal(line.quantity)) \(line.unit) × \(MaterialCostDisplay.currency(line.unitCost, code: store.settings.regionFormatter.currencyCode))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

nonisolated enum WorkTaskMaterialFlowPhase: Equatable, Sendable {
    case selecting
    case editing(MaterialLibraryEntry)
}

/// A single stable sheet for the add-material journey. Selecting a catalogue
/// item swaps to the usage editor inside this presentation instead of dismissing
/// one sheet and racing to present another.
struct WorkTaskMaterialFlowView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let workTaskId: UUID
    let vineyardId: UUID
    @State private var phase: WorkTaskMaterialFlowPhase = .selecting

    var body: some View {
        switch phase {
        case .selecting:
            MaterialSelectorView(
                entries: store.materialLibrary(),
                dismissAfterSelection: false,
                onSelect: { phase = .editing($0) }
            )
        case .editing(let entry):
            WorkTaskMaterialEditorView(
                workTaskId: workTaskId,
                vineyardId: vineyardId,
                entry: entry,
                onFinished: { dismiss() }
            )
        }
    }
}

struct MaterialSelectorView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [MaterialLibraryEntry]
    let dismissAfterSelection: Bool
    let onSelect: (MaterialLibraryEntry) -> Void
    @State private var searchText: String = ""

    init(
        entries: [MaterialLibraryEntry],
        dismissAfterSelection: Bool = true,
        onSelect: @escaping (MaterialLibraryEntry) -> Void
    ) {
        self.entries = entries
        self.dismissAfterSelection = dismissAfterSelection
        self.onSelect = onSelect
    }

    private var filtered: [MaterialLibraryEntry] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return entries }
        return entries.filter { $0.name.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(categories, id: \.self) { category in
                        Section(category) {
                            ForEach(filtered.filter { $0.category == category }) { entry in
                                Button {
                                    onSelect(entry)
                                    if dismissAfterSelection { dismiss() }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.name).foregroundStyle(.primary)
                                        HStack(spacing: 5) {
                                            Text(entry.unit)
                                            if let cost = entry.defaultUnitCost {
                                                Text("•")
                                                Text(MaterialCostDisplay.currency(cost, code: currencyCode))
                                            } else {
                                                Text("• No default cost")
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Material")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search materials")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    @Environment(MigratedDataStore.self) private var store
    private var currencyCode: String { store.settings.regionFormatter.currencyCode }
    private var categories: [String] {
        Array(Set(filtered.map { $0.category })).sorted {
            let left = MaterialCategoryCatalog.order(of: $0)
            let right = MaterialCategoryCatalog.order(of: $1)
            return left == right ? $0 < $1 : left < right
        }
    }
}

struct WorkTaskMaterialEditorView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let workTaskId: UUID
    let vineyardId: UUID
    let entry: MaterialLibraryEntry?
    let existingLine: WorkTaskMaterial?
    let onFinished: (() -> Void)?

    @State private var quantityText: String
    @State private var unit: String
    @State private var unitCostText: String
    @State private var errorMessage: String?

    init(
        workTaskId: UUID,
        vineyardId: UUID,
        entry: MaterialLibraryEntry? = nil,
        existingLine: WorkTaskMaterial? = nil,
        onFinished: (() -> Void)? = nil
    ) {
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.entry = entry
        self.existingLine = existingLine
        self.onFinished = onFinished
        _quantityText = State(initialValue: existingLine.map { MaterialCostDisplay.decimal($0.quantity) } ?? "")
        _unit = State(initialValue: existingLine?.unit ?? entry?.unit ?? "Each")
        _unitCostText = State(initialValue: existingLine.map { MaterialCostDisplay.decimal($0.unitCost) } ?? entry?.defaultUnitCost.map { MaterialCostDisplay.decimal($0) } ?? "")
    }

    private var name: String { existingLine?.materialName ?? entry?.name ?? "Material" }
    private var quantity: Decimal? { MaterialCostDisplay.parse(quantityText) }
    private var unitCost: Decimal? { MaterialCostDisplay.parse(unitCostText) }
    private var total: Decimal { MaterialMoney.lineTotal(quantity: quantity ?? 0, unitCost: unitCost ?? 0) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Material") { Text(name).foregroundStyle(.secondary) }
                Section("Usage") {
                    TextField("Quantity", text: $quantityText)
                        .keyboardType(.decimalPad)
                    Picker("Unit", selection: $unit) {
                        ForEach(unitOptions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Unit Cost", text: $unitCostText)
                        .keyboardType(.decimalPad)
                }
                Section("Material Total") {
                    HStack {
                        Text("\(quantityText.isEmpty ? "0" : quantityText) × \(unitCostText.isEmpty ? "0" : unitCostText)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(MaterialCostDisplay.currency(total, code: store.settings.regionFormatter.currencyCode))
                            .font(.headline)
                    }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                if existingLine != nil {
                    Section { Text("To replace the selected material, remove this line and add the new material.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(existingLine == nil ? "Add Material" : "Edit Material")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).fontWeight(.semibold) }
            }
        }
    }

    private var unitOptions: [String] {
        var values = MaterialUnitCatalog.suggested
        if !values.contains(unit) { values.append(unit) }
        return values
    }

    private func save() {
        guard let quantity else { errorMessage = "Enter a quantity."; return }
        guard quantity > 0 else { errorMessage = "Quantity must be greater than zero."; return }
        guard !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Enter a unit."; return }
        guard let unitCost, unitCost >= 0 else { errorMessage = "Enter a valid unit cost."; return }

        if var line = existingLine {
            line.quantity = quantity
            line.unit = MaterialUnitCatalog.normalised(unit)
            line.unitCost = unitCost
            store.updateWorkTaskMaterial(line)
        } else if let entry {
            store.addWorkTaskMaterial(entry.makeTaskMaterial(workTaskId: workTaskId, vineyardId: vineyardId, quantity: quantity, unitCost: unitCost, unit: unit))
        }
        if let onFinished { onFinished() } else { dismiss() }
    }
}

struct VineyardMaterialLibraryView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(MaterialCatalogueSyncService.self) private var catalogueSync
    @Environment(VineyardMaterialSyncService.self) private var librarySync

    @State private var searchText: String = ""
    @State private var editingEntry: MaterialLibraryEntry?
    @State private var editingCustom: VineyardMaterial?
    @State private var isAddingCustom: Bool = false

    private var activeEntries: [MaterialLibraryEntry] {
        let all = store.materialLibrary()
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(searchText) }
    }

    private var inactiveCustoms: [VineyardMaterial] {
        guard let vineyardId = store.selectedVineyardId else { return [] }
        return store.vineyardMaterials.filter { $0.vineyardId == vineyardId && $0.isCustom && !$0.isActive }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if activeEntries.isEmpty {
                ContentUnavailableView("No materials", systemImage: "shippingbox", description: Text("The saved catalogue is still available offline after it has loaded once."))
            } else {
                ForEach(categories, id: \.self) { category in
                    Section(category) {
                        ForEach(activeEntries.filter { $0.category == category }) { entry in
                            Button { editingEntry = entry } label: { libraryRow(entry) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !inactiveCustoms.isEmpty {
                Section("Inactive Custom Materials") {
                    ForEach(inactiveCustoms) { material in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(material.name)
                                Text("\(material.category) • \(material.unit)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reactivate") {
                                var updated = material
                                updated.isActive = true
                                store.updateVineyardMaterial(updated)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if catalogueSync.errorMessage != nil || librarySync.errorMessage != nil {
                Section {
                    Label("Showing the saved library. Refresh failed; pending changes will retry automatically.", systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Retry") { refresh() }
                }
            }
        }
        .navigationTitle("Material Library")
        .searchable(text: $searchText, prompt: "Search materials")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isAddingCustom = true } label: { Label("Add Custom Material", systemImage: "plus") }
            }
        }
        .refreshable { await refreshAsync() }
        .task { await refreshAsync() }
        .sheet(isPresented: $isAddingCustom) { VineyardMaterialEditorView() }
        .sheet(item: $editingEntry) { entry in
            if entry.isCustom, let id = entry.vineyardMaterialId,
               let material = store.vineyardMaterials.first(where: { $0.id == id }) {
                VineyardMaterialEditorView(existing: material)
            } else {
                VineyardMaterialEditorView(standardEntry: entry)
            }
        }
        .sheet(item: $editingCustom) { VineyardMaterialEditorView(existing: $0) }
    }

    private var categories: [String] {
        Array(Set(activeEntries.map(\.category))).sorted { MaterialCategoryCatalog.order(of: $0) < MaterialCategoryCatalog.order(of: $1) }
    }

    private func libraryRow(_ entry: MaterialLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.name).font(.subheadline.weight(.semibold))
                Spacer()
                if entry.isCustom { Text("Custom").font(.caption2.weight(.semibold)).foregroundStyle(VineyardTheme.leafGreen) }
            }
            Text(entry.defaultUnitCost.map { "\(entry.unit) • Default cost: \(MaterialCostDisplay.currency($0, code: store.settings.regionFormatter.currencyCode))" } ?? "\(entry.unit) • No default cost")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func refresh() { Task { await refreshAsync() } }
    private func refreshAsync() async {
        await catalogueSync.sync()
        await librarySync.syncForSelectedVineyard()
    }
}

struct VineyardMaterialEditorView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let standardEntry: MaterialLibraryEntry?
    let existing: VineyardMaterial?

    @State private var name: String
    @State private var category: String
    @State private var unit: String
    @State private var costText: String
    @State private var errorMessage: String?
    @State private var confirmDeactivate: Bool = false

    init(standardEntry: MaterialLibraryEntry? = nil, existing: VineyardMaterial? = nil) {
        self.standardEntry = standardEntry
        self.existing = existing
        _name = State(initialValue: existing?.name ?? standardEntry?.name ?? "")
        _category = State(initialValue: existing?.category ?? standardEntry?.category ?? MaterialCategoryCatalog.other)
        _unit = State(initialValue: existing?.unit ?? standardEntry?.unit ?? "Each")
        _costText = State(initialValue: (existing?.defaultUnitCost ?? standardEntry?.defaultUnitCost).map { MaterialCostDisplay.decimal($0) } ?? "")
    }

    private var isStandard: Bool { standardEntry != nil && existing == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Material") {
                    if isStandard { Text(name).foregroundStyle(.secondary) }
                    else { TextField("Name", text: $name) }
                    Picker("Category", selection: $category) {
                        ForEach(MaterialCategoryCatalog.ordered, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(isStandard)
                    Picker("Unit", selection: $unit) {
                        ForEach(unitOptions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Default Unit Cost (optional)", text: $costText).keyboardType(.decimalPad)
                }
                Section { Text("Changing this library default never changes existing Work Task snapshots.").font(.caption).foregroundStyle(.secondary) }
                if let errorMessage { Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
                if let existing, existing.isCustom && existing.isActive {
                    Section {
                        Button("Deactivate Custom Material", role: .destructive) { confirmDeactivate = true }
                    }
                }
            }
            .navigationTitle(isStandard ? "Standard Material" : existing == nil ? "New Custom Material" : "Edit Custom Material")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).fontWeight(.semibold) }
            }
            .confirmationDialog("Deactivate material?", isPresented: $confirmDeactivate) {
                Button("Deactivate", role: .destructive) {
                    if let existing { store.deactivateVineyardMaterial(existing.id) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("It will disappear from new task selection but remain on historical Work Tasks.") }
        }
    }

    private var unitOptions: [String] {
        var values = MaterialUnitCatalog.suggested
        if !values.contains(unit) { values.append(unit) }
        return values
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { errorMessage = "Enter a material name."; return }
        guard !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Enter a unit."; return }
        let cost: Decimal?
        if costText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cost = nil }
        else if let parsed = MaterialCostDisplay.parse(costText), parsed >= 0 { cost = parsed }
        else { errorMessage = "Enter a valid unit cost."; return }
        guard let vineyardId = store.selectedVineyardId else { errorMessage = "Select a vineyard first."; return }

        if var material = existing {
            material.name = trimmedName
            material.category = category
            material.unit = MaterialUnitCatalog.normalised(unit)
            material.defaultUnitCost = cost
            store.updateVineyardMaterial(material)
        } else if let standardEntry {
            guard let base = store.materialCatalogue.first(where: { $0.key == standardEntry.baseMaterialKey }) else {
                errorMessage = "This standard material is not available yet. Refresh the library and try again."
                return
            }
            if let existingOverrideId = standardEntry.vineyardMaterialId,
               var override = store.vineyardMaterials.first(where: { $0.id == existingOverrideId }) {
                override.unit = MaterialUnitCatalog.normalised(unit)
                override.defaultUnitCost = cost
                store.updateVineyardMaterial(override)
            } else if let override = VineyardMaterial.override(vineyardId: vineyardId, base: base, unit: unit, defaultUnitCost: cost) {
                store.addVineyardMaterial(override)
            } else {
                errorMessage = "Connect once to load the standard catalogue before setting its default price."
                return
            }
        } else {
            store.addVineyardMaterial(.custom(vineyardId: vineyardId, name: trimmedName, category: category, unit: unit, defaultUnitCost: cost))
        }
        dismiss()
    }
}
