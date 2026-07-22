import SwiftUI

/// Owner/Manager-only guided setup that walks new users through:
///  1. Intro
///  2. Davis WeatherLink (status, refresh, backfill)
///  3. Weather Underground (find nearby station, save, backfill)
///  4. Summary of configured sources + rainfall priority
///  5. Finish — links to Rain Calendar / Irrigation / Weather Settings
///
/// Reuses the existing services and pickers used by
/// `WeatherDataSettingsView` (`VineyardDavisProxyService`,
/// `VineyardWundergroundProxyService`, `WundergroundStationPickerSheet`)
/// rather than duplicating logic. Davis credentials/test/station picking
/// remain in `WeatherDataSettingsView` — the wizard surfaces status and
/// nudges the user back there if Davis is not yet connected.
struct WeatherSetupWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl

    enum Step: Int, CaseIterable, Hashable {
        case intro, davis, wunderground, openMeteo, summary, finish
        var title: String {
            switch self {
            case .intro: return "Welcome"
            case .davis: return "Davis WeatherLink"
            case .wunderground: return "Weather Underground"
            case .openMeteo: return "Open-Meteo"
            case .summary: return "Summary"
            case .finish: return "Done"
            }
        }
    }

    @State private var step: Step = .intro

    // Davis state
    @State private var davisRefreshing: Bool = false
    @State private var davisRefreshStatus: String?
    @State private var davisRefreshOk: Bool = false
    @State private var isBackfillingDavis: Bool = false
    @State private var davisBackfillStatus: String?
    @State private var davisBackfillOk: Bool = false
    @State private var davisRowsBackfilled: Int = 0
    @State private var davisSkipped: Bool = false

    // WU state
    @State private var wuIntegration: VineyardWeatherIntegration?
    @State private var isLoadingWu: Bool = false
    @State private var showWuPicker: Bool = false
    @State private var wuStationIdInput: String = ""
    @State private var wuStationNameInput: String = ""
    @State private var isSavingWu: Bool = false
    @State private var wuSaveStatus: String?
    @State private var wuSaveOk: Bool = false
    @State private var isBackfillingWu: Bool = false
    @State private var wuBackfillStatus: String?
    @State private var wuBackfillOk: Bool = false
    @State private var wuRowsBackfilled: Int = 0
    @State private var wuSkipped: Bool = false

    // Open-Meteo state
    @State private var showBuildHistorySheet: Bool = false
    @State private var isBackfillingOpenMeteo: Bool = false
    @State private var openMeteoStatus: String?
    @State private var openMeteoOk: Bool = false
    @State private var openMeteoRowsBackfilled: Int = 0
    @State private var openMeteoSkipped: Bool = false

    private let integrationRepository: any VineyardWeatherIntegrationRepositoryProtocol
        = SupabaseVineyardWeatherIntegrationRepository()

    private var canEdit: Bool { accessControl.canChangeSettings }
    private var vineyardId: UUID? { store.selectedVineyardId }

    private var davisConfig: WeatherProviderConfig {
        guard let vid = vineyardId else { return .default }
        return WeatherProviderStore.shared.config(for: vid)
    }

    private var davisConfigured: Bool {
        let cfg = davisConfig
        let hasShared = cfg.davisIsVineyardShared
            && cfg.davisVineyardHasServerCredentials
        let hasStation = (cfg.davisStationId?.isEmpty == false)
        return hasShared && hasStation
    }

    private var davisStationLabel: String? {
        let cfg = davisConfig
        if let n = cfg.davisStationName, !n.isEmpty { return n }
        if let s = cfg.davisStationId, !s.isEmpty { return "Station \(s)" }
        return nil
    }

    private var hasCoordinates: Bool {
        let s = store.settings
        if let lat = s.vineyardLatitude, let lon = s.vineyardLongitude,
           lat != 0 || lon != 0 { return true }
        if let lat = store.paddockCentroidLatitude,
           let lon = store.paddockCentroidLongitude,
           lat != 0 || lon != 0 { return true }
        return false
    }

    private var wuConfigured: Bool {
        !(wuIntegration?.stationId ?? "").isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    progressHeader
                    Group {
                        switch step {
                        case .intro: introStep
                        case .davis: davisStep
                        case .wunderground: wuStep
                        case .openMeteo: openMeteoStep
                        case .summary: summaryStep
                        case .finish: finishStep
                        }
                    }
                    .padding(.horizontal, 4)

                    Spacer(minLength: 12)

                    navigationButtons
                }
                .padding(20)
            }
            .navigationTitle("Weather Setup Wizard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showWuPicker) {
                if let vid = vineyardId {
                    WundergroundStationPickerSheet(vineyardId: vid) { stationId, stationName in
                        wuStationIdInput = stationId
                        wuStationNameInput = stationName ?? ""
                        wuSaveOk = true
                        wuSaveStatus = "Weather Underground station saved."
                        Task { await loadWu(for: vid) }
                    }
                }
            }
            .sheet(isPresented: $showBuildHistorySheet) {
                IrrigationMissingRainHelperSheet(
                    vineyardId: vineyardId,
                    rainfallWindowDays: 14,
                    onCompleted: {
                        NotificationCenter.default.post(
                            name: .rainfallCalendarShouldReload, object: nil
                        )
                    }
                )
                .environment(accessControl)
            }
        }
        .onAppear {
            if let vid = vineyardId {
                Task { await loadWu(for: vid) }
            }
        }
    }

    // MARK: - Progress

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(stepColor(s))
                        .frame(height: 4)
                }
            }
            HStack {
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(step.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
    }

    private func stepColor(_ s: Step) -> Color {
        if s.rawValue < step.rawValue { return .green }
        if s == step { return .accentColor }
        return Color.secondary.opacity(0.25)
    }

    // MARK: - Steps

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "cloud.sun.rain.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Set up vineyard weather")
                .font(.title2.weight(.bold))
            Text("VineTrack can use your vineyard weather station to improve rainfall history, irrigation advice, alerts and spray planning.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                bullet(symbol: "antenna.radiowaves.left.and.right", color: .blue, title: "Davis WeatherLink (optional)", detail: "If you own a WeatherLink-enabled station, connect it for the most accurate vineyard rainfall and leaf wetness. Skip this step if you don't have one.")
                bullet(symbol: "wifi.router", color: .orange, title: "Weather Underground", detail: "Pick a nearby Personal Weather Station as a backup rainfall source.")
                bullet(symbol: "calendar.badge.clock", color: .green, title: "Rainfall history", detail: "Backfill recent rainfall after setup so the Rain Calendar has useful history.")
            }

            if !canEdit {
                infoCard(color: .orange, symbol: "person.badge.shield.checkmark.fill",
                         title: "Read-only access",
                         body: "Only owners and managers can configure weather services. Ask your owner or manager to run this wizard.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Source priority")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Manual → Davis → Weather Underground → Open-Meteo")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
        }
    }

    private var davisStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(symbol: "antenna.radiowaves.left.and.right", color: .blue, title: "Davis WeatherLink")

            if davisConfigured {
                infoCard(color: .green, symbol: "checkmark.seal.fill",
                         title: "Davis is connected",
                         body: davisStationLabel.map { "Station: \($0)" } ?? "Vineyard-shared Davis credentials are saved on the server.")

                if canEdit {
                    Button {
                        Task { await refreshDavisNow() }
                    } label: {
                        HStack {
                            if davisRefreshing { ProgressView().controlSize(.small) }
                            Label(davisRefreshing ? "Refreshing…" : "Refresh Davis now",
                                  systemImage: "arrow.triangle.2.circlepath.cloud")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(davisRefreshing)

                    if let msg = davisRefreshStatus, !msg.isEmpty {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(davisRefreshOk ? .green : .red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Task { await runDavisBackfill() }
                    } label: {
                        HStack {
                            if isBackfillingDavis { ProgressView().controlSize(.small) }
                            Label(isBackfillingDavis ? "Backfilling…" : "Backfill Davis rainfall (14 days)",
                                  systemImage: "calendar.badge.clock")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(isBackfillingDavis)

                    if let msg = davisBackfillStatus, !msg.isEmpty {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(davisBackfillOk ? .green : .red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Backfill is safe to re-run. Manual rainfall corrections are never overwritten.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                infoCard(color: .orange, symbol: "key.slash",
                         title: "Davis is not connected yet",
                         body: "Davis credentials live in the Davis section of Weather Data & Forecasting. Close the wizard to enter your WeatherLink API key, secret and pick a station, then run the wizard again to backfill rainfall.")

                Text("Davis is optional. If you don't own a Davis WeatherLink station, skip this step and use Weather Underground instead.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    davisSkipped = true
                    advance()
                } label: {
                    Label("I don't have a Davis — skip", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.gray)

                Button {
                    dismiss()
                } label: {
                    Label("I have a Davis — open settings", systemImage: "gearshape.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
        }
    }

    private var wuStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(symbol: "wifi.router", color: .orange, title: "Weather Underground")

            Text("Pick a Personal Weather Station near your vineyard. WU only fills days where Manual and Davis are missing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if wuConfigured {
                infoCard(color: .green, symbol: "checkmark.seal.fill",
                         title: "Weather Underground station saved",
                         body: {
                            let sid = wuIntegration?.stationId ?? ""
                            let name = (wuIntegration?.stationName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            return name.isEmpty ? sid : "\(name) (\(sid))"
                         }())
            }

            if canEdit {
                Button {
                    showWuPicker = true
                } label: {
                    Label("Find nearby WU stations", systemImage: "location.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vineyardId == nil || !hasCoordinates)

                if !hasCoordinates {
                    Text("Vineyard coordinates are required to find nearby Weather Underground stations.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Or enter station ID manually")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Station ID")
                        Spacer()
                        TextField("e.g. KCASANFR123", text: $wuStationIdInput)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                    }
                    HStack {
                        Text("Station name")
                        Spacer()
                        TextField("Optional", text: $wuStationNameInput)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                    }
                    Button {
                        Task { await saveWu() }
                    } label: {
                        HStack {
                            if isSavingWu { ProgressView().controlSize(.small) }
                            Label(isSavingWu ? "Saving…" : "Save station",
                                  systemImage: "externaldrive.fill.badge.icloud")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSavingWu || wuStationIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))

                if let msg = wuSaveStatus, !msg.isEmpty {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(wuSaveOk ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await runWuBackfill() }
                } label: {
                    HStack {
                        if isBackfillingWu { ProgressView().controlSize(.small) }
                        Label(isBackfillingWu ? "Backfilling…" : "Backfill Weather Underground rainfall (14 days)",
                              systemImage: "calendar.badge.clock")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isBackfillingWu || !wuConfigured || vineyardId == nil)

                if let msg = wuBackfillStatus, !msg.isEmpty {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(wuBackfillOk ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("WU rows never overwrite Manual or Davis rainfall. Today is skipped because the daily summary is incomplete.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var openMeteoStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(symbol: "tray.full.fill", color: .gray, title: "Open-Meteo fallback")

            Text("Use Open-Meteo archive data only for days where no Manual, Davis or Weather Underground rainfall record exists.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            infoCard(color: .gray, symbol: "info.circle.fill",
                     title: "Optional step",
                     body: "You can skip this and run it later from Weather Data & Forecasting. Open-Meteo never overwrites Manual, Davis or Weather Underground rows.")

            if canEdit {
                Button {
                    Task { await runOpenMeteoBackfill() }
                } label: {
                    HStack {
                        if isBackfillingOpenMeteo { ProgressView().controlSize(.small) }
                        Label(isBackfillingOpenMeteo ? "Filling gaps…" : "Fill remaining gaps with Open-Meteo (365 days)",
                              systemImage: "calendar.badge.plus")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.gray)
                .disabled(isBackfillingOpenMeteo || vineyardId == nil)

                if let msg = openMeteoStatus, !msg.isEmpty {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(openMeteoOk ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Today and yesterday are skipped because the archive is incomplete.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(symbol: "list.bullet.rectangle", color: .indigo, title: "Setup summary")

            VStack(spacing: 10) {
                summaryRow(symbol: "antenna.radiowaves.left.and.right",
                           label: "Davis configured",
                           value: davisConfigured ? "Yes" : (davisSkipped ? "Skipped" : "No"),
                           ok: davisConfigured)
                summaryRow(symbol: "wifi.router",
                           label: "WU station configured",
                           value: wuConfigured ? "Yes" : (wuSkipped ? "Skipped" : "No"),
                           ok: wuConfigured)
                summaryRow(symbol: "calendar.badge.clock",
                           label: "Davis rows backfilled",
                           value: "\(davisRowsBackfilled)",
                           ok: davisRowsBackfilled > 0)
                summaryRow(symbol: "calendar.badge.clock",
                           label: "WU rows backfilled",
                           value: "\(wuRowsBackfilled)",
                           ok: wuRowsBackfilled > 0)
                summaryRow(symbol: "tray.full.fill",
                           label: "Open-Meteo rows backfilled",
                           value: openMeteoSkipped && openMeteoRowsBackfilled == 0 ? "Skipped" : "\(openMeteoRowsBackfilled)",
                           ok: openMeteoRowsBackfilled > 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Rainfall source priority")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Manual → Davis → Weather Underground → Open-Meteo")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                Text("Higher-priority rows are never overwritten by lower-priority sources.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))

            if canEdit {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.indigo)
                            .frame(width: 32, height: 32)
                            .background(Color.indigo.opacity(0.15), in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Build full 365-day rainfall history")
                                .font(.subheadline.weight(.semibold))
                            Text("Optional. Runs Davis → Weather Underground → Open-Meteo to fill the past year.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("Open-Meteo only fills days still missing after Manual, Davis and Weather Underground records.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        showBuildHistorySheet = true
                    } label: {
                        Label("Build 365-day rainfall history", systemImage: "cloud.rain.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(vineyardId == nil)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.indigo.opacity(0.06), in: .rect(cornerRadius: 12))
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Weather setup complete")
                    .font(.title2.weight(.bold))
                Text("You can revisit the wizard any time from Weather Data & Forecasting.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 10) {
                finishLink(symbol: "drop.fill", color: .blue, title: "Open Rain Calendar",
                           detail: "Review rainfall history and confirm backfilled rows.")
                finishLink(symbol: "leaf.fill", color: .green, title: "Open Irrigation Advisor",
                           detail: "See updated irrigation recommendations.")
                finishLink(symbol: "gearshape.fill", color: .indigo, title: "Open Weather Settings",
                           detail: "Fine-tune providers, station selection and diagnostics.")
            }

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            if step != .intro && step != .finish {
                Button {
                    goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if step != .finish {
                Button {
                    advance()
                } label: {
                    HStack {
                        Text(nextLabel)
                        Image(systemName: "chevron.right")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var nextLabel: String {
        switch step {
        case .intro: return "Get started"
        case .davis: return davisConfigured ? "Continue" : "Skip Davis"
        case .wunderground: return wuConfigured ? "Continue" : "Skip Weather Underground"
        case .openMeteo: return openMeteoRowsBackfilled > 0 ? "Continue" : "Skip Open-Meteo"
        case .summary: return "Finish"
        case .finish: return "Done"
        }
    }

    private func advance() {
        if step == .davis && !davisConfigured { davisSkipped = true }
        if step == .wunderground && !wuConfigured { wuSkipped = true }
        if step == .openMeteo && openMeteoRowsBackfilled == 0 { openMeteoSkipped = true }
        let next = min(step.rawValue + 1, Step.allCases.count - 1)
        if let s = Step(rawValue: next) {
            withAnimation(.easeInOut) { step = s }
        }
    }

    private func goBack() {
        let prev = max(step.rawValue - 1, 0)
        if let s = Step(rawValue: prev) {
            withAnimation(.easeInOut) { step = s }
        }
    }

    // MARK: - Reusable UI

    private func bullet(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.15), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func sectionHeader(symbol: String, color: Color, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.15), in: .rect(cornerRadius: 8))
            Text(title).font(.title3.weight(.bold))
        }
    }

    private func infoCard(color: Color, symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.15), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    private func summaryRow(symbol: String, label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(ok ? .green : .secondary)
                .frame(width: 24)
            Text(label).font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ok ? .green : .secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8))
    }

    private func finishLink(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.15), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 10))
    }

    // MARK: - Actions

    private func refreshDavisNow() async {
        guard let vid = vineyardId else { return }
        let cfg = WeatherProviderStore.shared.config(for: vid)
        guard let sid = cfg.davisStationId, !sid.isEmpty else {
            davisRefreshStatus = "No Davis station selected."
            davisRefreshOk = false
            return
        }
        davisRefreshing = true
        defer { davisRefreshing = false }
        do {
            _ = try await VineyardDavisProxyService.fetchCurrentConditions(
                vineyardId: vid, stationId: sid
            )
            davisRefreshStatus = "Davis refreshed."
            davisRefreshOk = true
            NotificationCenter.default.post(
                name: .rainfallCalendarShouldReload, object: nil
            )
        } catch {
            davisRefreshOk = false
            davisRefreshStatus = "Refresh failed — \(error.localizedDescription)"
        }
    }

    private func runDavisBackfill() async {
        guard canEdit, let vid = vineyardId else { return }
        let cfg = WeatherProviderStore.shared.config(for: vid)
        guard let sid = cfg.davisStationId, !sid.isEmpty else {
            davisBackfillStatus = "No Davis station selected."
            davisBackfillOk = false
            return
        }
        isBackfillingDavis = true
        davisBackfillStatus = nil
        defer { isBackfillingDavis = false }
        do {
            let r = try await VineyardDavisProxyService.backfillRainfall(
                vineyardId: vid, stationId: sid, days: 14
            )
            davisRowsBackfilled = r.rowsUpserted
            davisBackfillOk = r.success
            var lines: [String] = []
            lines.append(r.success
                         ? "Davis rainfall backfill complete."
                         : "Davis rainfall backfill finished with errors.")
            lines.append("Days requested: \(r.daysRequested). Processed: \(r.daysProcessed). Rows upserted: \(r.rowsUpserted). Errors: \(r.errorsCount).")
            davisBackfillStatus = lines.joined(separator: " ")
            if r.rowsUpserted > 0 {
                NotificationCenter.default.post(
                    name: .rainfallCalendarShouldReload, object: nil
                )
            }
        } catch let error as VineyardDavisProxyError {
            davisBackfillOk = false
            davisBackfillStatus = "Davis backfill failed — \(error.errorDescription ?? "unknown error")"
        } catch {
            davisBackfillOk = false
            davisBackfillStatus = "Davis backfill failed — \(error.localizedDescription)"
        }
    }

    private func loadWu(for vid: UUID) async {
        isLoadingWu = true
        defer { isLoadingWu = false }
        do {
            let integ = try await integrationRepository.fetch(
                vineyardId: vid, provider: "wunderground"
            )
            wuIntegration = integ
            if wuStationIdInput.isEmpty {
                wuStationIdInput = integ?.stationId ?? ""
            }
            if wuStationNameInput.isEmpty {
                wuStationNameInput = integ?.stationName ?? ""
            }
        } catch {
            // ignore — non-critical
        }
    }

    private func saveWu() async {
        guard canEdit, let vid = vineyardId else { return }
        let trimmedId = wuStationIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }
        let trimmedName = wuStationNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isSavingWu = true
        wuSaveStatus = nil
        defer { isSavingWu = false }
        do {
            let payload = VineyardWeatherIntegrationSave(
                p_vineyard_id: vid,
                p_provider: "wunderground",
                p_api_key: nil,
                p_api_secret: nil,
                p_station_id: trimmedId,
                p_station_name: trimmedName.isEmpty ? nil : trimmedName,
                p_station_latitude: nil,
                p_station_longitude: nil,
                p_has_leaf_wetness: nil,
                p_has_rain: true,
                p_has_wind: nil,
                p_has_temperature_humidity: nil,
                p_detected_sensors: nil,
                p_last_tested_at: nil,
                p_last_test_status: nil,
                p_is_active: true
            )
            try await integrationRepository.save(payload)
            wuSaveOk = true
            wuSaveStatus = "Weather Underground station saved."
            await loadWu(for: vid)
        } catch {
            wuSaveOk = false
            wuSaveStatus = "Could not save — \(error.localizedDescription)"
        }
    }

    private func runWuBackfill() async {
        guard canEdit, let vid = vineyardId else { return }
        guard wuConfigured else {
            wuBackfillStatus = "Add a Weather Underground station ID first."
            wuBackfillOk = false
            return
        }
        isBackfillingWu = true
        wuBackfillStatus = nil
        defer { isBackfillingWu = false }
        do {
            let r = try await VineyardWundergroundProxyService.backfillRainfall(
                vineyardId: vid, stationId: nil, days: 14
            )
            wuRowsBackfilled = r.rowsUpserted
            wuBackfillOk = r.success
            var lines: [String] = []
            lines.append(r.success
                         ? "Weather Underground rainfall backfill complete."
                         : "Weather Underground rainfall backfill finished with errors.")
            lines.append("Days requested: \(r.daysRequested). Processed: \(r.daysProcessed). Rows upserted: \(r.rowsUpserted). Errors: \(r.errorsCount).")
            if let v = r.proxyVersion, !v.isEmpty {
                lines.append("Proxy version: \(v).")
            }
            wuBackfillStatus = lines.joined(separator: " ")
            if r.rowsUpserted > 0 {
                NotificationCenter.default.post(
                    name: .rainfallCalendarShouldReload, object: nil
                )
            }
        } catch let error as VineyardWundergroundProxyError {
            wuBackfillOk = false
            wuBackfillStatus = "WU backfill failed — \(error.errorDescription ?? "unknown error")"
        } catch {
            wuBackfillOk = false
            wuBackfillStatus = "WU backfill failed — \(error.localizedDescription)"
        }
    }

    private func runOpenMeteoBackfill() async {
        guard canEdit, let vid = vineyardId else { return }
        isBackfillingOpenMeteo = true
        openMeteoStatus = nil
        defer { isBackfillingOpenMeteo = false }
        do {
            let r = try await VineyardOpenMeteoProxyService.backfillRainfallGaps(
                vineyardId: vid, days: 365, timezone: TimeZone.current.identifier
            )
            openMeteoRowsBackfilled = r.rowsUpserted
            openMeteoOk = r.success
            var lines: [String] = []
            lines.append(r.success
                         ? "Open-Meteo gap fill complete."
                         : "Open-Meteo gap fill finished with errors.")
            lines.append("Days requested: \(r.daysRequested). Processed: \(r.daysProcessed). Rows upserted: \(r.rowsUpserted). Skipped (better source): \(r.daysSkippedBetterSource). Skipped (no data): \(r.daysSkippedNoData). Errors: \(r.errorsCount).")
            if let v = r.proxyVersion, !v.isEmpty {
                lines.append("Proxy version: \(v).")
            }
            openMeteoStatus = lines.joined(separator: " ")
            if r.rowsUpserted > 0 {
                NotificationCenter.default.post(
                    name: .rainfallCalendarShouldReload, object: nil
                )
            }
        } catch let error as VineyardOpenMeteoProxyError {
            openMeteoOk = false
            openMeteoStatus = "Open-Meteo gap fill failed — \(error.errorDescription ?? "unknown error")"
        } catch {
            openMeteoOk = false
            openMeteoStatus = "Open-Meteo gap fill failed — \(error.localizedDescription)"
        }
    }
}
