import SwiftUI

struct PreferencesHubView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(LocationService.self) private var locationService

    @State private var rowTrackingEnabled: Bool = true
    @State private var rowTrackingInterval: Double = 1.0
    @State private var autoPhotoPrompt: Bool = false
    @State private var appearance: AppAppearance = .system
    @State private var timezoneIdentifier: String = TimeZone.current.identifier
    @State private var aiSuggestionsEnabled: Bool = true

    @AppStorage(ScreenAwakeManager.preferenceKey) private var keepScreenAwake: Bool = true

    @State private var showTimezonePicker: Bool = false

    var body: some View {
        Form {
            appearanceSection
            tripTrackingSection
            photosSection
            aiSection
            regionalSection
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTimezonePicker) {
            TimezonePickerSheet(selected: $timezoneIdentifier) { id in
                var s = store.settings
                s.timezone = id
                store.updateSettings(s)
            }
        }
        .onAppear { loadSettings() }
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        Section {
            Picker("Display Mode", selection: $appearance) {
                ForEach(AppAppearance.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.iconName).tag(mode)
                }
            }
            .onChange(of: appearance) { _, newValue in
                var s = store.settings
                s.appearance = newValue
                store.updateSettings(s)
            }
        } header: {
            Text("Appearance")
        }
    }

    private var tripTrackingSection: some View {
        Section {
            Toggle("Row Tracking", isOn: $rowTrackingEnabled)
                .onChange(of: rowTrackingEnabled) { _, newValue in
                    var s = store.settings
                    s.rowTrackingEnabled = newValue
                    store.updateSettings(s)
                }

            HStack {
                Text("Tracking Interval")
                Spacer()
                Text(String(format: "%.1f s", rowTrackingInterval))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $rowTrackingInterval, in: 0.5...10.0, step: 0.5)
                .onChange(of: rowTrackingInterval) { _, newValue in
                    var s = store.settings
                    s.rowTrackingInterval = newValue
                    store.updateSettings(s)
                }

            Toggle("Keep screen awake during trips", isOn: $keepScreenAwake)
                .onChange(of: keepScreenAwake) { _, _ in
                    ScreenAwakeManager.shared.preferenceDidChange()
                }
        } header: {
            Text("Trip & Row Tracking")
        } footer: {
            Text("Controls how often GPS samples are recorded during an active trip, whether row guidance is shown in-field, and whether the device stays awake while a trip is running. Keeping the screen awake may use more battery.")
        }
    }

    private var photosSection: some View {
        Section {
            Toggle("Auto Photo Prompt", isOn: $autoPhotoPrompt)
                .onChange(of: autoPhotoPrompt) { _, newValue in
                    var s = store.settings
                    s.autoPhotoPrompt = newValue
                    store.updateSettings(s)
                }
        } header: {
            Text("Photos")
        } footer: {
            Text("When enabled, the app will prompt to attach a photo after dropping repair or growth pins.")
        }
    }

    private var aiSection: some View {
        Section {
            Toggle("Enable AI Suggestions", isOn: $aiSuggestionsEnabled)
                .onChange(of: aiSuggestionsEnabled) { _, newValue in
                    var s = store.settings
                    s.aiSuggestionsEnabled = newValue
                    store.updateSettings(s)
                }
        } header: {
            Text("AI Suggestions")
        } footer: {
            Text("AI suggestions are optional and must be checked against current product labels, permits, SDS, and local regulations before use.")
        }
    }

    private var regionalSection: some View {
        Section {
            Button {
                showTimezonePicker = true
            } label: {
                HStack {
                    Label("Timezone", systemImage: "globe")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(timezoneIdentifier)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } header: {
            Text("Regional")
        }
    }

    // MARK: - Helpers

    private func loadSettings() {
        let s = store.settings
        rowTrackingEnabled = s.rowTrackingEnabled
        rowTrackingInterval = s.rowTrackingInterval
        autoPhotoPrompt = s.autoPhotoPrompt
        appearance = s.appearance
        timezoneIdentifier = s.timezone
        aiSuggestionsEnabled = s.aiSuggestionsEnabled
    }
}

// MARK: - Timezone picker

private struct TimezonePickerSheet: View {
    @Binding var selected: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    private var identifiers: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(identifiers, id: \.self) { id in
                Button {
                    selected = id
                    onSelect(id)
                    dismiss()
                } label: {
                    HStack {
                        Text(id)
                            .foregroundStyle(.primary)
                        Spacer()
                        if id == selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search timezones")
            .navigationTitle("Timezone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
