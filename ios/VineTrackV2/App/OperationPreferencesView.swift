import SwiftUI

struct OperationPreferencesView: View {
    @Environment(MigratedDataStore.self) private var store

    @State private var samplesPerHectareText: String = ""
    @State private var fillTimerEnabled: Bool = true
    @State private var elConfirmationEnabled: Bool = true
    @State private var seasonFuelCostText: String = ""
    @State private var seasonStartMonth: Int = 7
    @State private var seasonStartDay: Int = 1

    var body: some View {
        Form {
            seasonSection
            spraySection
            yieldSection
        }
        .navigationTitle("Operation Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
    }

    private var seasonSection: some View {
        Section {
            Picker("Season Start Month", selection: $seasonStartMonth) {
                ForEach(1...12, id: \.self) { m in
                    Text(monthName(m)).tag(m)
                }
            }
            .onChange(of: seasonStartMonth) { _, newValue in
                var s = store.settings
                s.seasonStartMonth = newValue
                store.updateSettings(s)
            }

            Stepper(value: $seasonStartDay, in: 1...maxDay(for: seasonStartMonth)) {
                HStack {
                    Text("Season Start Day")
                    Spacer()
                    Text("\(seasonStartDay)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: seasonStartDay) { _, newValue in
                var s = store.settings
                s.seasonStartDay = newValue
                store.updateSettings(s)
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
            Text("Season boundaries are used by the E-L growth stage report.")
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
