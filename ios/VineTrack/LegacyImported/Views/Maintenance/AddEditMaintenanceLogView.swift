import SwiftUI

struct AddEditMaintenanceLogView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss

    let existingLog: MaintenanceLog?

    @State private var itemName: String = ""
    /// Stable equipment link captured when the user selects an existing asset.
    /// Nil source/ref means the saved row is treated as free_text.
    @State private var equipmentSource: String?
    @State private var equipmentRefId: UUID?
    @State private var activeAddSheet: AddSheet?
    @State private var hours: String = ""
    @State private var machineHours: String = ""
    @State private var workCompleted: String = ""
    @State private var partsUsed: String = ""
    @State private var partsCost: String = ""
    @State private var labourCost: String = ""
    @State private var date: Date = Date()
    @State private var invoicePhotoData: Data?
    @State private var photoChanged: Bool = false
    @State private var showCamera: Bool = false
    @State private var showPhotoSource: Bool = false
    @State private var showDeleteAlert: Bool = false

    private var isEditing: Bool { existingLog != nil }

    /// Which add flow the + menu launches. Each opens the matching equipment
    /// add sheet; the selection still saves as a plain `itemName` string.
    private enum AddSheet: Identifiable {
        case tractor
        case sprayEquipment
        case vineyardMachine
        case otherEquipment
        var id: Int { hashValue }
    }

    private var otherEquipmentItems: [EquipmentItem] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.equipmentItems
            .filter { $0.vineyardId == vid }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Non-tractor vineyard machines (ATVs, side-by-sides, harvesters, etc.).
    /// Tractor-backed machines are excluded because they already appear under
    /// the Tractors group.
    private var vineyardMachineItems: [VineyardMachine] {
        store.machines().filter { $0.legacyTractorId == nil }
    }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }
    private var canDelete: Bool { accessControl?.canDelete ?? false }

    init(existingLog: MaintenanceLog? = nil) {
        self.existingLog = existingLog
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Item / Machine") {
                    HStack(spacing: 8) {
                        Menu {
                            if !store.tractors.isEmpty {
                                Section("Tractors") {
                                    ForEach(store.tractors) { tractor in
                                        Button(tractor.displayName) {
                                            itemName = tractor.displayName
                                            equipmentSource = "tractor"
                                            equipmentRefId = tractor.id
                                        }
                                    }
                                }
                            }
                            if !store.sprayEquipment.isEmpty {
                                Section("Spray Equipment") {
                                    ForEach(store.sprayEquipment) { eq in
                                        Button(eq.name) {
                                            itemName = eq.name
                                            equipmentSource = "spray_equipment"
                                            equipmentRefId = eq.id
                                        }
                                    }
                                }
                            }
                            if !vineyardMachineItems.isEmpty {
                                Section("Vineyard Machines") {
                                    ForEach(vineyardMachineItems) { machine in
                                        Button("\(machine.displayName) · \(machine.machineType.displayName)") {
                                            itemName = machine.displayName
                                            equipmentSource = "vineyard_machine"
                                            equipmentRefId = machine.id
                                        }
                                    }
                                }
                            }
                            if !otherEquipmentItems.isEmpty {
                                Section("Other Equipment & Assets") {
                                    ForEach(otherEquipmentItems) { item in
                                        Button(item.displayName) {
                                            itemName = item.displayName
                                            equipmentSource = "equipment_item"
                                            equipmentRefId = item.id
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(itemName.isEmpty ? "Select item" : itemName)
                                    .foregroundStyle(itemName.isEmpty ? .secondary : .primary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        if accessControl?.canManageSetup ?? false {
                            Menu {
                                Button {
                                    activeAddSheet = .tractor
                                } label: {
                                    Label("Add Tractor", systemImage: "tractor")
                                }
                                Button {
                                    activeAddSheet = .sprayEquipment
                                } label: {
                                    Label("Add Spray Equipment", systemImage: "drop.fill")
                                }
                                Button {
                                    activeAddSheet = .vineyardMachine
                                } label: {
                                    Label("Add Vineyard Machine", systemImage: "car.fill")
                                }
                                Button {
                                    activeAddSheet = .otherEquipment
                                } label: {
                                    Label("Add Other Equipment & Asset", systemImage: "shippingbox.fill")
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(VineyardTheme.earthBrown)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add item")
                        }
                    }
                    if store.tractors.isEmpty && store.sprayEquipment.isEmpty && vineyardMachineItems.isEmpty && otherEquipmentItems.isEmpty {
                        Text("No tractors, spray equipment, vineyard machines, or other items yet. Tap + to add an Other item, or visit Equipment in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Service Details") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    HStack {
                        Text("Labour Hours")
                        Spacer()
                        TextField("0", text: $hours)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Machine Hours")
                            Text("Optional")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        TextField("e.g. 1250.5", text: $machineHours)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                }

                Section("Work Completed") {
                    TextField("Describe work completed...", text: $workCompleted, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Parts Used") {
                    TextField("List parts used...", text: $partsUsed, axis: .vertical)
                        .lineLimit(2...5)
                }

                if canViewFinancials {
                    Section("Costs") {
                        HStack {
                            Text("Parts Cost")
                            Spacer()
                            Text(currencySymbol)
                                .foregroundStyle(.secondary)
                            TextField("0.00", text: $partsCost)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                        }
                        HStack {
                            Text("Labour Cost")
                            Spacer()
                            Text(currencySymbol)
                                .foregroundStyle(.secondary)
                            TextField("0.00", text: $labourCost)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                        }
                        HStack {
                            Text("Total")
                                .fontWeight(.semibold)
                            Spacer()
                            Text(fmt.formatCurrency(computedTotal))
                                .fontWeight(.semibold)
                                .foregroundStyle(VineyardTheme.earthBrown)
                        }
                    }
                }

                Section("Invoice Photo") {
                    if let photoData = invoicePhotoData, let uiImage = UIImage(data: photoData) {
                        VStack(spacing: 12) {
                            Color(.secondarySystemBackground)
                                .frame(height: 200)
                                .overlay {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .allowsHitTesting(false)
                                }
                                .clipShape(.rect(cornerRadius: 12))

                            HStack {
                                Button {
                                    showPhotoSource = true
                                } label: {
                                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.subheadline)
                                }

                                Spacer()

                                Button(role: .destructive) {
                                    withAnimation {
                                        invoicePhotoData = nil
                                        photoChanged = true
                                    }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                        .font(.subheadline)
                                }
                            }
                        }
                    } else {
                        Button {
                            showPhotoSource = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "camera.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(VineyardTheme.earthBrown.gradient, in: .rect(cornerRadius: 10))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add Invoice Photo")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Take a photo or choose from library")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if isEditing && canDelete {
                    Section {
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("Delete Record", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Record" : "New Maintenance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveLog() }
                        .fontWeight(.semibold)
                        .disabled(itemName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Add Photo", isPresented: $showPhotoSource) {
                Button("Take Photo") {
                    showCamera = true
                }
                Button("Choose from Library") {
                    showCamera = true
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraImagePicker { data in
                    if let data {
                        invoicePhotoData = data
                        photoChanged = true
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Delete Record", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let log = existingLog {
                        store.deleteMaintenanceLog(log.id)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this maintenance record?")
            }
            .sheet(item: $activeAddSheet) { sheet in
                switch sheet {
                case .tractor:
                    TractorFormSheet(tractor: nil)
                case .sprayEquipment:
                    EquipmentFormSheet(equipment: nil)
                case .vineyardMachine:
                    VineyardMachineFormSheet(machine: nil)
                case .otherEquipment:
                    OtherEquipmentFormSheet(item: nil) { saved in
                        itemName = saved.displayName
                        equipmentSource = "equipment_item"
                        equipmentRefId = saved.id
                    }
                }
            }
            .onAppear {
                if let log = existingLog {
                    itemName = log.itemName
                    equipmentSource = log.equipmentSource
                    equipmentRefId = log.equipmentRefId
                    hours = log.hours > 0 ? String(format: "%.1f", log.hours) : ""
                    if let mh = log.machineHours {
                        machineHours = String(format: "%.1f", mh)
                    }
                    workCompleted = log.workCompleted
                    partsUsed = log.partsUsed
                    partsCost = log.partsCost > 0 ? String(format: "%.2f", log.partsCost) : ""
                    labourCost = log.labourCost > 0 ? String(format: "%.2f", log.labourCost) : ""
                    date = log.date
                    invoicePhotoData = log.invoicePhotoData
                }
            }
        }
    }

    private var computedTotal: Double {
        (Double(partsCost) ?? 0) + (Double(labourCost) ?? 0)
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var currencySymbol: String {
        fmt.formatCurrency(0)
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.,"))
            .first(where: { !$0.isEmpty }) ?? "$"
    }

    private func saveLog() {
        let trimmedName = itemName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        var log = existingLog ?? MaintenanceLog()
        log.itemName = trimmedName
        // Persist the stable equipment link when an asset was selected;
        // otherwise classify as free text. item_name is always preserved.
        if let refId = equipmentRefId, let source = equipmentSource, source != "free_text" {
            log.equipmentSource = source
            log.equipmentRefId = refId
        } else {
            log.equipmentSource = "free_text"
            log.equipmentRefId = nil
        }
        log.hours = Double(hours) ?? 0
        let trimmedMH = machineHours.trimmingCharacters(in: .whitespaces)
        log.machineHours = trimmedMH.isEmpty ? nil : Double(trimmedMH)
        log.workCompleted = workCompleted.trimmingCharacters(in: .whitespacesAndNewlines)
        log.partsUsed = partsUsed.trimmingCharacters(in: .whitespacesAndNewlines)
        log.partsCost = Double(partsCost) ?? 0
        log.labourCost = Double(labourCost) ?? 0
        log.date = date
        log.invoicePhotoData = invoicePhotoData
        // If the photo changed (added, replaced, or removed), clear the synced
        // path so MaintenanceLogSyncService re-uploads or drops it on next sync.
        if photoChanged {
            log.photoPath = nil
        }
        let userName = auth.userName ?? ""
        log.createdBy = userName.isEmpty ? nil : userName

        if isEditing {
            store.updateMaintenanceLog(log)
        } else {
            store.addMaintenanceLog(log)
        }
        dismiss()
    }
}
