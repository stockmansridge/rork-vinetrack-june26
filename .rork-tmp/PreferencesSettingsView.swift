import SwiftUI

struct PreferencesSettingsView: View {
    @Environment(DataStore.self) private var store

    var body: some View {
        Form {
            appearanceSection
            seasonSection
            trackingSection
            fillTimerSection
            yieldEstimationSection
            growthStageSection
            photoSection
            timezoneSection
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var seasonSection: some View {
        Section {
            Picker("Season Start Month", selection: Binding(
                get: { store.settings.seasonStartMonth },
                set: { newVal in
                    var s = store.settings
                    s.seasonStartMonth = newVal
                    store.updateSettings(s)
                }
            )) {
                ForEach(1...12, id: \.self) { month in
                    Text(monthName(month)).tag(month)
                }
            }

            Stepper("Start Day: \(store.settings.seasonStartDay)", value: Binding(
                get: { store.settings.seasonStartDay },
                set: { newVal in
                    var s = store.settings
                    s.seasonStartDay = newVal
                    store.updateSettings(s)
                }
            ), in: 1...28)
        } header: {
            Text("Growing Season")
        } footer: {
            Text("Set when your growing season begins each year. Reporting for each vintage starts on this date and runs until the same date the following year.")
        }
    }

    private var trackingSection: some View {
        Section {
            Toggle("Row Tracking", isOn: Binding(
                get: { store.settings.rowTrackingEnabled },
                set: { newVal in
                    var s = store.settings
                    s.rowTrackingEnabled = newVal
                    store.updateSettings(s)
                }
            ))

            if store.settings.rowTrackingEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tracking Interval: \(Int(store.settings.rowTrackingInterval))s")
                        .font(.subheadline)
                    Slider(value: Binding(
                        get: { store.settings.rowTrackingInterval },
                        set: { newVal in
                            var s = store.settings
                            s.rowTrackingInterval = newVal
                            store.updateSettings(s)
                        }
                    ), in: 1...30, step: 1)
                }
            }
        } header: {
            Text("Row Tracking")
        } footer: {
            Text("Controls how frequently location points are recorded during a trip.")
        }
    }

    private var fillTimerSection: some View {
        Section {
            Toggle("Tank Fill Timer", isOn: Binding(
                get: { store.settings.fillTimerEnabled },
                set: { newVal in
                    var s = store.settings
                    s.fillTimerEnabled = newVal
                    store.updateSettings(s)
                }
            ))
        } header: {
            Text("Fill Timer")
        } footer: {
            Text("When enabled, a Start Fill button appears during spray trips to time how long each tank fill takes. Fill durations are recorded in the spray sheet and PDF export.")
        }
    }

    private var yieldEstimationSection: some View {
        Section {
            Stepper("Samples per Ha: \(store.settings.samplesPerHectare)", value: Binding(
                get: { store.settings.samplesPerHectare },
                set: { newVal in
                    var s = store.settings
                    s.samplesPerHectare = newVal
                    store.updateSettings(s)
                }
            ), in: 1...100)
        } header: {
            Text("Yield Estimation")
        } footer: {
            Text("Number of vine sample sites to generate per hectare when creating yield estimation sample points.")
        }
    }

    private var photoSection: some View {
        Section {
            Toggle("Auto Photo Prompt", isOn: Binding(
                get: { store.settings.autoPhotoPrompt },
                set: { newVal in
                    var s = store.settings
                    s.autoPhotoPrompt = newVal
                    store.updateSettings(s)
                }
            ))
        } header: {
            Text("Photos")
        } footer: {
            Text("When enabled, a photo picker will appear each time you drop a pin so you can attach a photo.")
        }
    }

    private var timezoneSection: some View {
        Section {
            NavigationLink {
                TimezonePicker(selectedTimezone: Binding(
                    get: { store.settings.timezone },
                    set: { newVal in
                        var s = store.settings
                        s.timezone = newVal
                        store.updateSettings(s)
                    }
                ))
            } label: {
                LabeledContent("Timezone", value: store.settings.timezone.replacingOccurrences(of: "_", with: " "))
            }
        } header: {
            Text("Timezone")
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: Binding(
                get: { store.settings.appearance },
                set: { newVal in
                    var s = store.settings
                    s.appearance = newVal
                    store.updateSettings(s)
                }
            )) {
                ForEach(AppAppearance.allCases, id: \.self) { option in
                    Label(option.displayName, systemImage: option.iconName).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Display")
        } footer: {
            Text("Choose how VineTrack appears. System matches your device setting.")
        }
    }

    private var growthStageSection: some View {
        Section {
            Toggle("E-L Stage Confirmation", isOn: Binding(
                get: { store.settings.elConfirmationEnabled },
                set: { newVal in
                    var s = store.settings
                    s.elConfirmationEnabled = newVal
                    store.updateSettings(s)
                }
            ))
        } header: {
            Text("Growth Stages")
        } footer: {
            Text("When enabled, selecting a growth stage shows a reference image for visual confirmation before applying.")
        }
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        return formatter.monthSymbols[month - 1]
    }
}
