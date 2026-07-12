import SwiftUI

struct OperationPreferencesView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    @State private var samplesPerHectareText: String = ""
    @State private var fillTimerEnabled: Bool = true
    @State private var elConfirmationEnabled: Bool = true
    @State private var seasonFuelCostText: String = ""
    @State private var seasonStartMonth: Int = 7
    @State private var seasonStartDay: Int = 1
    @State private var isSavingSeason: Bool = false
    @State private var seasonSaveError: String?
    @State private var seasonSaveTask: Task<Void, Never>?

    /// Shared season settings live on `public.vineyards` (sql/108) and may
    /// only be changed by owners/managers. Everyone else sees them read-only.
    private var canEditSeason: Bool { accessControl?.canManageSetup ?? false }

    private let vineyardRepository: any VineyardRepositoryProtocol = SupabaseVineyardRepository()

    var body: some View {
        Form {
            seasonSection
            spraySection
            yieldSection
        }
        .navigationTitle("Operation Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        // Keep the pickers in step when a sync applies a newer shared value.
        .onChange(of: store.settings.seasonStartMonth) { _, newValue in
            guard seasonSaveTask == nil else { return }
            seasonStartMonth = newValue
        }
        .onChange(of: store.settings.seasonStartDay) { _, newValue in
            guard seasonSaveTask == nil else { return }
            seasonStartDay = newValue
        }
        .alert("Season Settings", isPresented: Binding(
            get: { seasonSaveError != nil },
            set: { if !$0 { seasonSaveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(seasonSaveError ?? "")
        }
    }

    private var seasonSection: some View {
        Section {
            Picker("Season Start Month", selection: $seasonStartMonth) {
                ForEach(1...12, id: \.self) { m in
                    Text(monthName(m)).tag(m)
                }
            }
            .disabled(!canEditSeason || isSavingSeason)
            .onChange(of: seasonStartMonth) { oldValue, newValue in
                guard canEditSeason, newValue != store.settings.seasonStartMonth else { return }
                if seasonStartDay > maxDay(for: newValue) {
                    seasonStartDay = maxDay(for: newValue)
                }
                scheduleSeasonSave()
            }

            Stepper(value: $seasonStartDay, in: 1...maxDay(for: seasonStartMonth)) {
                HStack {
                    Text("Season Start Day")
                    Spacer()
                    if isSavingSeason {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }
                    Text("\(seasonStartDay)")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!canEditSeason || isSavingSeason)
            .onChange(of: seasonStartDay) { _, newValue in
                guard canEditSeason, newValue != store.settings.seasonStartDay else { return }
                scheduleSeasonSave()
            }

            Toggle("Confirm E-L Stage", isOn: $elConfirmationEnabled)
                .onChange(of: elConfirmationEnabled) { _, newValue in
                    var s = store.settings
                    s.elConfirmationEnabled = newValue
                    store.updateSettings(s)
                }
        } header: {
            Text("Growing Season & E-L")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The season start is shared with everyone in this vineyard and is used by the E-L growth stage report and \u{201C}This Season\u{201D} totals.")
                Text("Changing the season start affects how VineTrack groups records into vintages and \u{201C}This Season\u{201D} reports for everyone in this vineyard.")
                if !canEditSeason {
                    Text("Only vineyard owners and managers can change the shared season settings.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var spraySection: some View {
        Section {
            Toggle("Tank Fill Timer", isOn: $fillTimerEnabled)
                .onChange(of: fillTimerEnabled) { _, newValue in
                    var s = store.settings
                    s.fillTimerEnabled = newValue
                    store.updateSettings(s)
                }
            HStack {
                Text("Fuel Cost (per L)")
                Spacer()
                TextField("0", text: $seasonFuelCostText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onSubmit { saveFuelCost() }
            }
        } header: {
            Text("Spray / Tank")
        }
    }

    private var yieldSection: some View {
        Section {
            HStack {
                Text("Samples per Hectare")
                Spacer()
                TextField("0", text: $samplesPerHectareText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onSubmit { saveSamples() }
            }
        } header: {
            Text("Yield Estimation")
        }
    }

    private func loadSettings() {
        let s = store.settings
        samplesPerHectareText = String(s.samplesPerHectare)
        fillTimerEnabled = s.fillTimerEnabled
        elConfirmationEnabled = s.elConfirmationEnabled
        seasonFuelCostText = String(format: "%.2f", s.seasonFuelCostPerLitre)
        seasonStartMonth = s.seasonStartMonth
        seasonStartDay = s.seasonStartDay
    }

    // MARK: - Shared season save

    /// Debounces rapid month/day changes into a single Supabase write. The
    /// local cache is only updated after the server confirms the save; on
    /// failure the pickers revert and an error alert is shown — never a
    /// silent `try?` for the shared setting.
    private func scheduleSeasonSave() {
        seasonSaveTask?.cancel()
        let month = seasonStartMonth
        let day = seasonStartDay
        seasonSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await saveSeason(month: month, day: day)
            seasonSaveTask = nil
        }
    }

    @MainActor
    private func saveSeason(month: Int, day: Int) async {
        guard let vineyardId = store.selectedVineyardId else { return }
        guard month >= 1, month <= 12, day >= 1, day <= maxDay(for: month) else {
            seasonSaveError = "That day is not valid for the selected month."
            seasonStartMonth = store.settings.seasonStartMonth
            seasonStartDay = store.settings.seasonStartDay
            return
        }
        isSavingSeason = true
        defer { isSavingSeason = false }
        do {
            let saved = try await vineyardRepository.setVineyardSeasonSettings(
                vineyardId: vineyardId,
                seasonStartMonth: month,
                seasonStartDay: day
            )
            store.applyRemoteVineyardSeasonSettings(
                month: saved.seasonStartMonth,
                day: saved.seasonStartDay,
                vineyardId: vineyardId
            )
            SeasonSettingsMigrationTracker.markDecided(vineyardId)
            seasonStartMonth = saved.seasonStartMonth
            seasonStartDay = saved.seasonStartDay
        } catch {
            seasonSaveError = "Could not save the shared season settings. Check your connection and try again."
            seasonStartMonth = store.settings.seasonStartMonth
            seasonStartDay = store.settings.seasonStartDay
        }
    }

    private func saveSamples() {
        guard let v = Int(samplesPerHectareText), v > 0 else { return }
        var s = store.settings
        s.samplesPerHectare = v
        store.updateSettings(s)
    }

    private func saveFuelCost() {
        guard let v = Double(seasonFuelCostText), v >= 0 else { return }
        var s = store.settings
        s.seasonFuelCostPerLitre = v
        store.updateSettings(s)
    }

    private func monthName(_ m: Int) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.standaloneMonthSymbols[max(0, min(11, m - 1))]
    }

    private func maxDay(for month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return 29
        default: return 31
        }
    }
}
