import SwiftUI

struct AlertSettingsView: View {
    @Environment(AlertService.self) private var alertService
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(\.dismiss) private var dismiss

    @State private var draft: BackendAlertPreferences?
    @State private var isSaving: Bool = false

    private var canEdit: Bool { accessControl.canChangeSettings }

    var body: some View {
        Form {
            if let prefs = draft {
                editor(prefs)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Alerts & Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(!canEdit || draft == nil || isSaving)
            }
        }
        .task {
            if draft == nil {
                if let existing = alertService.preferences {
                    draft = existing
                } else if let vid = store.selectedVineyardId {
                    draft = BackendAlertPreferences.defaults(for: vid)
                }
            }
        }
    }

    @ViewBuilder
    private func editor(_ prefs: BackendAlertPreferences) -> some View {
        let binding = Binding<BackendAlertPreferences>(
            get: { draft ?? prefs },
            set: { draft = $0 }
        )

        Section {
            Toggle("Aged pin alerts", isOn: binding.agedPinAlertsEnabled)
                .disabled(!canEdit)
            Stepper(
                "Age threshold: \(binding.wrappedValue.agedPinDays) days",
                value: binding.agedPinDays,
                in: 1...60
            )
            .disabled(!canEdit || !binding.wrappedValue.agedPinAlertsEnabled)
        } header: {
            Text("Pins")
        } footer: {
            Text("Aged pin alerts track unresolved repair and growth pins. Notified when pins remain unresolved longer than the threshold.")
        }

        Section {
            Toggle("Irrigation alerts", isOn: binding.irrigationAlertsEnabled)
                .disabled(!canEdit)
            Stepper(
                "Forecast window: \(binding.wrappedValue.irrigationForecastDays) days",
                value: binding.irrigationForecastDays,
                in: 1...14
            )
            .disabled(!canEdit || !binding.wrappedValue.irrigationAlertsEnabled)
            HStack {
                Text("Deficit threshold (mm)")
                Spacer()
                TextField("mm", value: binding.irrigationDeficitThresholdMm, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(!canEdit || !binding.wrappedValue.irrigationAlertsEnabled)
            }
        } header: {
            Text("Irrigation")
        } footer: {
            Text("Irrigation alerts use forecast ET, forecast rain and your configured irrigation data to estimate deficit over the forecast window.")
        }

        Section {
            Toggle("Weather alerts", isOn: binding.weatherAlertsEnabled)
                .disabled(!canEdit)
            HStack {
                Text("Rain (mm)")
                Spacer()
                TextField("mm", value: binding.rainAlertThresholdMm, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(!canEdit || !binding.wrappedValue.weatherAlertsEnabled)
            }
            HStack {
                Text("Wind (km/h)")
                Spacer()
                TextField("km/h", value: binding.windAlertThresholdKmh, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(!canEdit || !binding.wrappedValue.weatherAlertsEnabled)
            }
            HStack {
                Text("Frost below (°C)")
                Spacer()
                TextField("°C", value: binding.frostAlertThresholdC, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(!canEdit || !binding.wrappedValue.weatherAlertsEnabled)
            }
            HStack {
                Text("Heat above (°C)")
                Spacer()
                TextField("°C", value: binding.heatAlertThresholdC, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(!canEdit || !binding.wrappedValue.weatherAlertsEnabled)
            }
        } header: {
            Text("Weather")
        } footer: {
            Text("Weather alerts use forecast rain, wind, heat and frost thresholds. Tapping a weather alert opens the Irrigation Advisor.")
        }

        Section {
            Toggle("Spray job reminders", isOn: binding.sprayJobRemindersEnabled)
                .disabled(!canEdit)
        } header: {
            Text("Spray")
        } footer: {
            Text("Reminders for scheduled spray records due today or tomorrow.")
        }

        Section {
            Toggle("Disease risk alerts", isOn: binding.diseaseAlertsEnabled)
                .disabled(!canEdit)
            Toggle("Downy mildew", isOn: binding.diseaseDownyEnabled)
                .disabled(!canEdit || !binding.wrappedValue.diseaseAlertsEnabled)
            Toggle("Powdery mildew", isOn: binding.diseasePowderyEnabled)
                .disabled(!canEdit || !binding.wrappedValue.diseaseAlertsEnabled)
            Toggle("Botrytis", isOn: binding.diseaseBotrytisEnabled)
                .disabled(!canEdit || !binding.wrappedValue.diseaseAlertsEnabled)
            weatherSourceLink
        } header: {
            Text("Disease risk")
        } footer: {
            Text("Disease alerts use forecast humidity, dew point, rainfall and temperature with an estimated wetness proxy (rain, RH ≥ 90%, or temperature within 2°C of dew point). They are not a substitute for measured leaf wetness; if a measured sensor is added later, it can override the proxy per vineyard.")
        }

        Section {
            Toggle("Push notifications", isOn: binding.pushEnabled)
                .disabled(true)
        } header: {
            Text("Push")
        } footer: {
            Text("Push notifications are coming later. In-app alerts are active and update on app launch and pull to refresh.")
        }

        if !canEdit {
            Section {
                Text("Only the vineyard owner or manager can change alert preferences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var weatherSourceLink: some View {
        let label: String = {
            guard let vid = store.selectedVineyardId else { return "Automatic Forecast" }
            return WeatherProviderResolver.resolve(
                for: vid,
                weatherStationId: store.settings.weatherStationId
            ).primaryLabel
        }()
        NavigationLink {
            WeatherDataSettingsView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cloud.sun.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weather source")
                        .font(.subheadline)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Manage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    private func save() async {
        guard canEdit, let prefs = draft else { return }
        isSaving = true
        defer { isSaving = false }
        await alertService.savePreferences(prefs)
        dismiss()
    }
}
