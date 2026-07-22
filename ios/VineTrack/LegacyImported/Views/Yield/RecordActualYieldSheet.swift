import SwiftUI

struct RecordActualYieldSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(HistoricalYieldRecordSyncService.self) private var historicalYieldSync

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var season: String = ""
    @State private var selectedPaddockId: UUID?
    @State private var variety: String = ""
    @State private var actualYieldText: String = ""
    @State private var notes: String = ""
    @FocusState private var yieldFocused: Bool

    private var paddocks: [Paddock] {
        store.orderedPaddocks
    }

    private var selectedPaddock: Paddock? {
        guard let id = selectedPaddockId else { return nil }
        return paddocks.first(where: { $0.id == id })
    }

    private var parsedYield: Double? {
        let trimmed = actualYieldText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private var canSave: Bool {
        guard let yield = parsedYield, yield >= 0 else { return false }
        return selectedPaddockId != nil && store.selectedVineyardId != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $year, in: 2000...2100) {
                        HStack {
                            Text("Year")
                            Spacer()
                            Text("\(year, format: .number.grouping(.never))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("Season (optional)", text: $season)
                } header: {
                    Text("Season")
                }

                Section {
                    if paddocks.isEmpty {
                        Text("No blocks available. Add a block first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Block", selection: $selectedPaddockId) {
                            Text("Select a block").tag(UUID?.none)
                            ForEach(paddocks, id: \.id) { p in
                                Text(p.name).tag(UUID?.some(p.id))
                            }
                        }
                    }
                    TextField("Variety (optional)", text: $variety)
                } header: {
                    Text("Block & Variety")
                } footer: {
                    if let p = selectedPaddock, p.areaHectares > 0 {
                        Text("Area: \(fmt.formatArea(hectares: p.areaHectares))")
                    }
                }

                Section {
                    HStack {
                        TextField("0.00", text: $actualYieldText)
                            .keyboardType(.decimalPad)
                            .focused($yieldFocused)
                        Text("t")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Actual Yield (tonnes)")
                } footer: {
                    if let yield = parsedYield, let p = selectedPaddock, p.areaHectares > 0 {
                        Text(fmt.formatYieldPerArea(perHectare: yield / p.areaHectares))
                    } else {
                        Text("Used by Cost Reports to calculate cost per tonne.")
                    }
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes (optional)")
                }
            }
            .navigationTitle("Record Actual Yield")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if selectedPaddockId == nil {
                    selectedPaddockId = paddocks.first?.id
                }
                yieldFocused = true
            }
        }
    }

    private func save() {
        guard let vid = store.selectedVineyardId,
              let paddock = selectedPaddock,
              let yield = parsedYield else { return }

        let now = Date()
        let trimmedVariety = variety.trimmingCharacters(in: .whitespaces)
        let paddockName: String
        if trimmedVariety.isEmpty {
            paddockName = paddock.name
        } else {
            paddockName = "\(paddock.name) — \(trimmedVariety)"
        }

        let blockResult = HistoricalBlockResult(
            paddockId: paddock.id,
            paddockName: paddockName,
            areaHectares: paddock.areaHectares,
            yieldTonnes: yield,
            yieldPerHectare: paddock.areaHectares > 0 ? yield / paddock.areaHectares : 0,
            averageBunchesPerVine: 0,
            averageBunchWeightGrams: 0,
            totalVines: paddock.effectiveVineCount,
            samplesRecorded: 0,
            damageFactor: 1.0,
            actualYieldTonnes: yield,
            actualRecordedAt: now
        )

        let record = HistoricalYieldRecord(
            vineyardId: vid,
            season: season.trimmingCharacters(in: .whitespaces),
            year: year,
            archivedAt: now,
            blockResults: [blockResult],
            totalYieldTonnes: yield,
            totalAreaHectares: paddock.areaHectares,
            notes: notes.trimmingCharacters(in: .whitespaces)
        )

        store.addHistoricalYieldRecord(record)
        Task { await historicalYieldSync.syncForSelectedVineyard() }
    }
}
