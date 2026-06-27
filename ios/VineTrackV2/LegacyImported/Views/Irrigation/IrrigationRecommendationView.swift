import SwiftUI

struct IrrigationRecommendationView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(SystemAdminService.self) private var systemAdmin

    @State private var selectedPaddockId: UUID?
    /// When true the advisor treats the calculation as "Whole Vineyard"
    /// (no specific block selected). Soil profile is averaged across
    /// available paddock soil profiles. Defaults to true so new users
    /// see a vineyard-wide recommendation immediately.
    @State private var useWholeVineyard: Bool = true
    @State private var showConfigSheet: Bool = false
    @State private var didLoadRecentRainSettings: Bool = false
    @State private var vineyardSoilProfiles: [BackendSoilProfile] = []
    @State private var vineyardDefaultSoilProfile: BackendSoilProfile?
    @State private var showWholeVineyardSoilEditor: Bool = false
    @State private var setupWizardCollapsed: Bool = false
    @State private var forecastService = IrrigationForecastService()

    @State private var applicationRateText: String = ""
    @State private var kcText: String = "0.65"
    @State private var efficiencyText: String = "90"
    @State private var rainEffText: String = "80"
    @State private var replacementText: String = "100"
    @State private var bufferText: String = "0"
    @State private var didLoadFromSettings: Bool = false

    @State private var manualEToOverrides: [Date: String] = [:]
    @State private var manualRainOverrides: [Date: String] = [:]
    @State private var useManualInputs: Bool = false
    @State private var forecastDuration: Int = 5
    @State private var lastUpdated: Date?
    @State private var didAutoLoad: Bool = false

    // Recent actual rainfall (preferring Davis WeatherLink when configured).
    @State private var recentRainResult: RainfallHistoryResult?
    @State private var recentRainDays: Int = 7
    @State private var includeRecentActualRain: Bool = true
    @State private var isLoadingRecentRain: Bool = false
    @State private var showWeatherSettings: Bool = false

    // Weather Setup Wizard banner — shown when neither Davis nor WU is
    // configured for the selected vineyard so new managers/owners get a
    // one-tap path to set up rainfall sources.
    @State private var showWeatherWizard: Bool = false
    @State private var wuStationConfigured: Bool = false

    // Missing rain data helper sheet — surfaced when the selected
    // actual-rain window contains no-data days OR when persisted
    // rainfall history coverage in the last 365 days is shallow.
    @State private var showMissingRainHelper: Bool = false
    @State private var didLoadWeatherWizardStatus: Bool = false

    // Soil profile (Phase 1: manual soil profile + soil buffer panel).
    @State private var paddockSoilProfile: BackendSoilProfile?
    @State private var isLoadingSoilProfile: Bool = false
    @State private var showSoilProfileEditor: Bool = false
    @State private var lastLoadedSoilPaddockId: UUID?
    private let soilProfileRepository: any SoilProfileRepositoryProtocol
        = SupabaseSoilProfileRepository()

    // Info popover state — keyed by term identifier.
    @State private var activeInfoTerm: InfoTerm?

    private enum InfoTerm: String, Identifiable, CaseIterable {
        case eto, kc, applicationRate, irrigationEfficiency
        case rainfallEffectiveness, replacement, soilBuffer, recentRain

        var id: String { rawValue }

        var title: String {
            switch self {
            case .eto: return "ETo"
            case .kc: return "Crop coefficient (Kc)"
            case .applicationRate: return "Application rate (mm/hr)"
            case .irrigationEfficiency: return "Irrigation efficiency (%)"
            case .rainfallEffectiveness: return "Rainfall effectiveness (%)"
            case .replacement: return "Replacement (%)"
            case .soilBuffer: return "Soil moisture buffer (mm)"
            case .recentRain: return "Recent actual rain (mm)"
            }
        }

        var body: String {
            switch self {
            case .eto:
                return "ETo means reference evapotranspiration. It estimates how much water is lost from a reference crop through evaporation and plant transpiration. Vine water use is estimated by multiplying ETo by the crop coefficient."
            case .kc:
                return "Crop coefficient adjusts reference ETo to better match vine water use. A lower Kc means the vines are using less water; a higher Kc means more canopy and higher water demand."
            case .applicationRate:
                return "Application rate is how many millimetres of water your irrigation system applies per hour. It converts the required irrigation depth into an irrigation duration."
            case .irrigationEfficiency:
                return "Irrigation efficiency allows for losses in the system and soil. A lower efficiency means more water must be applied to achieve the target amount in the root zone."
            case .rainfallEffectiveness:
                return "Rainfall effectiveness estimates how much forecast or recent rain is actually useful to the vines. Some rainfall may be lost to runoff, evaporation, interception, or shallow wetting."
            case .replacement:
                return "Replacement controls how much of the calculated deficit you want to replace. 100% replaces the full calculated deficit; lower values apply less."
            case .soilBuffer:
                return "Soil moisture buffer is an allowance for water already available in the soil. It reduces the calculated irrigation requirement."
            case .recentRain:
                return "Recent actual rain is rain that has already fallen. The advisor uses it to reduce the forecast irrigation requirement."
            }
        }
    }

    // Persisted rainfall history coverage (number of days in the last
    // 365 days that have a recorded rainfall row in any source). Used
    // to surface the "Build rainfall history" prompt even when the
    // currently selected actual-rain window happens to be complete.
    @State private var persistedHistoryCoverageDays: Int?
    @State private var isCheckingHistoryCoverage: Bool = false
    @State private var didLoadHistoryCoverage: Bool = false
    /// Threshold below which we consider persisted rainfall history
    /// "shallow" and prompt the user to build it out. 60 days gives
    /// enough context for seasonal trends without being noisy.
    private let shallowHistoryThresholdDays: Int = 60
    private let historyCoverageWindowDays: Int = 365
    private let wizardIntegrationRepository: any VineyardWeatherIntegrationRepositoryProtocol
        = SupabaseVineyardWeatherIntegrationRepository()

    private let durationOptions: [Int] = [3, 5, 7, 14]

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case appRate, kc, efficiency, rainEff, replacement, buffer
        case manualEto(Date), manualRain(Date)
    }

    private var vineyardPaddocks: [Paddock] {
        guard let vid = store.selectedVineyard?.id else { return store.paddocks }
        return store.paddocks.filter { $0.vineyardId == vid }
    }

    private var selectedPaddock: Paddock? {
        guard let id = selectedPaddockId, !useWholeVineyard else { return nil }
        return store.paddocks.first(where: { $0.id == id })
    }

    /// Effective soil profile used by the calculator.
    ///
    /// Resolution order in Whole Vineyard mode:
    /// 1. Vineyard-level profile (paddock_id = null)
    /// 2. Conservative aggregate across paddock profiles (cautious)
    /// 3. nil — setup required
    private var effectiveSoilProfile: BackendSoilProfile? {
        if useWholeVineyard {
            if let v = vineyardDefaultSoilProfile { return v }
            return wholeVineyardAggregatedProfile
        }
        return paddockSoilProfile
    }

    /// Only the paddock profiles (excludes the vineyard-level fallback row
    /// returned by list_vineyard_soil_profiles).
    private var paddockOnlySoilProfiles: [BackendSoilProfile] {
        vineyardSoilProfiles.filter { $0.paddockId != nil }
    }

    private var wholeVineyardAggregatedProfile: BackendSoilProfile? {
        let valid = paddockOnlySoilProfiles.compactMap { p -> BackendSoilProfile? in
            guard p.availableWaterCapacityMmPerM != nil, p.effectiveRootDepthM != nil else { return nil }
            return p
        }
        guard !valid.isEmpty else { return nil }
        // Conservative aggregate — lowest AWC, shallowest root depth, lowest
        // allowed depletion. Keeps Whole Vineyard recommendations cautious.
        let awcs = valid.compactMap { $0.availableWaterCapacityMmPerM }
        let depths = valid.compactMap { $0.effectiveRootDepthM }
        let depls = valid.compactMap { $0.managementAllowedDepletionPercent }
        guard let first = valid.first else { return nil }
        return BackendSoilProfile(
            id: first.id,
            vineyardId: first.vineyardId,
            paddockId: first.paddockId,
            source: "aggregated",
            sourceProvider: "aggregated",
            sourceDataset: nil,
            sourceFeatureId: nil,
            sourceName: "Whole Vineyard (conservative average)",
            modelVersion: first.modelVersion,
            countryCode: first.countryCode,
            regionCode: first.regionCode,
            lookupLatitude: nil,
            lookupLongitude: nil,
            soilLandscape: nil,
            soilLandscapeCode: nil,
            australianSoilClassification: nil,
            australianSoilClassificationCode: nil,
            landSoilCapability: nil,
            landSoilCapabilityClass: nil,
            soilDescription: nil,
            soilTextureClass: nil,
            irrigationSoilClass: first.irrigationSoilClass,
            availableWaterCapacityMmPerM: awcs.min(),
            effectiveRootDepthM: depths.min(),
            managementAllowedDepletionPercent: depls.min(),
            infiltrationRisk: nil,
            drainageRisk: nil,
            waterloggingRisk: nil,
            confidence: "low",
            isManualOverride: false,
            manualNotes: nil,
            createdAt: nil,
            updatedAt: nil,
            updatedBy: nil
        )
    }

    private var latitude: Double? {
        store.settings.vineyardLatitude ?? store.paddockCentroidLatitude
    }

    private var longitude: Double? {
        store.settings.vineyardLongitude ?? store.paddockCentroidLongitude
    }

    /// Source describing where the resolved application rate came from.
    /// Used in the wizard/Settings note so the user can see whether the
    /// rate is from a vineyard default, a paddock system rate, an
    /// aggregate of paddock rates, or a manual typed override.
    private enum AppRateSource: Equatable {
        case none
        case typedOverride
        case paddockSystemRate
        case vineyardDefault
        case areaWeightedAverage(count: Int, missing: Int)
        case simpleAverage(count: Int, missing: Int)

        var label: String {
            switch self {
            case .none: return ""
            case .typedOverride: return "Manual override"
            case .paddockSystemRate: return "From this block's system rate"
            case .vineyardDefault: return "Vineyard default"
            case .areaWeightedAverage(let count, let missing):
                let base = "Area-weighted average of \(count) block\(count == 1 ? "" : "s")"
                return missing > 0 ? "\(base) (\(missing) without rate)" : base
            case .simpleAverage(let count, let missing):
                let base = "Average of \(count) block\(count == 1 ? "" : "s")"
                return missing > 0 ? "\(base) (\(missing) without rate)" : base
            }
        }
    }

    /// Computed (rate, source) so UI can show provenance and the wizard
    /// can verify completeness without re-implementing the same lookup.
    ///
    /// Block selected: typed value → paddock system rate → vineyard default.
    /// Whole Vineyard: typed value → vineyard default → area-weighted
    /// aggregate of paddock system rates → simple average.
    private var resolvedAppRateAndSource: (rate: Double, source: AppRateSource) {
        let typed = parse(applicationRateText)
        if useWholeVineyard {
            if typed > 0 { return (typed, .typedOverride) }
            let defaultRate = store.settings.irrigationDefaultApplicationRateMmPerHour
            if defaultRate > 0 { return (defaultRate, .vineyardDefault) }
            let paddocks = vineyardPaddocks
            let withRate = paddocks.filter { ($0.mmPerHour ?? 0) > 0 }
            let missing = max(0, paddocks.count - withRate.count)
            guard !withRate.isEmpty else { return (0, .none) }
            let weighted = withRate.reduce(into: (sum: 0.0, weight: 0.0)) { acc, p in
                if let r = p.mmPerHour, r > 0, p.areaHectares > 0 {
                    acc.sum += r * p.areaHectares
                    acc.weight += p.areaHectares
                }
            }
            if weighted.weight > 0 {
                return (weighted.sum / weighted.weight,
                        .areaWeightedAverage(count: withRate.count, missing: missing))
            }
            let rates = withRate.compactMap { $0.mmPerHour }
            let avg = rates.reduce(0, +) / Double(rates.count)
            return (avg, .simpleAverage(count: withRate.count, missing: missing))
        }
        if typed > 0 { return (typed, .typedOverride) }
        if let mmHr = selectedPaddock?.mmPerHour, mmHr > 0 {
            return (mmHr, .paddockSystemRate)
        }
        let def = store.settings.irrigationDefaultApplicationRateMmPerHour
        if def > 0 { return (def, .vineyardDefault) }
        return (0, .none)
    }

    private var resolvedApplicationRateMmPerHour: Double {
        resolvedAppRateAndSource.rate
    }

    private var settings: IrrigationSettings {
        IrrigationSettings(
            irrigationApplicationRateMmPerHour: resolvedApplicationRateMmPerHour,
            cropCoefficientKc: parse(kcText, default: 0.65),
            irrigationEfficiencyPercent: parse(efficiencyText, default: 90),
            rainfallEffectivenessPercent: parse(rainEffText, default: 80),
            replacementPercent: parse(replacementText, default: 100),
            soilMoistureBufferMm: parse(bufferText)
        )
    }

    private var forecastDays: [ForecastDay] {
        guard let base = forecastService.forecast?.days, !base.isEmpty else { return [] }
        return base.map { day in
            let eto = manualEToOverrides[day.date].flatMap { Double($0) } ?? day.forecastEToMm
            let rain = manualRainOverrides[day.date].flatMap { Double($0) } ?? day.forecastRainMm
            return ForecastDay(date: day.date, forecastEToMm: eto, forecastRainMm: rain)
        }
    }

    /// Total recent actual rainfall (mm) eligible to offset the deficit.
    /// Only counts when the toggle is on and we actually have data.
    private var recentActualRainOffsetMm: Double {
        guard includeRecentActualRain, let r = recentRainResult else { return 0 }
        return r.dailyMm.values.reduce(0, +)
    }

    // MARK: - Dormancy awareness

    /// True when the vines are likely dormant based on latitude and the
    /// current calendar month. Southern Hemisphere: Jun/Jul/Aug.
    /// Northern Hemisphere: Dec/Jan/Feb. Used as a first-pass heuristic
    /// when no growth-stage data is available.
    private var isLikelyDormant: Bool {
        let month = Calendar.current.component(.month, from: Date())
        let lat = latitude ?? 0
        if lat < 0 {
            return [6, 7, 8].contains(month)
        } else {
            return [12, 1, 2].contains(month)
        }
    }

    private var soilInputs: SoilProfileInputs {
        guard let p = effectiveSoilProfile else { return .empty }
        return SoilProfileInputs(
            irrigationSoilClass: p.irrigationSoilClass,
            availableWaterCapacityMmPerM: p.availableWaterCapacityMmPerM,
            effectiveRootDepthM: p.effectiveRootDepthM,
            managementAllowedDepletionPercent: p.managementAllowedDepletionPercent,
            infiltrationRisk: p.infiltrationRisk,
            drainageRisk: p.drainageRisk,
            waterloggingRisk: p.waterloggingRisk,
            modelVersion: p.modelVersion
        )
    }

    private var soilAwareV2Enabled: Bool {
        systemAdmin.isEnabled(SystemFeatureFlagKey.enableSoilAwareIrrigationV2)
    }

    private var result: IrrigationRecommendationResult? {
        IrrigationCalculator.calculate(
            forecastDays: forecastDays,
            settings: settings,
            recentActualRainMm: recentActualRainOffsetMm,
            soil: soilInputs,
            soilAwareV2Enabled: soilAwareV2Enabled
        )
    }

    private var missingItems: [String] {
        var items: [String] = []
        if latitude == nil || longitude == nil {
            items.append("Weather source / vineyard location")
        }
        if settings.irrigationApplicationRateMmPerHour <= 0 {
            items.append(useWholeVineyard
                         ? "Vineyard irrigation application rate (mm/hr)"
                         : "Irrigation application rate (mm/hr)")
        }
        if (effectiveSoilProfile?.availableWaterCapacityMmPerM ?? 0) <= 0 {
            items.append(useWholeVineyard
                         ? "Whole Vineyard soil profile"
                         : "Soil profile for the selected block")
        }
        if settings.cropCoefficientKc <= 0 {
            items.append("Crop coefficient (Kc)")
        }
        if vineyardPaddocks.isEmpty {
            items.append("At least one block")
        }
        return items
    }

    var body: some View {
        Form {
            // 1. Wizard — only shown when there are incomplete items.
            if !wizardComplete {
                setupWizardSection
            }
            if shouldShowWeatherWizardBanner {
                weatherWizardBannerSection
            }
            // 2. Block / Whole Vineyard selector (compact).
            compactBlockSelectorSection
            // 3. Recommendation.
            recommendationSection
            // 4. Config entry button.
            configEntrySection
        }
        .navigationTitle("Irrigation Advisor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onAppear {
            if !didLoadFromSettings {
                loadParametersFromSettings()
                didLoadFromSettings = true
            }
            if selectedPaddockId == nil {
                selectedPaddockId = store.settings.irrigationAlertPaddockId ?? vineyardPaddocks.first?.id
            }
            applyPaddockDefaults()
            if !didAutoLoad {
                didAutoLoad = true
                if forecastService.forecast == nil, latitude != nil, longitude != nil {
                    Task { await loadForecast() }
                }
                if recentRainResult == nil, latitude != nil, longitude != nil {
                    Task { await loadRecentRainfall() }
                }
            }
            Task { await refreshWeatherWizardStatus() }
            Task { await loadPersistedHistoryCoverage() }
            Task { await loadSoilProfile() }
            Task { await loadVineyardSoilProfiles() }
            Task { await loadVineyardDefaultSoilProfile() }
            if !didLoadRecentRainSettings {
                let saved = store.settings.irrigationRecentRainLookbackDays
                if [1, 2, 7, 14].contains(saved) {
                    recentRainDays = saved
                }
                didLoadRecentRainSettings = true
            }
            logRateResolverDiagnostics(trigger: "onAppear")
        }
        .sheet(isPresented: $showConfigSheet) {
            NavigationStack {
                irrigationAdvisorConfigBody
                    .navigationTitle("Irrigation Advisor Config")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showConfigSheet = false }
                        }
                    }
            }
        }
        .onChange(of: store.selectedVineyardId) { _, _ in
            didLoadWeatherWizardStatus = false
            wuStationConfigured = false
            didLoadHistoryCoverage = false
            persistedHistoryCoverageDays = nil
            Task { await refreshWeatherWizardStatus() }
            Task { await loadPersistedHistoryCoverage(force: true) }
        }
        .onChange(of: kcText) { _, _ in persistParameters() }
        .onChange(of: efficiencyText) { _, _ in persistParameters() }
        .onChange(of: rainEffText) { _, _ in persistParameters() }
        .onChange(of: replacementText) { _, _ in persistParameters() }
        .onChange(of: bufferText) { _, _ in persistParameters() }
        .onChange(of: applicationRateText) { _, _ in persistParameters() }
        .onChange(of: selectedPaddockId) { _, _ in
            applyPaddockDefaults()
            Task { await loadSoilProfile(force: true) }
        }
        .onChange(of: useWholeVineyard) { _, _ in
            applyPaddockDefaults()
            logRateResolverDiagnostics(trigger: "useWholeVineyard changed")
            Task { await loadVineyardSoilProfiles() }
            Task { await loadVineyardDefaultSoilProfile(force: true) }
        }
        .onChange(of: forecastDuration) { _, newValue in
            persistForecastDuration(newValue)
            if latitude != nil, longitude != nil {
                Task { await loadForecast() }
            }
        }
        .onChange(of: recentRainDays) { _, newValue in
            if didLoadRecentRainSettings, [1, 2, 7, 14].contains(newValue) {
                var s = store.settings
                if s.irrigationRecentRainLookbackDays != newValue {
                    s.irrigationRecentRainLookbackDays = newValue
                    store.updateSettings(s)
                }
                // Persist shared vineyard-level lookback (hours) to Supabase
                // so Lovable and other clients see the same window.
                if let vid = store.selectedVineyardId {
                    let hours = newValue * 24
                    Task {
                        do {
                            _ = try await RecentRainfallContractService
                                .setLookbackHours(vineyardId: vid, hours: hours)
                        } catch {
                            print("[Irrigation] failed to persist shared lookback: \(error.localizedDescription)")
                        }
                    }
                }
            }
            if latitude != nil, longitude != nil {
                Task { await loadRecentRainfall() }
            }
        }
    }

    // MARK: - Weather Setup Wizard banner

    private var davisConfiguredForBanner: Bool {
        guard let vid = store.selectedVineyardId else { return false }
        let cfg = WeatherProviderStore.shared.config(for: vid)
        let hasShared = cfg.davisIsVineyardShared && cfg.davisVineyardHasServerCredentials
        let hasStation = (cfg.davisStationId?.isEmpty == false)
        return hasShared && hasStation
    }

    private var shouldShowWeatherWizardBanner: Bool {
        guard accessControl.canChangeSettings else { return false }
        guard store.selectedVineyardId != nil else { return false }
        if davisConfiguredForBanner { return false }
        if wuStationConfigured { return false }
        return true
    }

    private var weatherWizardBannerSection: some View {
        Section {
            Button {
                showWeatherWizard = true
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "cloud.sun.rain.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            LinearGradient(
                                colors: [Color.accentColor, VineyardTheme.leafGreen],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: .rect(cornerRadius: 10)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Set up vineyard weather")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Connect a Davis station (optional) or pick a Weather Underground station to power rainfall, irrigation and alerts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text("Open Weather Setup Wizard")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tint)
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showWeatherWizard, onDismiss: {
            Task { await refreshWeatherWizardStatus(force: true) }
        }) {
            WeatherSetupWizardView()
        }
    }

    private func refreshWeatherWizardStatus(force: Bool = false) async {
        guard let vid = store.selectedVineyardId else {
            wuStationConfigured = false
            return
        }
        if didLoadWeatherWizardStatus && !force { return }
        didLoadWeatherWizardStatus = true
        // Make sure Davis cache is hot so davisConfiguredForBanner reflects
        // the server-side integration even for fresh installs.
        await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: vid)
        do {
            let integ = try await wizardIntegrationRepository.fetch(
                vineyardId: vid, provider: "wunderground"
            )
            wuStationConfigured = !((integ?.stationId ?? "").isEmpty)
        } catch {
            wuStationConfigured = false
        }
    }

    // MARK: - Top status

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.tint)
                    Text("Weather sources")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let updated = lastUpdated {
                        Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if forecastService.isLoading {
                        Text("Loading…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    sourceRow(
                        label: "Forecast",
                        value: forecastSourceDisplayValue,
                        icon: "cloud.sun.fill",
                        tint: Color.accentColor
                    )
                    sourceRow(
                        label: "Actual rain",
                        value: actualRainSourceValue,
                        icon: (recentRainResult?.isMeasured ?? false)
                            ? "sensor.tag.radiowaves.forward.fill"
                            : "externaldrive.connected.to.line.below.fill",
                        tint: (recentRainResult?.isMeasured ?? false) ? VineyardTheme.leafGreen : .secondary
                    )
                    sourceRow(
                        label: "Fallback",
                        value: "Open-Meteo Archive",
                        icon: "tray.full.fill",
                        tint: .secondary
                    )
                }

                if let reason = forecastService.fallbackReason, !reason.isEmpty {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if let r = recentRainResult, r.fallbackUsed {
                    Label("Using archive fallback for actual rainfall.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Button {
                    showWeatherSettings = true
                } label: {
                    Label("Manage Weather Data", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showMissingRainHelper, onDismiss: {
            // Refresh persisted rainfall after the helper closes so the
            // recommendation card and source labels reflect any new rows.
            Task { await loadRecentRainfall() }
            Task { await loadPersistedHistoryCoverage(force: true) }
        }) {
            IrrigationMissingRainHelperSheet(
                vineyardId: store.selectedVineyardId,
                rainfallWindowDays: recentRainDays,
                onCompleted: {
                    Task { await loadRecentRainfall() }
                    Task { await loadPersistedHistoryCoverage(force: true) }
                }
            )
        }
        .sheet(isPresented: $showWeatherSettings) {
            NavigationStack {
                WeatherDataSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showWeatherSettings = false }
                        }
                    }
            }
        }
    }

    private func sourceRow(label: String, value: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// User-facing text shown on the right of the "Actual rain" row.
    /// Strips the "Source: " prefix produced by RainfallHistoryService so the
    /// label sits naturally beside "Actual rain:".
    private var actualRainSourceValue: String {
        guard let r = recentRainResult else {
            if isLoadingRecentRain { return "Loading…" }
            return "Automatic Historical Weather"
        }
        let raw = r.providerLabel
        if raw.hasPrefix("Source: ") {
            return String(raw.dropFirst("Source: ".count))
        }
        return raw
    }

    /// Display label for the active forecast source on the Weather
    /// sources card. Normalises raw provider keys returned by the
    /// WillyWeather edge function so the UI reads "WillyWeather" rather
    /// than "willyweather". While the forecast is still loading, shows
    /// the resolved provider so users see the expected source rather
    /// than a hard-coded Open-Meteo placeholder.
    private var forecastSourceDisplayValue: String {
        if let raw = forecastService.forecast?.source,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return prettyForecastSource(raw)
        }
        switch forecastService.resolvedProvider {
        case .willyWeather: return "WillyWeather"
        case .openMeteo: return "Open-Meteo Forecast"
        case .auto: return forecastService.isLoading ? "Resolving…" : "Open-Meteo Forecast"
        }
    }

    private func prettyForecastSource(_ raw: String) -> String {
        switch raw.lowercased() {
        case "willyweather", "willy_weather", "willy-weather":
            return "WillyWeather"
        case "open_meteo", "open-meteo", "openmeteo":
            return "Open-Meteo Forecast"
        case "davis_weatherlink", "davis", "weatherlink":
            return "Davis WeatherLink"
        case "weather_underground", "wunderground":
            return "Weather Underground"
        default:
            return raw
        }
    }

    /// Short tag used inside the recommendation card sentence. Looks at
    /// the per-day source map so persisted manual / Open-Meteo days are
    /// surfaced honestly instead of always showing the configured
    /// provider.
    private var actualRainShortSource: String {
        guard let r = recentRainResult else { return "Archive" }
        let counts = r.sources.values.reduce(into: [RainfallSource: Int]()) { $0[$1, default: 0] += 1 }
        let present = counts.filter { $0.value > 0 }.keys
        if present.count > 1 {
            return "Mixed sources"
        }
        switch present.first {
        case .davis:
            if let name = r.stationName, !name.isEmpty {
                return "Davis WeatherLink — \(name)"
            }
            return "Davis WeatherLink"
        case .wunderground: return "Weather Underground"
        case .manual: return "Manual entries"
        case .archive: return "Open-Meteo"
        case .missing, .none:
            switch r.effectiveProvider {
            case .davis: return "Davis WeatherLink"
            case .wunderground: return "Weather Underground"
            case .automatic: return "Archive"
            }
        }
    }

    /// Days inside the requested window that have no recorded rainfall
    /// in any source (persisted nor live). Surfaced as a footnote so
    /// users can tell "0 mm recorded" apart from "no data".
    private var recentRainNoDataDays: Int {
        guard let r = recentRainResult else { return 0 }
        return max(0, recentRainDays - r.dailyMm.count)
    }

    private var missingSetupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Complete irrigation settings to calculate recommendations.", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(missingItems, id: \.self) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Setup wizard checklist

    private struct WizardItem: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isComplete: Bool
    }

    private var wizardItems: [WizardItem] {
        let blockChosen = useWholeVineyard || (selectedPaddockId != nil)
        let weatherOK = latitude != nil && longitude != nil
        let appRateOK = resolvedApplicationRateMmPerHour > 0
        let soilOK = (effectiveSoilProfile?.availableWaterCapacityMmPerM ?? 0) > 0
        let kcOK = settings.cropCoefficientKc > 0
        let efficiencyOK = settings.irrigationEfficiencyPercent > 0 && settings.rainfallEffectivenessPercent > 0
        return [
            WizardItem(id: "block", title: "Block or Whole Vineyard",
                       detail: useWholeVineyard ? "Using Whole Vineyard (conservative average)."
                       : (selectedPaddock?.name ?? "Pick a block or choose Whole Vineyard."),
                       isComplete: blockChosen),
            WizardItem(id: "weather", title: "Weather source",
                       detail: weatherOK ? "Vineyard location and forecast configured."
                       : "Set vineyard location and weather source.",
                       isComplete: weatherOK),
            WizardItem(id: "appRate", title: "Irrigation application rate",
                       detail: appRateOK
                       ? {
                           let r = resolvedAppRateAndSource
                           let label = r.source.label
                           return label.isEmpty
                               ? String(format: "%.2f mm/hr", r.rate)
                               : String(format: "%.2f mm/hr — %@", r.rate, label)
                       }()
                       : (useWholeVineyard
                          ? "Set irrigation application rate in block settings or add a vineyard default."
                          : "Enter mm/hr below in Settings."),
                       isComplete: appRateOK),
            WizardItem(id: "soil", title: "Soil profile / buffer",
                       detail: soilOK
                       ? (useWholeVineyard
                          ? (vineyardDefaultSoilProfile != nil
                             ? "Using Whole Vineyard soil profile."
                             : "Using conservative aggregate from paddock profiles.")
                          : "Soil profile present.")
                       : (useWholeVineyard
                          ? "Add a Whole Vineyard soil profile or block profiles."
                          : "Add a soil profile for soil-aware advice."),
                       isComplete: soilOK),
            WizardItem(id: "kc", title: "Crop coefficient / growth stage",
                       detail: String(format: "Kc = %.2f", settings.cropCoefficientKc),
                       isComplete: kcOK),
            WizardItem(id: "efficiency", title: "Rainfall & irrigation efficiency",
                       detail: String(format: "Eff %.0f%% • RainEff %.0f%%",
                                      settings.irrigationEfficiencyPercent,
                                      settings.rainfallEffectivenessPercent),
                       isComplete: efficiencyOK),
        ]
    }

    private var wizardComplete: Bool { wizardItems.allSatisfy(\.isComplete) }

    @ViewBuilder
    private var setupWizardSection: some View {
        let incomplete = wizardItems.filter { !$0.isComplete }
        if !incomplete.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.clipboard")
                            .foregroundStyle(Color.accentColor)
                        Text("Finish irrigation setup")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    ForEach(incomplete) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.caption.weight(.semibold))
                                Text(item.detail).font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Button {
                        showConfigSheet = true
                    } label: {
                        Label("Open Irrigation Advisor Config", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Compact block selector

    private var compactBlockSelectorSection: some View {
        Section {
            Picker("Scope", selection: blockScopeBinding) {
                Text("Whole Vineyard").tag(UUID?.none)
                ForEach(vineyardPaddocks) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Block")
        }
    }

    /// Bridges the Whole Vineyard toggle + paddock selection through a
    /// single picker. nil tag means Whole Vineyard.
    private var blockScopeBinding: Binding<UUID?> {
        Binding(
            get: { useWholeVineyard ? nil : selectedPaddockId },
            set: { newValue in
                if let v = newValue {
                    useWholeVineyard = false
                    selectedPaddockId = v
                } else {
                    useWholeVineyard = true
                }
            }
        )
    }

    private var configEntrySection: some View {
        Section {
            Button {
                showConfigSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Irrigation Advisor Config")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Weather sources, recent rain, forecast, soil profile, assumptions and block settings")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Whole Vineyard warnings

    /// Active paddock names missing emitter setup, in Whole Vineyard
    /// mode. Used to surface a warning without blocking the
    /// recommendation when at least one block has a valid rate.
    private var blocksMissingEmitters: [String] {
        guard useWholeVineyard else { return [] }
        return vineyardPaddocks.compactMap { p -> String? in
            let ok = (p.mmPerHour ?? 0) > 0
            return ok ? nil : (p.name.isEmpty ? "(unnamed block)" : p.name)
        }
    }

    /// Active paddocks without a saved soil profile, in Whole Vineyard
    /// mode. Helps surface which blocks to configure next without
    /// blocking the recommendation.
    private var blocksMissingSoilProfile: [String] {
        guard useWholeVineyard else { return [] }
        let withProfileIds = Set(paddockOnlySoilProfiles.compactMap { $0.paddockId })
        return vineyardPaddocks.compactMap { p in
            withProfileIds.contains(p.id) ? nil
                : (p.name.isEmpty ? "(unnamed block)" : p.name)
        }
    }

    @ViewBuilder
    private var wholeVineyardWarningsView: some View {
        let missingRate = blocksMissingEmitters
        let missingSoil = blocksMissingSoilProfile
        if useWholeVineyard, !missingRate.isEmpty || !missingSoil.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !missingRate.isEmpty {
                    Label("Some blocks are missing irrigation setup",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(missingRate, id: \.self) { name in
                        Text("\u{2022} \(name): missing emitter details")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !missingSoil.isEmpty {
                    Label("Some blocks are missing a soil profile",
                          systemImage: "square.stack.3d.up.slash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.top, missingRate.isEmpty ? 0 : 4)
                    ForEach(missingSoil, id: \.self) { name in
                        Text("\u{2022} \(name)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Recommendation uses the configured blocks. Select an individual block for a more accurate result.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Config sheet body

    @ViewBuilder
    private var irrigationAdvisorConfigBody: some View {
        Form {
            // 1. Weather sources
            statusSection
            // 2. Recent rain
            recentRainSection
            if shouldShowRainfallHistorySection {
                rainfallHistorySection
            }
            rainfallCalendarSection
            // 3/4. Forecast + details
            forecastControlSection
            forecastDetailsSection
            // 5. Daily breakdown
            dailyBreakdownDisclosure
            // 6. Calculation assumptions
            settingsSection
            // 7. Block settings (soil + block details)
            blockSection
            soilProfileSection
            // Diagnostics last — system admins only when the flag is on.
            if showIrrigationDiagnostics {
                rateResolverDiagnosticsSection
            }
        }
    }

    // MARK: - Recent actual rainfall

    @ViewBuilder
    private var recentRainSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: (recentRainResult?.isMeasured ?? false)
                                      ? "sensor.tag.radiowaves.forward.fill"
                                      : "cloud.rain.fill")
                        .foregroundStyle((recentRainResult?.isMeasured ?? false) ? VineyardTheme.leafGreen : Color.accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recentRainHeading)
                            .font(.subheadline.weight(.semibold))
                        Text(recentRainSourceLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if isLoadingRecentRain {
                        ProgressView()
                    } else {
                        Button {
                            Task { await loadRecentRainfall() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Picker("Window", selection: $recentRainDays) {
                    Text("24h").tag(1)
                    Text("48h").tag(2)
                    Text("7d").tag(7)
                    Text("14d").tag(14)
                }
                .pickerStyle(.segmented)

                if let warn = recentRainResult?.fallbackReason, recentRainResult?.fallbackUsed == true {
                    Text(warn)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if let warn = recentRainResult?.fallbackReason {
                    Text(warn)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if recentRainNoDataDays > 0 {
                    Text("\(recentRainNoDataDays) day\(recentRainNoDataDays == 1 ? "" : "s") in this window have no recorded rainfall (treated as 0 mm in the deficit calculation).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    missingRainHelperPrompt
                }

                Toggle(isOn: $includeRecentActualRain) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Include recent actual rain")
                                .font(.subheadline)
                            infoButton(for: .recentRain)
                        }
                        Text(includeRecentActualRain
                             ? "Subtracted from forecast deficit (after rainfall effectiveness)."
                             : "Recent actual rain is shown but not used in the calculation.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(VineyardTheme.leafGreen)

                if isLikelyDormant {
                    Label("Dormant season — recent rainfall is shown for reference.",
                          systemImage: "leaf.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Recent Actual Rainfall")
        }
    }

    @ViewBuilder
    private var missingRainHelperPrompt: some View {
        if accessControl.canChangeSettings {
            VStack(alignment: .leading, spacing: 6) {
                Text("Some rainfall days are missing. VineTrack can try Davis, Weather Underground, then Open-Meteo for remaining gaps.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showMissingRainHelper = true
                } label: {
                    Label("Missing rain data? Fill gaps", systemImage: "cloud.rain.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            }
            .padding(.top, 2)
        } else {
            Text("Ask an Owner or Manager to fill missing rainfall data.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rainfall history (persisted coverage)

    /// True when we have a coverage figure and it falls below the
    /// shallow-history threshold. While the check is loading we do
    /// NOT show the prompt to avoid a flash for vineyards with deep
    /// history.
    private var hasShallowPersistedHistory: Bool {
        guard let coverage = persistedHistoryCoverageDays else { return false }
        return coverage < shallowHistoryThresholdDays
    }

    private var shouldShowRainfallHistorySection: Bool {
        guard store.selectedVineyardId != nil else { return false }
        guard latitude != nil, longitude != nil else { return false }
        return hasShallowPersistedHistory
    }

    @ViewBuilder
    private var rainfallHistorySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rainfall history")
                            .font(.subheadline.weight(.semibold))
                        Text(persistedHistorySubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isCheckingHistoryCoverage {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("VineTrack can build out older rainfall history using your configured weather sources, then fall back to Open-Meteo for any remaining gaps.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if accessControl.canChangeSettings {
                    Button {
                        showMissingRainHelper = true
                    } label: {
                        Label("Build rainfall history", systemImage: "cloud.rain.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                } else {
                    Text("Ask an Owner or Manager to build rainfall history.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Rainfall history")
        }
    }

    private var persistedHistorySubtitle: String {
        if let coverage = persistedHistoryCoverageDays {
            return "Only \(coverage) day\(coverage == 1 ? "" : "s") of persisted rainfall history found in the last \(historyCoverageWindowDays) days."
        }
        if isCheckingHistoryCoverage {
            return "Checking persisted rainfall history\u{2026}"
        }
        return "Persisted rainfall history not yet checked."
    }

    private func loadPersistedHistoryCoverage(force: Bool = false) async {
        guard let vid = store.selectedVineyardId else {
            persistedHistoryCoverageDays = nil
            return
        }
        if didLoadHistoryCoverage && !force { return }
        isCheckingHistoryCoverage = true
        defer { isCheckingHistoryCoverage = false }
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -(historyCoverageWindowDays - 1), to: to) ?? to
        do {
            let rows = try await PersistedRainfallService.fetchDailyRainfall(
                vineyardId: vid, from: from, to: to
            )
            // Count days with any recorded rainfall row (any source).
            let coverage = rows.reduce(into: 0) { acc, row in
                if row.rainfallMm != nil || (row.source?.isEmpty == false) {
                    acc += 1
                }
            }
            persistedHistoryCoverageDays = coverage
            didLoadHistoryCoverage = true
        } catch {
            // Leave coverage as nil so we don't claim shallow history
            // on a transient RPC error.
            persistedHistoryCoverageDays = nil
        }
    }

    private var recentRainHeading: String {
        guard let r = recentRainResult else {
            return isLoadingRecentRain ? "Loading recent rainfall…" : "Recent rainfall: —"
        }
        let mm = r.dailyMm.values.reduce(0, +)
        let label = recentRainDays == 1 ? "24h" : (recentRainDays == 2 ? "48h" : "\(recentRainDays) days")
        return String(format: "Recent rainfall: %.1f mm over last \(label)", mm)
    }

    private var recentRainSourceLabel: String {
        guard let r = recentRainResult else { return "Source: —" }
        return r.providerLabel
    }

    // MARK: - Rainfall calendar entry

    private var rainfallCalendarSection: some View {
        Section {
            NavigationLink {
                RainfallCalendarView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rainfall Calendar")
                            .font(.subheadline.weight(.semibold))
                        Text("Daily rainfall by month for the year")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Recommendation card

    @ViewBuilder
    private var recommendationSection: some View {
        Section("Recommendation") {
            if !missingItems.isEmpty {
                blockedRecommendationCard
            } else if forecastService.isLoading && forecastService.forecast == nil {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Calculating recommendation…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if let error = forecastService.errorMessage, forecastService.forecast == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Button {
                        Task { await loadForecast() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            } else if let result {
                recommendationCard(result)
            } else {
                Text("Recommendation will appear once the forecast loads.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var blockedRecommendationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Recommendation unavailable")
                    .font(.headline)
                Spacer()
            }
            Text(useWholeVineyard
                 ? "Complete the missing items below for Whole Vineyard mode to calculate a recommendation."
                 : "Complete the missing items below to calculate a recommendation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(missingItems, id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func recommendationCard(_ result: IrrigationRecommendationResult) -> some View {
        let needsIrrigation = result.netDeficitMm > 0 && settings.irrigationApplicationRateMmPerHour > 0
        let dormant = isLikelyDormant
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: dormant
                                  ? "leaf.fill"
                                  : (needsIrrigation ? "drop.fill" : "checkmark.seal.fill"))
                    .foregroundStyle(dormant
                                     ? Color.orange
                                     : (needsIrrigation ? VineyardTheme.vineRed : VineyardTheme.leafGreen))
                Text(dormant
                     ? "Dormant season caution"
                     : (needsIrrigation ? "Irrigation recommended" : "No irrigation needed"))
                    .font(.headline)
                Spacer()
            }

            if dormant {
                Text("The vines are likely dormant. The calculated water deficit is shown for reference, but irrigation may not be required unless soil moisture is low, young vines need support, or conditions are unusually dry.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if needsIrrigation {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calculated irrigation equivalent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(hoursMinutesString(result.recommendedIrrigationHours))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                        Text(String(format: "Equivalent to %.1f mm over the next %d days", result.grossIrrigationMm, result.dailyBreakdown.count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 10))
                }
            } else if needsIrrigation {
                Text(String(format: "%.1f hours", result.recommendedIrrigationHours))
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .monospacedDigit()
                Text(hoursMinutesString(result.recommendedIrrigationHours))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if useWholeVineyard {
                    Text(String(format: "Apply approximately %.1f mm. Runtime is estimated per block using the vineyard average rate. Select an individual block for a more accurate runtime.", result.grossIrrigationMm))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(format: "Apply %.1f mm over the next %d days", result.grossIrrigationMm, result.dailyBreakdown.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Forecast rainfall meets vine demand for the next \(result.dailyBreakdown.count) days.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 14) {
                summaryStat("Crop use", String(format: "%.1f mm", result.forecastCropUseMm), info: .eto)
                summaryStat("Eff. rain", String(format: "%.1f mm", result.forecastEffectiveRainMm), info: .rainfallEffectiveness)
                summaryStat("Net deficit", String(format: "%.1f mm", result.netDeficitMm), info: nil)
            }

            if result.recentActualRainMm > 0 {
                Text(String(format: "Includes %.1f mm recent actual rain from %@.",
                            result.recentActualRainMm,
                            actualRainShortSource))
                    .font(.caption2)
                    .foregroundStyle(VineyardTheme.leafGreen)
            }

            if let paddock = selectedPaddock,
               let lPerHaHr = paddock.litresPerHaPerHour,
               let mmHr = paddock.mmPerHour, mmHr > 0, needsIrrigation {
                let totalLitres = (result.grossIrrigationMm / mmHr) * lPerHaHr * paddock.areaHectares
                Text(String(format: "≈ %.0f L total for %@", totalLitres, paddock.name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let v2 = result.v2 {
                soilAwareV2Panel(v2)
            }

            wholeVineyardWarningsView
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func soilAwareV2Panel(_ v2: SoilAwareV2Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "leaf.circle.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
                Text("Soil-aware recommendation")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("v2")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(VineyardTheme.leafGreen.opacity(0.15), in: .capsule)
                    .foregroundStyle(VineyardTheme.leafGreen)
            }

            HStack(spacing: 6) {
                Image(systemName: urgencyIcon(v2.urgency))
                    .foregroundStyle(urgencyColor(v2.urgency))
                Text(v2.urgency.displayLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(urgencyColor(v2.urgency))
            }

            VStack(alignment: .leading, spacing: 4) {
                if let raw = result?.readilyAvailableWaterMm, raw > 0 {
                    Text(String(format: "RAW: %.0f mm", raw))
                        .font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let rzc = result?.rootZoneCapacityMm, rzc > 0 {
                    Text(String(format: "Root-zone capacity: %.0f mm", rzc))
                        .font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(String(format: "Base demand: %.1f mm", v2.baseGrossIrrigationMm))
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                if v2.soilAdjusted {
                    Text(String(format: "Soil-adjusted event: %.1f mm", v2.soilAdjustedGrossMm))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                if v2.splitSuggested {
                    Text("Split irrigation suggested (\(v2.splitCount) events)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            if let reason = v2.adjustmentReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let caution = v2.cautionText {
                Label(caution, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.leafGreen.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private func urgencyIcon(_ u: IrrigationUrgency) -> String {
        switch u {
        case .irrigateNow:     return "exclamationmark.circle.fill"
        case .irrigateSoon:    return "clock.fill"
        case .monitor:         return "eye.fill"
        case .delayRainLikely: return "cloud.rain.fill"
        }
    }

    private func urgencyColor(_ u: IrrigationUrgency) -> Color {
        switch u {
        case .irrigateNow:     return VineyardTheme.vineRed
        case .irrigateSoon:    return .orange
        case .monitor:         return .secondary
        case .delayRainLikely: return .blue
        }
    }

    private func summaryStat(_ label: String, _ value: String, info: InfoTerm? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let info {
                    infoButton(for: info)
                }
            }
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Info popover button

    private func infoButton(for term: InfoTerm) -> some View {
        Button {
            activeInfoTerm = term
        } label: {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(term.title)")
        .popover(isPresented: Binding(
            get: { activeInfoTerm == term },
            set: { if !$0 { activeInfoTerm = nil } }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                Text(term.title)
                    .font(.headline)
                Text(term.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(minWidth: 260, maxWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Block

    private var blockSection: some View {
        Section("Block") {
            Toggle("Whole Vineyard", isOn: $useWholeVineyard)
                .tint(VineyardTheme.leafGreen)
            if useWholeVineyard {
                let count = vineyardSoilProfiles.count
                Text(count > 1
                     ? "Multiple soil profiles detected across this vineyard. Recommendations use a conservative average. For better accuracy, select an individual block."
                     : (count == 1
                        ? "Using the single available block soil profile as a vineyard fallback."
                        : "No block soil profiles found. Add a soil profile on at least one block for soil-aware guidance."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if vineyardPaddocks.isEmpty {
                Text("No blocks available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Block", selection: $selectedPaddockId) {
                    Text("Select…").tag(UUID?.none)
                    ForEach(vineyardPaddocks) { paddock in
                        Text(paddock.name).tag(Optional(paddock.id))
                    }
                }
                .pickerStyle(.menu)

                if let paddock = selectedPaddock {
                    LabeledContent("Area") {
                        Text(String(format: "%.2f ha", paddock.areaHectares))
                            .foregroundStyle(.secondary)
                    }
                    if let mmHr = paddock.mmPerHour {
                        LabeledContent("System rate") {
                            Text(String(format: "%.2f mm/hr", mmHr))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Forecast controls

    private var forecastControlSection: some View {
        Section {
            Picker("Forecast duration", selection: $forecastDuration) {
                ForEach(durationOptions, id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
            .pickerStyle(.segmented)

            Button {
                Task { await loadForecast() }
            } label: {
                if forecastService.isLoading {
                    HStack {
                        ProgressView()
                        Text("Refreshing…")
                    }
                } else {
                    Label("Refresh Recommendation", systemImage: "arrow.clockwise")
                }
            }
            .disabled(forecastService.isLoading || latitude == nil || longitude == nil)
        } header: {
            Text("Forecast")
        } footer: {
            if latitude == nil || longitude == nil {
                Text("Set your vineyard location in Settings → Vineyard Setup to load a forecast.")
            } else {
                Text("Recommendation refreshes automatically when you change duration.")
            }
        }
    }

    // MARK: - Forecast details (collapsible)

    @ViewBuilder
    private var forecastDetailsSection: some View {
        if let forecast = forecastService.forecast {
            Section {
                DisclosureGroup("Forecast details") {
                    LabeledContent("Source") {
                        Text(forecast.source).foregroundStyle(.secondary)
                    }
                    if let vid = store.selectedVineyardId {
                        let status = WeatherProviderResolver.resolve(
                            for: vid,
                            weatherStationId: store.settings.weatherStationId
                        )
                        LabeledContent("Provider") {
                            Text(status.compactLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    LabeledContent("Days") {
                        Text("\(forecast.days.count)").foregroundStyle(.secondary)
                    }
                    Toggle("Override forecast values", isOn: $useManualInputs)
                }
            }
        }
    }

    @ViewBuilder
    private var dailyBreakdownDisclosure: some View {
        if let result {
            Section {
                DisclosureGroup("Daily breakdown") {
                    ForEach(result.dailyBreakdown) { day in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(String(format: "%.1f mm deficit", day.dailyDeficitMm))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(day.dailyDeficitMm > 0 ? VineyardTheme.vineRed : VineyardTheme.leafGreen)
                                    .monospacedDigit()
                            }

                            if useManualInputs {
                                HStack(spacing: 8) {
                                    manualField(label: "ETo", value: day.forecastEToMm, field: .manualEto(day.date), binding: etoBinding(for: day.date))
                                    manualField(label: "Rain", value: day.forecastRainMm, field: .manualRain(day.date), binding: rainBinding(for: day.date))
                                }
                            } else {
                                HStack {
                                    metric("ETo", String(format: "%.1f", day.forecastEToMm), suffix: "mm")
                                    Divider().frame(height: 20)
                                    metric("Rain", String(format: "%.1f", day.forecastRainMm), suffix: "mm",
                                           highlight: day.forecastRainMm > 0 ? .blue : nil)
                                    Divider().frame(height: 20)
                                    metric("Crop use", String(format: "%.1f", day.cropUseMm), suffix: "mm")
                                    Divider().frame(height: 20)
                                    metric("Eff. rain", String(format: "%.1f", day.effectiveRainMm), suffix: "mm",
                                           highlight: day.effectiveRainMm > 0 ? .blue : nil)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    // MARK: - Settings (collapsible)

    // MARK: - Application rate resolver diagnostics

    private var showIrrigationDiagnostics: Bool {
        systemAdmin.isSystemAdmin
            && systemAdmin.isEnabled(SystemFeatureFlagKey.showIrrigationDiagnostics)
    }

    private struct PaddockRateDiagnostic: Identifiable {
        let id: UUID
        let name: String
        let areaHectares: Double
        let flowPerEmitter: Double?
        let emitterSpacing: Double?
        let rowWidth: Double
        let mmPerHour: Double?
        let included: Bool
        let exclusionReason: String?
    }

    private struct RateResolverDiagnostic {
        let mode: String
        let vineyardId: UUID?
        let totalPaddocks: Int
        let paddocksWithRate: Int
        let resolvedRate: Double
        let sourceLabel: String
        let paddocks: [PaddockRateDiagnostic]
    }

    private var appRateResolverDiagnostics: RateResolverDiagnostic {
        let paddocks = vineyardPaddocks
        let details: [PaddockRateDiagnostic] = paddocks.map { p in
            let mm = p.mmPerHour
            var reason: String? = nil
            if p.flowPerEmitter == nil || (p.flowPerEmitter ?? 0) <= 0 {
                reason = "missing flowPerEmitter"
            } else if p.emitterSpacing == nil || (p.emitterSpacing ?? 0) <= 0 {
                reason = "missing emitterSpacing"
            } else if p.rowWidth <= 0 {
                reason = "missing rowWidth"
            } else if (mm ?? 0) <= 0 {
                reason = "mmPerHour computed as 0"
            }
            return PaddockRateDiagnostic(
                id: p.id,
                name: p.name.isEmpty ? "(unnamed)" : p.name,
                areaHectares: p.areaHectares,
                flowPerEmitter: p.flowPerEmitter,
                emitterSpacing: p.emitterSpacing,
                rowWidth: p.rowWidth,
                mmPerHour: mm,
                included: (mm ?? 0) > 0,
                exclusionReason: reason
            )
        }
        let resolved = resolvedAppRateAndSource
        return RateResolverDiagnostic(
            mode: useWholeVineyard ? "Whole Vineyard" : "Selected block",
            vineyardId: store.selectedVineyard?.id,
            totalPaddocks: paddocks.count,
            paddocksWithRate: details.filter { $0.included }.count,
            resolvedRate: resolved.rate,
            sourceLabel: resolved.source.label.isEmpty ? "none" : resolved.source.label,
            paddocks: details
        )
    }

    @ViewBuilder
    private var rateResolverDiagnosticsSection: some View {
        let diag = appRateResolverDiagnostics
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    diagRow("Mode", diag.mode)
                    diagRow("Vineyard id", diag.vineyardId?.uuidString ?? "—")
                    diagRow("Paddocks loaded", "\(diag.totalPaddocks)")
                    diagRow("Configured rates found", "\(diag.paddocksWithRate)")
                    diagRow("Resolved rate",
                            diag.resolvedRate > 0
                            ? String(format: "%.2f mm/hr", diag.resolvedRate)
                            : "—")
                    diagRow("Source", diag.sourceLabel)
                    if !diag.paddocks.isEmpty {
                        Divider().padding(.vertical, 2)
                        ForEach(diag.paddocks) { (p: PaddockRateDiagnostic) in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Image(systemName: p.included ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(p.included ? VineyardTheme.leafGreen : .orange)
                                        .font(.caption2)
                                    Text(p.name).font(.caption.weight(.semibold))
                                }
                                Text(String(format: "area %.2f ha • flow %@ L/hr • emitter %@ m • row %.2f m",
                                            p.areaHectares,
                                            p.flowPerEmitter.map { String(format: "%.2f", $0) } ?? "—",
                                            p.emitterSpacing.map { String(format: "%.2f", $0) } ?? "—",
                                            p.rowWidth))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("mmPerHour = \(p.mmPerHour.map { String(format: "%.3f", $0) } ?? "nil")" +
                                     (p.exclusionReason.map { " — \($0)" } ?? ""))
                                    .font(.caption2)
                                    .foregroundStyle(p.included ? Color.secondary : Color.orange)
                            }
                            .padding(.vertical, 2)
                        }
                    } else {
                        Text("No paddocks loaded for this vineyard.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ladybug")
                        .foregroundStyle(.secondary)
                    Text("Rate resolver diagnostics")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(diag.resolvedRate > 0
                         ? String(format: "%.2f mm/hr", diag.resolvedRate)
                         : "—")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Debug panel for the Whole Vineyard irrigation rate. Remove once verified.")
        }
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).font(.caption2.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func logRateResolverDiagnostics(trigger: String) {
        let d = appRateResolverDiagnostics
        var lines: [String] = []
        lines.append("[IrrigationRateResolver] trigger=\(trigger)")
        lines.append("  mode=\(d.mode) vineyardId=\(d.vineyardId?.uuidString ?? "nil")")
        lines.append("  paddocksLoaded=\(d.totalPaddocks) withRate=\(d.paddocksWithRate)")
        lines.append(String(format: "  resolvedRate=%.4f source=%@", d.resolvedRate, d.sourceLabel))
        for p in d.paddocks {
            lines.append(String(format: "   • %@ area=%.2f flow=%@ emitter=%@ row=%.2f mmPerHour=%@ included=%@ reason=%@",
                                p.name,
                                p.areaHectares,
                                p.flowPerEmitter.map { String(format: "%.2f", $0) } ?? "nil",
                                p.emitterSpacing.map { String(format: "%.2f", $0) } ?? "nil",
                                p.rowWidth,
                                p.mmPerHour.map { String(format: "%.4f", $0) } ?? "nil",
                                p.included ? "yes" : "no",
                                p.exclusionReason ?? "-"))
        }
        print(lines.joined(separator: "\n"))
    }

    private var appRateIsSiteData: Bool {
        let src = resolvedAppRateAndSource.source
        switch src {
        case .paddockSystemRate, .vineyardDefault,
             .areaWeightedAverage, .simpleAverage:
            return resolvedAppRateAndSource.rate > 0
        case .typedOverride, .none:
            return false
        }
    }

    private var appRateSiteDataNote: String? {
        let resolved = resolvedAppRateAndSource
        guard resolved.rate > 0 else { return nil }
        switch resolved.source {
        case .typedOverride, .none:
            return nil
        case .paddockSystemRate:
            return "Pre-filled from this paddock's system rate."
        case .vineyardDefault:
            return String(format: "Using vineyard default rate (%.2f mm/hr).", resolved.rate)
        case .areaWeightedAverage, .simpleAverage:
            return String(format: "%.2f mm/hr — %@.", resolved.rate, resolved.source.label)
        }
    }

    private var settingsSection: some View {
        Section {
            DisclosureGroup("Calculation assumptions & block settings") {
                settingRow(
                    label: useWholeVineyard
                           ? "Vineyard application rate (mm/hr)"
                           : "Application rate (mm/hr)",
                    text: $applicationRateText,
                    field: .appRate,
                    help: useWholeVineyard
                          ? "Default mm/hr used for Whole Vineyard recommendations when no block is selected. Stored as a vineyard-level default."
                          : "How many millimetres of water your irrigation system applies to this block in one hour.",
                    isSiteData: appRateIsSiteData,
                    siteDataNote: appRateSiteDataNote,
                    info: .applicationRate
                )
                settingRow(
                    label: "Crop coefficient (Kc)",
                    text: $kcText,
                    field: .kc,
                    help: "Vine water demand vs reference grass. 0.65 is a typical mid-season value.",
                    isSiteData: false,
                    siteDataNote: nil,
                    info: .kc
                )
                settingRow(
                    label: "Irrigation efficiency (%)",
                    text: $efficiencyText,
                    field: .efficiency,
                    help: "How much pumped water reaches vine roots. Drip systems ~90%.",
                    isSiteData: false,
                    siteDataNote: nil,
                    info: .irrigationEfficiency
                )
                settingRow(
                    label: "Rainfall effectiveness (%)",
                    text: $rainEffText,
                    field: .rainEff,
                    help: "Fraction of forecast rainfall available to the vines. Typically ~80%.",
                    isSiteData: false,
                    siteDataNote: nil,
                    info: .rainfallEffectiveness
                )
                settingRow(
                    label: "Replacement (%)",
                    text: $replacementText,
                    field: .replacement,
                    help: "How much vine water use to replace. Lower for deficit irrigation.",
                    isSiteData: false,
                    siteDataNote: nil,
                    info: .replacement
                )
                settingRow(
                    label: "Soil buffer (mm)",
                    text: $bufferText,
                    field: .buffer,
                    help: "Extra water already stored in the soil. Subtracted from the deficit.",
                    isSiteData: false,
                    siteDataNote: nil,
                    info: .soilBuffer
                )
            }
        } footer: {
            Text("Fields marked \u{2728} are pre-filled with site-specific data from the selected block.")
        }
    }

    private func settingRow(
        label: String,
        text: Binding<String>,
        field: Field,
        help: String,
        isSiteData: Bool,
        siteDataNote: String?,
        info: InfoTerm? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Text(label)
                    if let info {
                        infoButton(for: info)
                    }
                    if isSiteData {
                        Image(systemName: "sparkles")
                            .font(.caption)
                            .foregroundStyle(VineyardTheme.leafGreen)
                    }
                }
                Spacer()
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: field)
                    .frame(maxWidth: 120)
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isSiteData, let note = siteDataNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(VineyardTheme.leafGreen)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func metric(_ label: String, _ value: String, suffix: String, highlight: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value) \(suffix)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(highlight ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func manualField(label: String, value: Double, field: Field, binding: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(String(format: "%.1f", value), text: binding)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
                .font(.caption.weight(.semibold))
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }

    private func etoBinding(for date: Date) -> Binding<String> {
        Binding(
            get: { manualEToOverrides[date] ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    manualEToOverrides.removeValue(forKey: date)
                } else {
                    manualEToOverrides[date] = newValue
                }
            }
        )
    }

    private func rainBinding(for date: Date) -> Binding<String> {
        Binding(
            get: { manualRainOverrides[date] ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    manualRainOverrides.removeValue(forKey: date)
                } else {
                    manualRainOverrides[date] = newValue
                }
            }
        )
    }

    private func hoursMinutesString(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60.0).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h) hr \(m) min"
    }

    private func loadForecast() async {
        guard let lat = latitude, let lon = longitude else { return }
        await forecastService.fetchForecast(latitude: lat, longitude: lon, days: forecastDuration, vineyardId: store.selectedVineyardId)
        if forecastService.forecast != nil {
            lastUpdated = Date()
        }
    }

    private func loadRecentRainfall() async {
        guard let lat = latitude, let lon = longitude else { return }
        isLoadingRecentRain = true
        let result = await RainfallHistoryService.fetchRecentRainfallPreferringPersisted(
            vineyardId: store.selectedVineyardId,
            latitude: lat,
            longitude: lon,
            days: recentRainDays,
            weatherStationId: store.settings.weatherStationId
        )
        recentRainResult = result
        isLoadingRecentRain = false
    }

    private func applyPaddockDefaults() {
        // Don't clobber a user-typed override. Only pre-fill when the
        // current text is empty or zero — this lets toggling Whole
        // Vineyard surface the resolved rate (vineyard default or the
        // average of configured block rates) directly in the field.
        if useWholeVineyard {
            if parse(applicationRateText) > 0 { return }
            let def = store.settings.irrigationDefaultApplicationRateMmPerHour
            if def > 0 {
                applicationRateText = String(format: "%.2f", def)
                return
            }
            let resolved = resolvedAppRateAndSource
            if resolved.rate > 0 {
                applicationRateText = String(format: "%.2f", resolved.rate)
            } else {
                applicationRateText = ""
            }
            return
        }
        guard let paddock = selectedPaddock else { return }
        if let mmHr = paddock.mmPerHour, mmHr > 0 {
            applicationRateText = String(format: "%.2f", mmHr)
        }
    }

    private func loadParametersFromSettings() {
        let s = store.settings
        kcText = String(format: "%.2f", s.irrigationKc)
        efficiencyText = String(format: "%.0f", s.irrigationEfficiencyPercent)
        rainEffText = String(format: "%.0f", s.irrigationRainfallEffectivenessPercent)
        replacementText = String(format: "%.0f", s.irrigationReplacementPercent)
        bufferText = String(format: "%.0f", s.irrigationSoilBufferMm)
        let saved = s.irrigationForecastDays
        forecastDuration = durationOptions.contains(saved) ? saved : 5
    }

    private func persistParameters() {
        guard didLoadFromSettings else { return }
        var s = store.settings
        s.irrigationKc = parse(kcText, default: 0.65)
        s.irrigationEfficiencyPercent = parse(efficiencyText, default: 90)
        s.irrigationRainfallEffectivenessPercent = parse(rainEffText, default: 80)
        s.irrigationReplacementPercent = parse(replacementText, default: 100)
        s.irrigationSoilBufferMm = parse(bufferText)
        let typedRate = parse(applicationRateText)
        if typedRate > 0 {
            let paddockHasRate = (selectedPaddock?.mmPerHour ?? 0) > 0
            if useWholeVineyard || !paddockHasRate {
                s.irrigationDefaultApplicationRateMmPerHour = typedRate
            }
        }
        store.updateSettings(s)
    }

    private func persistForecastDuration(_ days: Int) {
        guard didLoadFromSettings else { return }
        var s = store.settings
        s.irrigationForecastDays = days
        store.updateSettings(s)
    }

    private func parse(_ text: String, default defaultValue: Double = 0) -> Double {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
        if cleaned.isEmpty { return defaultValue }
        return Double(cleaned) ?? defaultValue
    }

    // MARK: - Soil profile panel

    @ViewBuilder
    private var soilProfileSection: some View {
        if useWholeVineyard {
            wholeVineyardSoilSection
        } else if let paddock = selectedPaddock {
            Section {
                if isLoadingSoilProfile && paddockSoilProfile == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading soil profile…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let soil = paddockSoilProfile {
                    soilProfileSummary(soil)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No soil profile set for this paddock", systemImage: "square.stack.3d.up.slash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Add a soil profile to get soil-aware irrigation guidance.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let advice = result?.soilAdviceText {
                    Label(advice, systemImage: "drop.degreesign")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caution = result?.soilCautionText {
                    Label(caution, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    showSoilProfileEditor = true
                } label: {
                    Label(paddockSoilProfile == nil ? "Add soil profile" : "Edit soil profile",
                          systemImage: "square.and.pencil")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } header: {
                Text("Soil profile")
            } footer: {
                if paddockSoilProfile?.source == "nsw_seed" {
                    Text("Soil information is estimated from NSW SEED mapping and may not reflect site-specific vineyard soil conditions. Adjust soil class and water-holding values using your own soil knowledge where needed.")
                } else {
                    Text("Soil profile values feed the soil buffer and root-zone calculation. Editing requires Owner or Manager access.")
                }
            }
            .sheet(isPresented: $showSoilProfileEditor, onDismiss: {
                Task { await loadSoilProfile(force: true) }
            }) {
                SoilProfileEditorSheet(
                    vineyardId: paddock.vineyardId,
                    paddockId: paddock.id,
                    paddockName: paddock.name,
                    onSaved: { saved in
                        paddockSoilProfile = saved
                    }
                )
            }
        }
    }

    private func soilProfileSummary(_ soil: BackendSoilProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
                Text(soilClassDisplay(soil))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(soil.source.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                soilStat("AWC", soil.availableWaterCapacityMmPerM.map { String(format: "%.0f mm/m", $0) } ?? "—")
                soilStat("Root depth", soil.effectiveRootDepthM.map { String(format: "%.2f m", $0) } ?? "—")
                soilStat("Depletion", soil.managementAllowedDepletionPercent.map { String(format: "%.0f%%", $0) } ?? "—")
            }
            if let rzc = soil.rootZoneCapacityMm, let raw = soil.readilyAvailableWaterMm {
                Text(String(format: "Root-zone capacity %.0f mm • Readily available %.0f mm", rzc, raw))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func soilStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func soilClassDisplay(_ soil: BackendSoilProfile) -> String {
        if let cls = soil.typedSoilClass { return cls.fallbackLabel }
        if let raw = soil.irrigationSoilClass, !raw.isEmpty {
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "Unspecified soil class"
    }

    private func loadVineyardSoilProfiles() async {
        guard let vid = store.selectedVineyardId else {
            vineyardSoilProfiles = []
            return
        }
        do {
            let rows = try await soilProfileRepository.listVineyardSoilProfiles(vineyardId: vid)
            vineyardSoilProfiles = rows
        } catch {
            vineyardSoilProfiles = []
        }
    }

    private func loadVineyardDefaultSoilProfile(force: Bool = false) async {
        guard let vid = store.selectedVineyardId else {
            vineyardDefaultSoilProfile = nil
            return
        }
        do {
            vineyardDefaultSoilProfile = try await soilProfileRepository
                .fetchVineyardDefaultSoilProfile(vineyardId: vid)
        } catch {
            if force { vineyardDefaultSoilProfile = nil }
        }
    }

    @ViewBuilder
    private var wholeVineyardSoilSection: some View {
        Section {
            if let v = vineyardDefaultSoilProfile {
                soilProfileSummary(v)
                Text("Whole Vineyard soil profile. Uses a vineyard-level soil profile for broad irrigation guidance. For more accurate recommendations, select an individual block.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let agg = wholeVineyardAggregatedProfile {
                soilProfileSummary(agg)
                Text("Multiple soil profiles detected across this vineyard. Recommendations use a conservative aggregate. For better accuracy, select an individual block or set a Whole Vineyard soil profile.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("No vineyard soil profile yet", systemImage: "square.stack.3d.up.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Add a Whole Vineyard soil profile for broad guidance, or add block profiles for more accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let advice = result?.soilAdviceText {
                Label(advice, systemImage: "drop.degreesign")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caution = result?.soilCautionText {
                Label(caution, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if accessControl.canChangeSettings, store.selectedVineyardId != nil {
                Button {
                    showWholeVineyardSoilEditor = true
                } label: {
                    Label(vineyardDefaultSoilProfile == nil
                          ? "Add Whole Vineyard Soil Profile"
                          : "Edit Whole Vineyard Soil Profile",
                          systemImage: "square.and.pencil")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } header: {
            Text("Soil profile (Whole Vineyard)")
        } footer: {
            Text("Whole Vineyard mode uses a vineyard-level soil profile when set, otherwise a conservative aggregate of block profiles. Editing requires Owner or Manager access.")
        }
        .sheet(isPresented: $showWholeVineyardSoilEditor, onDismiss: {
            Task { await loadVineyardDefaultSoilProfile(force: true) }
        }) {
            if let vid = store.selectedVineyardId {
                SoilProfileEditorSheet(
                    vineyardId: vid,
                    paddockId: nil,
                    paddockName: "Whole Vineyard",
                    onSaved: { saved in
                        vineyardDefaultSoilProfile = saved
                    }
                )
            }
        }
    }

    private func loadSoilProfile(force: Bool = false) async {
        guard let pid = selectedPaddockId else {
            paddockSoilProfile = nil
            lastLoadedSoilPaddockId = nil
            return
        }
        if !force && lastLoadedSoilPaddockId == pid && paddockSoilProfile != nil { return }
        isLoadingSoilProfile = true
        defer { isLoadingSoilProfile = false }
        do {
            let profile = try await soilProfileRepository.fetchPaddockSoilProfile(paddockId: pid)
            paddockSoilProfile = profile
            lastLoadedSoilPaddockId = pid
        } catch {
            // Leave the profile nil on transient failure; the editor will
            // surface the error if the user opens it.
            paddockSoilProfile = nil
            lastLoadedSoilPaddockId = pid
        }
    }
}
