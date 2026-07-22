import SwiftUI

/// Vineyard-level "Region & Units" settings.
///
/// These settings are the organisation-level source of truth for how vineyard
/// records are *displayed and exported* — they never rewrite stored records.
/// Values are read from the synced `AppSettings.regionSettings` (which itself
/// is hydrated from `get_vineyard_region_settings`) and saved back through
/// `setVineyardRegionSettings`.
///
/// Editing is owner/manager only (`accessControl.canChangeSettings`). Staff and
/// operators see a read-only view; the server RPC also enforces this.
///
/// Any missing/null value continues to fall back to Australian defaults, so
/// existing AU/NZ vineyards behave exactly as before unless explicitly changed.
struct RegionUnitsSettingsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl

    private let vineyardRepository: any VineyardRepositoryProtocol = SupabaseVineyardRepository()

    // Editable working copy of the contract.
    @State private var countryCode: String = "AU"
    @State private var currencyCode: String = "AUD"
    @State private var areaUnit: AreaUnit = .hectares
    @State private var volumeUnit: VolumeUnit = .litres
    @State private var distanceUnit: DistanceSystem = .metric
    @State private var fuelUnit: FuelUnit = .litres
    @State private var sprayRateAreaUnit: SprayRateAreaUnit = .hectare
    @State private var dateFormat: RegionDateFormat = .dayMonthYear
    @State private var terminologyRegion: TerminologyRegion = .auNz

    @State private var isSaving: Bool = false
    @State private var isRefreshing: Bool = false
    @State private var savedFeedback: Bool = false
    @State private var errorMessage: String?
    @State private var pendingCountry: RegionCountry?

    private var canEdit: Bool { accessControl.canChangeSettings }

    var body: some View {
        Form {
            infoSection

            countrySection
            currencySection
            unitsSection
            formattingSection
            terminologySection

            if !canEdit {
                Section {
                    Label(
                        "Only vineyard owners and managers can change region and unit settings.",
                        systemImage: "lock.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Region & Units")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .sensoryFeedback(.success, trigger: savedFeedback)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                    }
                }
            }
        }
        .onAppear(perform: loadFromSettings)
        .task { await refreshFromServer() }
        .alert("Apply recommended defaults?", isPresented: applyDefaultsBinding, presenting: pendingCountry) { country in
            Button("Apply Defaults") { applyRecommendedDefaults(for: country) }
            Button("Keep Current Settings", role: .cancel) { applyCountryOnly(country) }
        } message: { country in
            Text("Set currency, units, date format and terminology to the recommended defaults for \(country.displayName)? Your current choices will be replaced. Choose \"Keep Current Settings\" to change only the country.")
        }
        .alert("Couldn't Save", isPresented: errorBinding, presenting: errorMessage) { _ in
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Sections

    private var infoSection: some View {
        Section {
            Text("Region and unit settings control how vineyard records are displayed and exported. Changing these settings does not rewrite existing spray, fuel, task, maintenance, equipment, or costing records.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var countrySection: some View {
        Section {
            Picker("Country", selection: countryPickerBinding) {
                ForEach(RegionCountry.allCases) { country in
                    Text(country.displayName).tag(country)
                }
            }
            .disabled(!canEdit)
        } header: {
            Text("Country")
        } footer: {
            Text("Changing the country suggests recommended defaults for that region. You can apply them or keep your current choices.")
        }
    }

    private var currencySection: some View {
        Section("Currency") {
            Picker("Currency", selection: $currencyCode) {
                ForEach(RegionCurrency.allCases) { currency in
                    Text(currency.displayName).tag(currency.code)
                }
            }
            .disabled(!canEdit)
        }
    }

    private var unitsSection: some View {
        Section("Units") {
            Picker("Area", selection: $areaUnit) {
                Text("Hectares (ha)").tag(AreaUnit.hectares)
                Text("Acres (ac)").tag(AreaUnit.acres)
            }
            Picker("Volume", selection: $volumeUnit) {
                Text("Litres (L)").tag(VolumeUnit.litres)
                Text("Gallons (gal)").tag(VolumeUnit.gallons)
            }
            Picker("Distance", selection: $distanceUnit) {
                Text("Metric (km)").tag(DistanceSystem.metric)
                Text("Imperial (mi)").tag(DistanceSystem.imperial)
            }
            Picker("Fuel", selection: $fuelUnit) {
                Text("Litres (L)").tag(FuelUnit.litres)
                Text("Gallons (gal)").tag(FuelUnit.gallons)
            }
            Picker("Spray Rate Area", selection: $sprayRateAreaUnit) {
                Text("Per Hectare (/ha)").tag(SprayRateAreaUnit.hectare)
                Text("Per Acre (/ac)").tag(SprayRateAreaUnit.acre)
            }
        }
        .disabled(!canEdit)
    }

    private var formattingSection: some View {
        Section {
            Picker("Date Format", selection: $dateFormat) {
                ForEach(RegionDateFormat.allCases, id: \.self) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .disabled(!canEdit)
        } header: {
            Text("Date Format")
        } footer: {
            Text("Timezone is managed under Vineyard Location and is shared across the organisation.")
        }
    }

    private var terminologySection: some View {
        Section("Terminology") {
            Picker("Terminology Region", selection: $terminologyRegion) {
                ForEach(TerminologyRegion.allCases, id: \.self) { region in
                    Text(region.displayLabel).tag(region)
                }
            }
            .disabled(!canEdit)
        }
    }

    // MARK: - Bindings

    /// Intercepts country changes so we can offer recommended defaults rather
    /// than silently overwriting the other choices.
    private var countryPickerBinding: Binding<RegionCountry> {
        Binding(
            get: { RegionCountry(rawValue: countryCode) ?? .australia },
            set: { newValue in
                guard newValue.rawValue != countryCode else { return }
                pendingCountry = newValue
            }
        )
    }

    private var applyDefaultsBinding: Binding<Bool> {
        Binding(
            get: { pendingCountry != nil },
            set: { if !$0 { pendingCountry = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - Country defaults

    /// Replaces all unit/currency/date/terminology choices with the region
    /// recommendations after explicit confirmation.
    private func applyRecommendedDefaults(for country: RegionCountry) {
        let preset = country.recommendedPreset
        countryCode = country.rawValue
        currencyCode = preset.currencyCode
        areaUnit = preset.areaUnit
        volumeUnit = preset.volumeUnit
        distanceUnit = preset.distanceUnit
        fuelUnit = preset.fuelUnit
        sprayRateAreaUnit = preset.sprayRateAreaUnit
        dateFormat = preset.dateFormat
        terminologyRegion = preset.terminologyRegion
        pendingCountry = nil
    }

    /// Changes only the country, leaving the user's other choices intact.
    private func applyCountryOnly(_ country: RegionCountry) {
        countryCode = country.rawValue
        pendingCountry = nil
    }

    // MARK: - Load / Save

    private func loadFromSettings() {
        let region = store.settings.regionSettings
        countryCode = region.countryCode
        currencyCode = region.currencyCode
        areaUnit = region.area
        volumeUnit = region.volume
        distanceUnit = region.distance
        fuelUnit = region.fuel
        sprayRateAreaUnit = region.sprayRateArea
        dateFormat = region.dateStyle
        terminologyRegion = region.terminology
    }

    /// Pull the authoritative server values directly when the screen opens, so
    /// settings saved on the Lovable portal or another device are reflected
    /// immediately — not just after a background sync. The merge keeps AU
    /// defaults for any null server field, then the working copy is reloaded.
    private func refreshFromServer() async {
        guard !isRefreshing, let vineyardId = store.selectedVineyardId else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard let remote = try await vineyardRepository.getVineyardRegionSettings(vineyardId: vineyardId) else { return }
            store.applyRemoteVineyardRegionSettings(remote, vineyardId: vineyardId)
            // Don't clobber in-progress edits the user is making.
            guard !isSaving, pendingCountry == nil else { return }
            loadFromSettings()
        } catch {
            // Offline / RPC missing — keep the cached local values already shown.
        }
    }

    private func save() async {
        guard canEdit, let vineyardId = store.selectedVineyardId else { return }
        isSaving = true
        defer { isSaving = false }

        // Preserve the existing shared timezone — it is managed elsewhere.
        let timezone = store.settings.regionSettings.timezone

        let payload = BackendVineyardRegionSettings(
            vineyardId: vineyardId,
            countryCode: countryCode,
            currencyCode: currencyCode,
            timezone: timezone,
            areaUnit: areaUnit.rawValue,
            volumeUnit: volumeUnit.rawValue,
            distanceUnit: distanceUnit.rawValue,
            fuelUnit: fuelUnit.rawValue,
            sprayRateAreaUnit: sprayRateAreaUnit.rawValue,
            dateFormat: dateFormat.rawValue,
            terminologyRegion: terminologyRegion.rawValue
        )

        do {
            let saved = try await vineyardRepository.setVineyardRegionSettings(payload)
            // Merge the authoritative server response back into local settings.
            store.applyRemoteVineyardRegionSettings(saved, vineyardId: vineyardId)
            savedFeedback.toggle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Country options

/// The initial set of supported markets, each with a recommended unit/currency
/// preset that the user can opt into when switching country.
nonisolated enum RegionCountry: String, CaseIterable, Identifiable, Sendable {
    case australia = "AU"
    case newZealand = "NZ"
    case unitedStates = "US"
    case canada = "CA"
    case unitedKingdom = "GB"
    case southAfrica = "ZA"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .australia: "Australia"
        case .newZealand: "New Zealand"
        case .unitedStates: "United States"
        case .canada: "Canada"
        case .unitedKingdom: "United Kingdom"
        case .southAfrica: "South Africa"
        }
    }

    nonisolated struct Preset: Sendable {
        let currencyCode: String
        let areaUnit: AreaUnit
        let volumeUnit: VolumeUnit
        let distanceUnit: DistanceSystem
        let fuelUnit: FuelUnit
        let sprayRateAreaUnit: SprayRateAreaUnit
        let dateFormat: RegionDateFormat
        let terminologyRegion: TerminologyRegion
    }

    var recommendedPreset: Preset {
        switch self {
        case .australia:
            Preset(currencyCode: "AUD", areaUnit: .hectares, volumeUnit: .litres, distanceUnit: .metric, fuelUnit: .litres, sprayRateAreaUnit: .hectare, dateFormat: .dayMonthYear, terminologyRegion: .auNz)
        case .newZealand:
            Preset(currencyCode: "NZD", areaUnit: .hectares, volumeUnit: .litres, distanceUnit: .metric, fuelUnit: .litres, sprayRateAreaUnit: .hectare, dateFormat: .dayMonthYear, terminologyRegion: .auNz)
        case .unitedStates:
            Preset(currencyCode: "USD", areaUnit: .acres, volumeUnit: .gallons, distanceUnit: .imperial, fuelUnit: .gallons, sprayRateAreaUnit: .acre, dateFormat: .monthDayYear, terminologyRegion: .us)
        case .canada:
            Preset(currencyCode: "CAD", areaUnit: .hectares, volumeUnit: .litres, distanceUnit: .metric, fuelUnit: .litres, sprayRateAreaUnit: .hectare, dateFormat: .isoYearMonthDay, terminologyRegion: .us)
        case .unitedKingdom:
            Preset(currencyCode: "GBP", areaUnit: .hectares, volumeUnit: .litres, distanceUnit: .metric, fuelUnit: .litres, sprayRateAreaUnit: .hectare, dateFormat: .dayMonthYear, terminologyRegion: .uk)
        case .southAfrica:
            Preset(currencyCode: "ZAR", areaUnit: .hectares, volumeUnit: .litres, distanceUnit: .metric, fuelUnit: .litres, sprayRateAreaUnit: .hectare, dateFormat: .dayMonthYear, terminologyRegion: .za)
        }
    }
}

// MARK: - Currency options

nonisolated enum RegionCurrency: String, CaseIterable, Identifiable, Sendable {
    case aud = "AUD"
    case nzd = "NZD"
    case usd = "USD"
    case cad = "CAD"
    case gbp = "GBP"
    case zar = "ZAR"

    var id: String { rawValue }
    var code: String { rawValue }

    var displayName: String {
        switch self {
        case .aud: "Australian Dollar (AUD)"
        case .nzd: "New Zealand Dollar (NZD)"
        case .usd: "US Dollar (USD)"
        case .cad: "Canadian Dollar (CAD)"
        case .gbp: "Pound Sterling (GBP)"
        case .zar: "South African Rand (ZAR)"
        }
    }
}

// MARK: - Terminology display

nonisolated extension TerminologyRegion {
    var displayLabel: String {
        switch self {
        case .auNz: "Australia / New Zealand"
        case .us: "United States / Canada"
        case .uk: "United Kingdom"
        case .za: "South Africa"
        }
    }
}
