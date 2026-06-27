import SwiftUI

/// Vineyard setup screen for "Other" equipment items used by the Maintenance
/// page Item / Machine picker. These are general-purpose assets that are not
/// tractors and not spray equipment (quad bike, ute, trailer, pump, generator,
/// compressor, slasher, mulcher, irrigation pump, workshop tool, etc.).
///
/// Backed by public.equipment_items (sql/053) via EquipmentItemSyncService —
/// items created here sync to Lovable and vice-versa.
struct OtherEquipmentManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(EquipmentItemSyncService.self) private var sync
    @Environment(\.accessControl) private var accessControl

    @State private var showAddSheet: Bool = false
    @State private var editingItem: EquipmentItem?

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    private var items: [EquipmentItem] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.equipmentItems
            .filter { $0.vineyardId == vid }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    Text("No items yet. Add trailers, implements, tools, irrigation parts, workshop gear, or other non-fuel-tracked vineyard assets you maintain. Powered machines like tractors, ATVs and side-by-sides belong under Vineyard Machines.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        Group {
                            if canManageSetup {
                                Button { editingItem = item } label: { OtherEquipmentRow(item: item) }
                            } else {
                                OtherEquipmentRow(item: item)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if canManageSetup {
                                Button(role: .destructive) {
                                    store.deleteEquipmentItem(item)
                                    Task { await sync.syncForSelectedVineyard() }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            } header: {
                Label("Other Items", systemImage: "shippingbox.fill")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
            } footer: {
                if canManageSetup {
                    Text("Items added here appear in the Maintenance Log Item / Machine selector under Other, and sync with Lovable.")
                } else {
                    Text("Setup data is managed by vineyard owners and managers.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Other Equipment")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await sync.syncForSelectedVineyard()
        }
        .toolbar {
            if canManageSetup {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            OtherEquipmentFormSheet(item: nil)
        }
        .sheet(item: $editingItem) { item in
            OtherEquipmentFormSheet(item: item)
        }
    }
}

private struct OtherEquipmentRow: View {
    let item: EquipmentItem

    private var subtitle: String {
        var parts: [String] = []
        if let make = item.make?.trimmingCharacters(in: .whitespaces), !make.isEmpty { parts.append(make) }
        if let model = item.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty { parts.append(model) }
        if let serial = item.serialNumber?.trimmingCharacters(in: .whitespaces), !serial.isEmpty { parts.append("S/N \(serial)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct OtherEquipmentFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(EquipmentItemSyncService.self) private var sync

    let item: EquipmentItem?
    var onSaved: ((EquipmentItem) -> Void)?

    @State private var name: String = ""
    @State private var make: String = ""
    @State private var model: String = ""
    @State private var serial: String = ""
    @State private var notes: String = ""

    init(item: EquipmentItem?, onSaved: ((EquipmentItem) -> Void)? = nil) {
        self.item = item
        self.onSaved = onSaved
        if let i = item {
            _name = State(initialValue: i.name)
            _make = State(initialValue: i.make ?? "")
            _model = State(initialValue: i.model ?? "")
            _serial = State(initialValue: i.serialNumber ?? "")
            _notes = State(initialValue: i.notes)
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Quad Bike", text: $name)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Quad bike, ute, trailer, pump, generator, compressor, slasher, mulcher, irrigation pump, workshop tool, etc.")
                }

                Section("Details (optional)") {
                    TextField("Make", text: $make)
                    TextField("Model", text: $model)
                    TextField("Serial Number", text: $serial)
                }

                Section("Notes (optional)") {
                    TextField("Anything worth noting…", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle(item == nil ? "Add Item" : "Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let saved = save()
                        if let saved { onSaved?(saved) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
    }

    @discardableResult
    private func save() -> EquipmentItem? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return nil }
        let trimmedMake = make.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedSerial = serial.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        let result: EquipmentItem
        if var existing = item {
            existing.name = trimmedName
            existing.make = trimmedMake.isEmpty ? nil : trimmedMake
            existing.model = trimmedModel.isEmpty ? nil : trimmedModel
            existing.serialNumber = trimmedSerial.isEmpty ? nil : trimmedSerial
            existing.notes = trimmedNotes
            store.updateEquipmentItem(existing)
            result = existing
        } else {
            let newItem = EquipmentItem(
                name: trimmedName,
                category: "other",
                make: trimmedMake.isEmpty ? nil : trimmedMake,
                model: trimmedModel.isEmpty ? nil : trimmedModel,
                serialNumber: trimmedSerial.isEmpty ? nil : trimmedSerial,
                notes: trimmedNotes
            )
            store.addEquipmentItem(newItem)
            result = newItem
        }
        Task { await sync.syncForSelectedVineyard() }
        return result
    }
}
