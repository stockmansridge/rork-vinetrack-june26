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
    /// Whether a NEW record created here is a reusable Program Step rather than
    /// an application. Ignored when editing — an existing record's own flag
    /// always wins, so opening a Program Step to edit it can never demote it to
    /// an operational record (or promote a spray into the program).
    var createsProgramStep: Bool = false

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

    init(
        tripId: UUID,
        paddockIds: [UUID],
        existingRecord: SprayRecord? = nil,
        createsProgramStep: Bool = false
    ) {
        self.tripId = tripId
        self.paddockIds = paddockIds
        self.existingRecord = existingRecord
        self.createsProgramStep = createsProgramStep
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

    /// What this record already says it treated. Nil means "blocks not recorded".
    private var recordedBlocks: [SprayApplicationBlockSnapshot]? {
        existingRecord?.applicationGeometry?.blocks
    }

    /// Blocks the operator can choose from: every live block in the vineyard, plus
    /// any block this record already attributes that no longer exists.
    ///
    /// The second group matters — an archived block must stay visible and stay
    /// selected, or editing the wind speed would quietly drop it from a compliance
    /// record.
    private var blockChoices: [SprayFormBlockChoice] {
        let live = availableBlocks.map {
            SprayFormBlockChoice(id: $0.id, name: $0.name, isLive: true)
        }
        let liveIds = Set(live.map { $0.id.uuidString.lowercased() })
        let missing = (recordedBlocks ?? []).compactMap { block -> SprayFormBlockChoice? in
            guard !liveIds.contains(block.blockId.lowercased()),
                  let uuid = UUID(uuidString: block.blockId) else { return nil }
            return SprayFormBlockChoice(id: uuid, name: block.displayName, isLive: false)
        }
        return live + missing
    }

    /// The selection as ordered ids. `selectedBlockIds` is a `Set`, so the order is
    /// taken from the displayed list to keep two saves of the same selection
    /// byte-identical.
    private var orderedSelectedBlockIds: [String] {
        blockChoices
            .filter { selectedBlockIds.contains($0.id) }
            .map { $0.id.uuidString }
    }

    /// The attribution to persist.
    ///
    /// Delegated to `SprayManualBlockAttribution` so the three rules that decide
    /// what a compliance record says — preserve verbatim, project fresh, carry a
    /// deleted block forward — are unit tested rather than only verified by eye,
    /// and are identical on Android.
    private var attributionBlocks: [SprayApplicationBlockSnapshot]? {
        SprayManualBlockAttribution.resolve(
            selectedBlockIds: orderedSelectedBlockIds,
            recordedBlocks: recordedBlocks,
            availableBlocks: availableBlocks,
            isEdit: existingRecord != nil
        )
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
        // D2.2 — captured BEFORE the identity is overwritten, because whether a
        // dosage may survive depends entirely on whether the product changed.
        let previousChemicalId = line.savedChemicalId
        if let chosen {
            // A genuine change of product: this line referred to one saved
            // chemical and now refers to a different one.
            //
            // `nil -> chosen` is NOT counted here. An unbound line's Rate/Ha
            // and Vol/Tank fields are editable, so figures sitting on them may
            // be the operator's own; that case is governed by dimensional
            // compatibility immediately below instead.
            let isProductIdentityChange = previousChemicalId != nil
                && previousChemicalId != chosen.id
            // D2.3 — first binding of a manual line.
            //
            // A typed dosage may survive being bound to a product only while it
            // still measures the same kind of thing. Litres and millilitres are
            // one quantity written two ways and share a base of mL, so 500 base
            // is 500 mL either way and needs no conversion — only the display
            // changes, to 0.5 L/ha.
            //
            // Volume and mass are not interchangeable. 500 mL of a liquid is
            // not 500 g of a powder, and this app holds no per-dosage density
            // that could make it so. Rather than invent one, the manual figure
            // is discarded and the product's own default takes over.
            //
            // Asked BEFORE the unit is replaced — afterwards the line's original
            // dimension is gone and the question can no longer be answered.
            let isFirstBinding = previousChemicalId == nil
            let crossesDimension = !line.unit.isDimensionallyCompatible(with: chosen.unit)
            let discardsManualDosage = isFirstBinding && crossesDimension
            line.savedChemicalId = chosen.id
            line.name = chosen.name
            // D2.1 — the line adopts the PRODUCT'S unit, and does so FIRST.
            //
            // A line defaults to Litres. Binding a Kg product left that default
            // in place, so the entire line was then read in the wrong unit: the
            // Rate/Ha and Vol/Tank fields below both render through
            // `line.unit.fromBase(...)` and label themselves with `line.unit`,
            // and `displayRate`/`displayVolume` do the same on every report and
            // export. The stored magnitude could be exactly right while the
            // screen said "2.2 Litres/Ha" about a product sold in kilograms.
            //
            // Unit identity belongs to the PRODUCT, never to whichever line the
            // operator happened to open, so it is assigned before any rate is
            // interpreted, converted or displayed.
            line.unit = chosen.unit
            // D2 unit boundary. `SavedChemical.ratePerHa` is a DISPLAY-unit
            // number (2.5 for "2.5 L/ha"); `SprayChemical.ratePerHa` is BASE
            // units, as the Rate/Ha field below proves by reading it through
            // `unit.fromBase` and writing it back through `unit.toBase`.
            //
            // Copying one into the other unconverted seeded a 2.5 L/ha product
            // as 2.5 mL/ha, so picking a saved chemical pre-filled a rate a
            // thousand times too low on every litre/kilogram product.
            //
            // Converted with the SOURCE product's unit — which, after the
            // assignment above, is also the line's — never with whatever unit
            // the line was carrying beforehand.
            //
            // D2.2 — a dosage belongs to the product it was established for.
            //
            // The `== 0` guard below exists to protect an operator's typed
            // rate, but on a change of product it protected the WRONG thing: a
            // 2.5 L/ha rate held as 2500 mL survived a re-bind to a kilogram
            // product and, with D2.1 now correcting the unit, was re-read as
            // 2.5 kg/ha. Product A's dose, presented as Product B's, in a unit
            // neither of them agreed to.
            //
            // So a stale dosage is invalidated FIRST, and the new product's own
            // default is then seeded through the same guard. If the new product
            // states no default the line is left unset, which is the honest
            // answer — an operator entering a rate is a smaller failure than a
            // wrong rate they had no reason to question.
            //
            // D2.3 adds the second way a rate can be wrong for the product now
            // on the line: a manual figure whose dimension the chosen product
            // does not share. A compatible manual rate is left exactly as the
            // operator typed it and is never replaced by the store default —
            // an explicit decision outranks a default.
            if isProductIdentityChange || discardsManualDosage {
                line.ratePerHa = 0
            }
            if line.ratePerHa == 0, chosen.ratePerHa > 0 {
                line.ratePerHa = chosen.unit.toBase(chosen.ratePerHa)
            }
            // D2.3 — the tank amount is as product-specific as the rate, and
            // was the more dangerous of the two: `bind()` never touched it at
            // all, so 1078 g of a powder survived a switch to a litres product
            // and reappeared through `displayVolume` as "1.078 L" of it.
            //
            // Invalidated on the same two conditions, and deliberately NOT
            // re-seeded: `SavedChemical` carries no per-tank default. `packSize`
            // is the size of a container and `inventoryQuantity` is stock on
            // hand — neither is a dose — and it must not be fabricated from the
            // rate or the tank volume. An empty field asks the operator a
            // question; a carried-over one answers it wrongly on their behalf.
            if isProductIdentityChange || discardsManualDosage {
                line.volumePerTank = 0
            }
        } else {
            // Releasing to manual keeps the unit already on screen: there is no
            // product to take one from, and resetting it would silently restate
            // the rate the operator typed.
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
                // P0 — these two fields edit values that are STORED IN BASE
                // UNITS (grams / millilitres) but are read by an operator in
                // the product's own unit.
                //
                // They used to bind the stored number directly. For a solid
                // product that is the 1000× defect in the flesh: a 2.2 kg/ha
                // rate is held as 2200 g and rendered as "2200" beside a Kg
                // label, and 0.49 ha of it is held as 1078 g and rendered as
                // "1078" — the exact 2,200 Kg/ha and 1,080 Kg an operator
                // reported from the field. `SprayChemical` already defines
                // `displayVolume` and `displayRate` for precisely this
                // boundary; this view simply was not crossing it.
                //
                // Writes convert back with `toBase`, so what is persisted stays
                // in base units and every other reader is unaffected.
                let unit = tanks[tIdx].chemicals[cIdx].unit
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rate/Ha (\(unit.rawValue))")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("0", value: Binding(
                            get: { unit.fromBase(tanks[tIdx].chemicals[cIdx].ratePerHa) },
                            set: { tanks[tIdx].chemicals[cIdx].ratePerHa = unit.toBase($0) }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                            .font(.subheadline)
                    }
                    Divider().frame(height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vol/Tank (\(unit.rawValue))")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("0", value: Binding(
                            get: { unit.fromBase(tanks[tIdx].chemicals[cIdx].volumePerTank) },
                            set: { tanks[tIdx].chemicals[cIdx].volumePerTank = unit.toBase($0) }
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
                    // A foreign registration on a spray line: the product record
                    // is usable, but its label rates/WHP/re-entry are another
                    // jurisdiction's law — marked so they never read as valid
                    // recommendations for this vineyard's spray.
                    if case .mismatch(let registration, let vineyard) = ChemicalJurisdiction.suitability(
                        for: bound, vineyardCountry: store.selectedVineyard?.country ?? ""
                    ) {
                        ChemicalJurisdictionChip(
                            registrationCountry: registration,
                            vineyardCountry: vineyard
                        )
                    }
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

    /// The genuine Vineyard Machines — ATV, side-by-side, harvester, utility
    /// vehicle, other — offered under the Power unit picker.
    ///
    /// # Why the mirrors are filtered out
    ///
    /// A tractor added under Equipment → Tractors creates a `tractors` row AND
    /// an internal `vineyard_machines` row linked back to it through
    /// `legacyTractorId`. That mirror is plumbing: it exists so machine-aware
    /// features can address a tractor, and it is not a second asset.
    ///
    /// Reading `currentVineyardMachines` unfiltered listed every mirror beside
    /// the real tractors, so one tractor appeared TWICE in the same menu — once
    /// under "Vineyard Machines" and once under "Tractors". Worse, the two
    /// entries did different things: the mirror stored `machineId`, the real
    /// entry stored `tractorId`, so which identity a spray record carried
    /// depended on which of two identical-looking rows the operator happened to
    /// tap. Every other equipment screen already filters these out
    /// (`VineyardMachineManagementView`, `AddEditWorkTaskMachineLineView`,
    /// `AddEditMaintenanceLogView`, `EquipmentManagementView`); this picker was
    /// the one place they leaked.
    ///
    /// Tractors are still fully selectable — through the Tractors section
    /// below, which is the entry that carries the correct identity.
    private var machineOptions: [VineyardMachine] {
        SprayEquipmentOptions
            .machines(for: .powerUnit, from: store.currentVineyardMachines)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var tractorOptions: [Tractor] {
        store.currentTractors
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
                                            // ONE identity, set through the
                                            // shared rule so the two ids can
                                            // never both be populated.
                                            let selection = SprayPowerUnitSelection
                                                .vineyardMachine(m.id)
                                            machineId = selection.machineId
                                            tractorId = selection.tractorId
                                        }
                                    }
                                }
                            }
                            if !tractorOptions.isEmpty {
                                Section("Tractors") {
                                    ForEach(tractorOptions) { t in
                                        Button(t.displayName) {
                                            tractor = t.displayName
                                            let selection = SprayPowerUnitSelection.tractor(t.id)
                                            tractorId = selection.tractorId
                                            machineId = selection.machineId
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
                    TextField("Tractor or machine", text: $tractor)
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
            // POWER UNIT, not "Tractor" (task §4).
            //
            // A completed spray record legitimately supports either a tractor
            // or a vineyard machine — `spray_records` has both `tractor_id` and
            // `machine_id`, and a block sprayed off an ATV is a real record
            // this app must be able to keep. But a field offering ATVs while
            // calling itself "Tractor" teaches the operator that the two words
            // mean the same thing, which is precisely the confusion that let
            // the Portal write a vineyard machine id into `spray_jobs.tractor_id`.
            //
            // So the label states what the field actually accepts, and the
            // menu keeps the two kinds in separate, named sections. "Tractor"
            // is reserved for controls that accept a `public.tractors` row and
            // nothing else — see the Program Step editor.
            } label: { Label("Power unit", systemImage: "steeringwheel") }
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
            if blockChoices.isEmpty {
                Text("No blocks available for this vineyard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(blockChoices) { block in
                    Button {
                        if selectedBlockIds.contains(block.id) {
                            selectedBlockIds.remove(block.id)
                        } else {
                            selectedBlockIds.insert(block.id)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(block.name)
                                    .foregroundStyle(.primary)
                                if !block.isLive {
                                    // Attributed, but the block is gone. Kept and kept
                                    // selected: a completed spray is a compliance
                                    // document, not a view of today's vineyard.
                                    Text("No longer in this vineyard · kept for history")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                if existingRecord != nil, recordedBlocks == nil {
                    // A historical record. Saving other changes keeps it silent —
                    // nobody is asked to invent where a 2019 spray went.
                    Text(
                        "\(SprayBlockAttributionDisplay.notRecorded). Saving other changes keeps it " +
                        "that way — select blocks only to record a correction you know to be factual."
                    )
                } else {
                    Text(
                        "\(SprayBlockAttributionDisplay.notRecorded). This spray will not appear in " +
                        "any block's history."
                    )
                }
            } else {
                Text(
                    "^[\(selectedBlockIds.count) block](inflect: true) recorded by ID, so renaming a " +
                    "block later keeps this record intact."
                )
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
            isTemplate: existingRecord?.isTemplate ?? createsProgramStep,
            // Attribution is recorded here, and the rest of any existing frozen
            // snapshot is carried through verbatim. Rebuilding the snapshot from
            // scratch would wipe the calculated geometry off a record that was
            // originally produced by the guided calculator, so only the block
            // attribution is replaced — an explicit factual correction (§16),
            // never a recomputation from today's vineyard.
            applicationGeometry: SprayManualBlockAttribution.geometryToPersist(
                existing: existingRecord?.applicationGeometry,
                blocks: attributionBlocks
            )
        )
        if existingRecord != nil {
            store.updateSprayRecord(record)
        } else {
            store.addSprayRecord(record)
        }
        dismiss()
    }
}

/// One selectable block in the manual spray form.
///
/// `isLive` is false for a block this record already attributes that no longer
/// exists in the vineyard, which must still be shown and must stay selected.
private struct SprayFormBlockChoice: Identifiable {
    let id: UUID
    let name: String
    let isLive: Bool
}
