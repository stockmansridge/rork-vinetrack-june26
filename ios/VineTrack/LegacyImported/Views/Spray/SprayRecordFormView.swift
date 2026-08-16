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
    /// The blocks this application treated (sql/195).
    ///
    /// The manual form is a full creation path, so it must record attribution too
    /// — otherwise it stays a way to keep producing sprays that no per-block
    /// resistance history can ever account for.
    @State private var selectedBlockIds: Set<UUID>
    @State private var expandedTankId: UUID?
    /// Which product line is currently choosing a Saved Chemical.
    @State private var picker: ChemicalPickerTarget?

    /// Identifies the line a picker sheet is editing.
    private struct ChemicalPickerTarget: Identifiable, Hashable {
        let tankIndex: Int
        let chemicalIndex: Int
        var id: String { "\(tankIndex)-\(chemicalIndex)" }
    }

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
        // An existing record's own recorded attribution wins. A record that never
        // recorded any is left EMPTY rather than pre-filled from the trip: quietly
        // adopting the trip's blocks on a historical edit would manufacture
        // attribution nobody stated. A NEW record starts from the trip selection,
        // which the operator can change before saving.
        let recordedBlocks = r?.applicationGeometry?.blocks?.compactMap { UUID(uuidString: $0.blockId) }
        if let recordedBlocks, !recordedBlocks.isEmpty {
            _selectedBlockIds = State(initialValue: Set(recordedBlocks))
        } else if r == nil {
            _selectedBlockIds = State(initialValue: Set(paddockIds))
        } else {
            _selectedBlockIds = State(initialValue: [])
        }
    }

    /// Blocks available to attribute this spray to, in stable display order.
    private var availableBlocks: [Paddock] {
        guard let vineyardId = store.selectedVineyardId else { return [] }
        return store.paddocks
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The attribution to persist, built through the SAME canonical geometry path
    /// the guided calculator uses.
    ///
    /// Routing it through `SprayGeometryResolver` rather than assembling ids by
    /// hand is deliberate: it keeps one definition of what a treated block's
    /// recorded geometry is, so a manually entered spray and a calculated one are
    /// never two different shapes of the same fact.
    private var attributionBlocks: [SprayApplicationBlockSnapshot]? {
        let selected = availableBlocks.filter { selectedBlockIds.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        let geometry = SprayGeometryResolver.resolve(selected.map { SprayBlockInput.from(paddock: $0) })
        return SprayApplicationBlockSnapshot.project(geometry.blocks)
    }

    var body: some View {
        NavigationStack {
            Form {
                referenceSection
                blocksSection
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
        .sheet(item: $picker) { target in
            SprayLineChemicalPicker(
                selectedId: tanks[target.tankIndex].chemicals[target.chemicalIndex].savedChemicalId
            ) { chosen in
                bind(chosen, at: target)
            }
        }
        .onAppear {
            if expandedTankId == nil, let first = tanks.first {
                expandedTankId = first.id
            }
        }
    }

    /// Bind a line to a picked Saved Chemical, or release it back to manual.
    ///
    /// Choosing a product overwrites the typed name with the store's name, so the
    /// record shows the product that was actually selected. Choosing "enter
    /// manually" clears the identifier and leaves the typed name intact.
    private func bind(_ chosen: SavedChemical?, at target: ChemicalPickerTarget) {
        guard tanks.indices.contains(target.tankIndex),
              tanks[target.tankIndex].chemicals.indices.contains(target.chemicalIndex)
        else { return }
        var line = tanks[target.tankIndex].chemicals[target.chemicalIndex]
        if let chosen {
            line.savedChemicalId = chosen.id
            line.name = chosen.name
            if line.ratePerHa == 0, chosen.ratePerHa > 0 {
                line.ratePerHa = chosen.ratePerHa
            }
        } else {
            line.savedChemicalId = nil
        }
        tanks[target.tankIndex].chemicals[target.chemicalIndex] = line
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
                chemicalIdentityRow(tIdx: tIdx, cIdx: cIdx, chemId: chemId)
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

    /// The Saved Chemical a line is bound to, or `nil` for a manual product.
    ///
    /// Resolved by IDENTIFIER only, so a product renamed in the store still
    /// resolves and a typed look-alike name never does.
    private func boundChemical(_ line: SprayChemical) -> SavedChemical? {
        guard let id = line.savedChemicalId else { return nil }
        return store.savedChemicals.first { $0.id == id }
    }

    /// The product identity row: either a picked Saved Chemical, or an explicit
    /// manual product.
    ///
    /// The two states look deliberately different. A grower needs to see at a
    /// glance which lines carry real chemistry and which are off-library entries
    /// that resistance analysis will not be able to assess.
    @ViewBuilder
    private func chemicalIdentityRow(tIdx: Int, cIdx: Int, chemId: UUID) -> some View {
        let line = tanks[tIdx].chemicals[cIdx]
        if let bound = boundChemical(line) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bound.name)
                        .font(.subheadline.weight(.medium))
                    ChemicalVerificationBadge(status: bound.verificationStatus)
                    Button("Change product") {
                        picker = ChemicalPickerTarget(tankIndex: tIdx, chemicalIndex: cIdx)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button(role: .destructive) {
                    tanks[tIdx].chemicals.removeAll { $0.id == chemId }
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        picker = ChemicalPickerTarget(tankIndex: tIdx, chemicalIndex: cIdx)
                    } label: {
                        Label("Select Chemical", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button(role: .destructive) {
                        tanks[tIdx].chemicals.removeAll { $0.id == chemId }
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                TextField("Or type a product not in your Chemical Store", text: Binding(
                    get: { tanks[tIdx].chemicals[cIdx].name },
                    set: { tanks[tIdx].chemicals[cIdx].name = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                if !line.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Stated plainly rather than blocked: an urgent field record
                    // must never be held up by a missing library entry.
                    Text("Recorded as an unverified product. Add it to your Chemical Store to include it in resistance tracking.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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

    /// Freeze Chemical Intelligence onto the lines of a manually entered spray.
    ///
    /// A spray typed in here is every bit as real an application as one built in
    /// the Spray Calculator, so it must not be left chemistry-less purely because
    /// of which screen the operator used.
    ///
    /// Name matching is deliberately DISABLED. Every line is either bound to a
    /// Saved Chemical the operator picked — where the identifier is the evidence —
    /// or it is an explicit manual product, where a typed string is a deliberate
    /// off-library entry. Quietly resolving `"Amistar"` to `"Amistar 250 SC"`
    /// would attach one product's verified chemistry to a different product's
    /// spray, which is worse than recording the application honestly unresolved.
    private func tanksWithCapturedChemistry() -> [SprayTank] {
        let library = store.savedChemicals
        let capturedAt = Date()
        return tanks.map { tank in
            var tank = tank
            tank.chemicals = tank.chemicals.map { chemical in
                var chemical = chemical
                let resolution = ChemicalSnapshotCapture.captureForNewApplication(
                    savedChemicalId: chemical.savedChemicalId,
                    productName: chemical.name,
                    library: library,
                    at: capturedAt,
                    allowNameMatch: false
                )
                chemical.savedChemicalId = resolution.savedChemicalId
                chemical.chemicalSnapshot = resolution.snapshot
                return chemical
            }
            return tank
        }
    }

    /// Treated blocks. Multi-select, because one application legitimately covers
    /// several blocks and must stay ONE spray record.
    private var blocksSection: some View {
        Section {
            if availableBlocks.isEmpty {
                Text("No blocks available for this vineyard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableBlocks) { block in
                    Button {
                        if selectedBlockIds.contains(block.id) {
                            selectedBlockIds.remove(block.id)
                        } else {
                            selectedBlockIds.insert(block.id)
                        }
                    } label: {
                        HStack {
                            Text(block.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedBlockIds.contains(block.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Selected")
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Blocks treated")
        } footer: {
            // Stated plainly rather than blocked. An existing record whose blocks
            // were never recorded must not be forced into a fabricated selection
            // just to let someone correct a wind speed — but the consequence is
            // named so it is a choice, not an accident.
            if selectedBlockIds.isEmpty {
                Text("Blocks not recorded. This spray will not appear in any block's history.")
            } else {
                Text("^[\(selectedBlockIds.count) block](inflect: true) recorded for this application.")
            }
        }
    }

    private func saveRecord() {
        // Only a NEW record captures chemistry. Editing an existing spray keeps
        // its frozen snapshots verbatim: re-capturing on save would rewrite
        // history with today's Chemical Store every time someone corrected a
        // wind speed. This mirrors Android's `refreshSnapshots = !isEdit`.
        let tanksToSave = existingRecord == nil ? tanksWithCapturedChemistry() : tanks
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
            tanks: tanksToSave,
            notes: notes,
            numberOfFansJets: numberOfFansJets,
            averageSpeed: Double(averageSpeedText),
            equipmentType: equipmentType,
            tractor: tractor,
            tractorGear: tractorGear,
            machineId: machineId,
            tractorId: tractorId,
            sprayEquipmentId: sprayEquipmentId,
            isTemplate: existingRecord?.isTemplate ?? false,
            // Attribution is recorded here, and the rest of any existing frozen
            // snapshot is carried through verbatim. Rebuilding the snapshot from
            // scratch would wipe the calculated geometry off a record that was
            // originally produced by the guided calculator, so only the block
            // attribution is replaced — an explicit factual correction (§16),
            // never a recomputation from today's vineyard.
            applicationGeometry: (existingRecord?.applicationGeometry ?? SprayApplicationSnapshot())
                .withBlocks(attributionBlocks)
        )
        if existingRecord != nil {
            store.updateSprayRecord(record)
        } else {
            store.addSprayRecord(record)
        }
        dismiss()
    }
}
