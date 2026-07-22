import SwiftUI

/// Simplified Phase 6E spray record form.
/// Backend-neutral: uses MigratedDataStore only. No WeatherDataService,
/// no auto-save chemicals/equipment options, no LocationService dependency.
struct SprayRecordFormView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let tripId: UUID
    let paddockIds: [UUID]
    var existingRecord: SprayRecord?

    @State private var date: Date
    @State private var startTime: Date
    @State private var sprayReference: String
    @State private var temperatureText: String
    @State private var windSpeedText: String
    @State private var windDirection: String
    @State private var humidityText: String
    @State private var notes: String
    @State private var equipmentType: String
    @State private var tractor: String
    @State private var tractorGear: String
    /// Stable equipment links, populated when a catalog asset is picked.
    /// Cleared back to nil whenever the user types free text into the field.
    @State private var machineId: UUID?
    @State private var tractorId: UUID?
    @State private var sprayEquipmentId: UUID?
    @State private var numberOfFansJets: String
    @State private var averageSpeedText: String
    @State private var tanks: [SprayTank]
    @State private var expandedTankId: UUID?

    init(tripId: UUID, paddockIds: [UUID], existingRecord: SprayRecord? = nil) {
        self.tripId = tripId
        self.paddockIds = paddockIds
        self.existingRecord = existingRecord
        let r = existingRecord
        _date = State(initialValue: r?.date ?? Date())
        _startTime = State(initialValue: r?.startTime ?? Date())
        _sprayReference = State(initialValue: r?.sprayReference ?? "")
        _temperatureText = State(initialValue: r?.temperature.map { String(format: "%.1f", $0) } ?? "")
        _windSpeedText = State(initialValue: r?.windSpeed.map { String(format: "%.1f", $0) } ?? "")
        _windDirection = State(initialValue: r?.windDirection ?? "")
        _humidityText = State(initialValue: r?.humidity.map { String(format: "%.0f", $0) } ?? "")
        _notes = State(initialValue: r?.notes ?? "")
        _equipmentType = State(initialValue: r?.equipmentType ?? "")
        _tractor = State(initialValue: r?.tractor ?? "")
        _tractorGear = State(initialValue: r?.tractorGear ?? "")
        _machineId = State(initialValue: r?.machineId)
        _tractorId = State(initialValue: r?.tractorId)
        _sprayEquipmentId = State(initialValue: r?.sprayEquipmentId)
        _numberOfFansJets = State(initialValue: r?.numberOfFansJets ?? "")
        _averageSpeedText = State(initialValue: r?.averageSpeed.map { String(format: "%.1f", $0) } ?? "")
        _tanks = State(initialValue: r?.tanks ?? [SprayTank(tankNumber: 1)])
    }

    var body: some View {
        NavigationStack {
            Form {
                referenceSection
                weatherSection
                tankCountSection
                ForEach(Array(tanks.enumerated()), id: \.element.id) { idx, _ in
                    tankSection(tankIndex: idx)
                }
                equipmentSection
                notesSection
            }
            .navigationTitle(existingRecord != nil ? "Edit Spray Record" : "New Spray Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveRecord() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
        .onAppear {
            if expandedTankId == nil, let first = tanks.first {
                expandedTankId = first.id
            }
        }
    }

    private var referenceSection: some View {
        Section("Spray Reference") {
            TextField("Spray Number/Reference", text: $sprayReference)
        }
    }

    private var weatherSection: some View {
        Section("Conditions") {
            DatePicker("Date", selection: $date, displayedComponents: .date)
            DatePicker("Start Time", selection: $startTime, displayedComponents: .hourAndMinute)
            LabeledContent {
                TextField("°C", text: $temperatureText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            } label: { Label("Temperature", systemImage: "thermometer") }
            LabeledContent {
                TextField("km/h", text: $windSpeedText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            } label: { Label("Wind Speed", systemImage: "wind") }
            Picker("Wind Direction", selection: $windDirection) {
                Text("Select").tag("")
                ForEach(WindDirection.allCases, id: \.rawValue) { dir in
                    Text(dir.rawValue).tag(dir.rawValue)
                }
            }
            LabeledContent {
                TextField("%", text: $humidityText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            } label: { Label("Humidity", systemImage: "humidity") }
        }
    }

    private var tankCountSection: some View {
        Section("Tanks") {
            Stepper("Number of Tanks: \(tanks.count)", value: Binding(
                get: { tanks.count },
                set: { newCount in
                    if newCount > tanks.count {
                        for i in tanks.count..<newCount {
                            tanks.append(SprayTank(tankNumber: i + 1))
                        }
                    } else if newCount < tanks.count && newCount >= 1 {
                        tanks = Array(tanks.prefix(newCount))
                    }
                }
            ), in: 1...20)
        }
    }

    private func tankSection(tankIndex tIdx: Int) -> some View {
        let tank = tanks[tIdx]
        let isExpanded = expandedTankId == tank.id
        return Section {
            Button {
                withAnimation(.snappy) {
                    expandedTankId = isExpanded ? nil : tank.id
                }
            } label: {
                HStack {
                    Label("Tank \(tank.tankNumber)", systemImage: "drop.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    if tank.areaPerTank > 0 {
                        Text(String(format: "%.2f Ha/tank", tank.areaPerTank))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                tankFields(tIdx: tIdx)
                tankChemicals(tIdx: tIdx)
            }
        }
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<SprayTank, Double>, tIdx: Int) -> Binding<String> {
        Binding<String>(
            get: {
                let v = tanks[tIdx][keyPath: keyPath]
                if v == 0 { return "" }
                if v == v.rounded() { return String(format: "%.0f", v) }
                return String(format: "%g", v)
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    tanks[tIdx][keyPath: keyPath] = 0
                } else if let parsed = Double(trimmed) {
                    tanks[tIdx][keyPath: keyPath] = parsed
                }
            }
        )
    }

    @ViewBuilder
    private func tankFields(tIdx: Int) -> some View {
        LabeledContent {
            TextField("1500", text: doubleBinding(\.waterVolume, tIdx: tIdx))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
        } label: { Text("Water Volume (L)").font(.subheadline) }
        LabeledContent {
            TextField("750", text: doubleBinding(\.sprayRatePerHa, tIdx: tIdx))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
        } label: { Text("Spray Rate (L/Ha)").font(.subheadline) }
        LabeledContent {
            TextField("1.0", text: doubleBinding(\.concentrationFactor, tIdx: tIdx))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
        } label: { Text("Concentration Factor").font(.subheadline) }
    }

    @ViewBuilder
    private func tankChemicals(tIdx: Int) -> some View {
        HStack {
            Text("Chemicals")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button {
                tanks[tIdx].chemicals.append(SprayChemical())
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }

        ForEach(tanks[tIdx].chemicals.indices, id: \.self) { cIdx in
            let chemId = tanks[tIdx].chemicals[cIdx].id
            VStack(spacing: 8) {
                HStack {
                    TextField("Chemical name", text: Binding(
                        get: { tanks[tIdx].chemicals[cIdx].name },
                        set: { tanks[tIdx].chemicals[cIdx].name = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    Button(role: .destructive) {
                        tanks[tIdx].chemicals.removeAll { $0.id == chemId }
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rate/Ha").font(.caption).foregroundStyle(.secondary)
                        TextField("0", value: Binding(
                            get: { tanks[tIdx].chemicals[cIdx].ratePerHa },
                            set: { tanks[tIdx].chemicals[cIdx].ratePerHa = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                            .font(.subheadline)
                    }
                    Divider().frame(height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vol/Tank").font(.caption).foregroundStyle(.secondary)
                        TextField("0", value: Binding(
                            get: { tanks[tIdx].chemicals[cIdx].volumePerTank },
                            set: { tanks[tIdx].chemicals[cIdx].volumePerTank = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                            .font(.subheadline)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Non-tractor vineyard machines plus tractor-backed machines, used to
    /// offer a stable pick for the "Tractor" field.
    private var machineOptions: [VineyardMachine] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.vineyardMachines
            .filter { $0.vineyardId == vid }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var tractorOptions: [Tractor] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.tractors
            .filter { $0.vineyardId == vid }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var sprayEquipmentOptions: [SprayEquipmentItem] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.sprayEquipment
            .filter { $0.vineyardId == vid }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var equipmentSection: some View {
        Section("Equipment") {
            LabeledContent {
                HStack(spacing: 8) {
                    if !sprayEquipmentOptions.isEmpty {
                        Menu {
                            ForEach(sprayEquipmentOptions) { eq in
                                Button(eq.name) {
                                    equipmentType = eq.name
                                    sprayEquipmentId = eq.id
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("Type", text: $equipmentType)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: equipmentType) { _, newValue in
                            // Free text typed: drop the stable link unless it
                            // still exactly matches the linked asset's name.
                            if let id = sprayEquipmentId,
                               sprayEquipmentOptions.first(where: { $0.id == id })?.name != newValue {
                                sprayEquipmentId = nil
                            }
                        }
                }
            } label: { Label("Equipment Type", systemImage: "wrench.and.screwdriver") }
            LabeledContent {
                HStack(spacing: 8) {
                    if !machineOptions.isEmpty || !tractorOptions.isEmpty {
                        Menu {
                            if !machineOptions.isEmpty {
                                Section("Vineyard Machines") {
                                    ForEach(machineOptions) { m in
                                        Button(m.displayName) {
                                            tractor = m.displayName
                                            machineId = m.id
                                            tractorId = nil
                                        }
                                    }
                                }
                            }
                            if !tractorOptions.isEmpty {
                                Section("Tractors") {
                                    ForEach(tractorOptions) { t in
                                        Button(t.displayName) {
                                            tractor = t.displayName
                                            tractorId = t.id
                                            machineId = nil
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("Tractor", text: $tractor)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: tractor) { _, newValue in
                            if let id = machineId,
                               machineOptions.first(where: { $0.id == id })?.displayName != newValue {
                                machineId = nil
                            }
                            if let id = tractorId,
                               tractorOptions.first(where: { $0.id == id })?.displayName != newValue {
                                tractorId = nil
                            }
                        }
                }
            } label: { Label("Tractor", systemImage: "steeringwheel") }
            LabeledContent {
                TextField("Gear", text: $tractorGear).multilineTextAlignment(.trailing)
            } label: { Label("Tractor Gear", systemImage: "gearshape") }
            LabeledContent {
                TextField("Count", text: $numberOfFansJets).multilineTextAlignment(.trailing)
            } label: { Label("No. Fans/Jets", systemImage: "wind") }
            LabeledContent {
                TextField("km/h", text: $averageSpeedText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            } label: { Label("Average Speed", systemImage: "speedometer") }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Additional notes...", text: $notes, axis: .vertical)
                .lineLimit(3...6)
        }
    }

    private func saveRecord() {
        let record = SprayRecord(
            id: existingRecord?.id ?? UUID(),
            tripId: tripId,
            vineyardId: store.selectedVineyardId ?? UUID(),
            date: date,
            startTime: startTime,
            endTime: existingRecord?.endTime,
            temperature: Double(temperatureText),
            windSpeed: Double(windSpeedText),
            windDirection: windDirection,
            humidity: Double(humidityText),
            sprayReference: sprayReference,
            tanks: tanks,
            notes: notes,
            numberOfFansJets: numberOfFansJets,
            averageSpeed: Double(averageSpeedText),
            equipmentType: equipmentType,
            tractor: tractor,
            tractorGear: tractorGear,
            machineId: machineId,
            tractorId: tractorId,
            sprayEquipmentId: sprayEquipmentId,
            isTemplate: existingRecord?.isTemplate ?? false
        )
        if existingRecord != nil {
            store.updateSprayRecord(record)
        } else {
            store.addSprayRecord(record)
        }
        dismiss()
    }
}
