import SwiftUI
import CoreLocation

struct NewMainTabView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(SubscriptionService.self) private var subscription
    @Environment(TripTrackingService.self) private var tripTracking
    @Environment(PinSyncService.self) private var pinSync
    @Environment(PaddockSyncService.self) private var paddockSync
    @Environment(TripSyncService.self) private var tripSync
    @Environment(SprayRecordSyncService.self) private var sprayRecordSync
    @Environment(SprayJobTemplateService.self) private var sprayJobTemplateService
    @Environment(ButtonConfigSyncService.self) private var buttonConfigSync
    @Environment(SavedChemicalSyncService.self) private var savedChemicalSync
    @Environment(SavedSprayPresetSyncService.self) private var savedSprayPresetSync
    @Environment(SprayEquipmentSyncService.self) private var sprayEquipmentSync
    @Environment(TractorSyncService.self) private var tractorSync
    @Environment(VineyardMachineSyncService.self) private var vineyardMachineSync
    @Environment(FuelPurchaseSyncService.self) private var fuelPurchaseSync
    @Environment(TractorFuelLogSyncService.self) private var tractorFuelLogSync
    @Environment(OperatorCategorySyncService.self) private var operatorCategorySync
    @Environment(WorkTaskTypeSyncService.self) private var workTaskTypeSync
    @Environment(EquipmentItemSyncService.self) private var equipmentItemSync
    @Environment(SavedInputSyncService.self) private var savedInputSync
    @Environment(TripCostAllocationSyncService.self) private var tripCostAllocationSync
    @Environment(GrowthStageImageSyncService.self) private var growthStageImageSync
    @Environment(GrowthStageRecordSyncService.self) private var growthStageRecordSync
    @Environment(WorkTaskSyncService.self) private var workTaskSync
    @Environment(WorkTaskLabourLineSyncService.self) private var workTaskLabourLineSync
    @Environment(WorkTaskMachineLineSyncService.self) private var workTaskMachineLineSync
    @Environment(WorkTaskPaddockSyncService.self) private var workTaskPaddockSync
    @Environment(MaintenanceLogSyncService.self) private var maintenanceLogSync
    @Environment(YieldEstimationSessionSyncService.self) private var yieldSessionSync
    @Environment(DamageRecordSyncService.self) private var damageRecordSync
    @Environment(HistoricalYieldRecordSyncService.self) private var historicalYieldSync
    @Environment(AlertService.self) private var alertService
    @Environment(AppNoticeService.self) private var appNoticeService
    @Environment(SyncStatusCenter.self) private var syncStatusCenter
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Int = 0
    @State private var isSweeping: Bool = false
    @State private var portalPromptTrigger: PortalPromptTrigger?
    @State private var seasonMigrationPrompt: SeasonMigrationPrompt?
    @State private var seasonMigrationError: String?

    /// Used by the full sweep to pull vineyard-scoped organisation region
    /// settings (country/units/date format/terminology) from Supabase.
    private let vineyardRegionRepository: any VineyardRepositoryProtocol = SupabaseVineyardRepository()

    var body: some View {
        TabView(selection: $selectedTab) {
            NewHomeTabView(selectedTab: $selectedTab)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            NavigationStack {
                PinsView()
            }
            .tabItem { Label("Pins", systemImage: "mappin.and.ellipse") }
            .tag(1)

            TripView()
                .tabItem { Label("Trip", systemImage: "steeringwheel") }
                .tag(2)

            NavigationStack {
                SprayProgramView()
            }
            .tabItem { Label("Program", systemImage: "sprinkler.and.droplets.fill") }
            .tag(3)

            BackendSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .environment(\.accessControl, accessControl.legacyAccessControl)
        .safeAreaInset(edge: .top, spacing: 0) {
            OfflineGraceBanner()
                .animation(.easeInOut(duration: 0.25), value: subscription.isRelyingOnOfflineGrace)
        }
        .onAppear {
            if locationService.authorizationStatus == .notDetermined {
                locationService.requestPermission()
            } else if locationService.authorizationStatus == .authorizedWhenInUse || locationService.authorizationStatus == .authorizedAlways {
                locationService.startUpdating()
            }
            tripTracking.configure(store: store, locationService: locationService)
            // Provide active-trip lookup so MigratedDataStore.addPin can
            // self-link any pin dropped during a live trip back to that
            // trip (so the Trip Report shows pins logged > 0 even when
            // the pin was created via QuickPinSheet / RepairsActionView /
            // GrowthObservationActionView / PinDropConfirmationSheet).
            store.currentActiveTripIdProvider = { [weak tripTracking = tripTracking] in
                tripTracking?.activeTrip?.id
            }
            pinSync.configure(store: store, auth: auth)
            paddockSync.configure(store: store, auth: auth)
            tripSync.configure(store: store, auth: auth)
            sprayRecordSync.configure(store: store, auth: auth)
            sprayJobTemplateService.configure(store: store, auth: auth)
            buttonConfigSync.configure(store: store, auth: auth)
            savedChemicalSync.configure(store: store, auth: auth)
            savedSprayPresetSync.configure(store: store, auth: auth)
            sprayEquipmentSync.configure(store: store, auth: auth)
            tractorSync.configure(store: store, auth: auth)
            vineyardMachineSync.configure(store: store, auth: auth)
            fuelPurchaseSync.configure(store: store, auth: auth)
            tractorFuelLogSync.configure(store: store, auth: auth)
            operatorCategorySync.configure(store: store, auth: auth)
            workTaskTypeSync.configure(store: store, auth: auth)
            equipmentItemSync.configure(store: store, auth: auth)
            savedInputSync.configure(store: store, auth: auth)
            tripCostAllocationSync.configure(store: store, auth: auth, accessControl: accessControl)
            growthStageImageSync.configure(store: store, auth: auth)
            growthStageRecordSync.configure(store: store, auth: auth)
            workTaskSync.configure(store: store, auth: auth)
            workTaskLabourLineSync.configure(store: store, auth: auth)
            workTaskMachineLineSync.configure(store: store, auth: auth)
            workTaskPaddockSync.configure(store: store, auth: auth)
            maintenanceLogSync.configure(store: store, auth: auth)
            yieldSessionSync.configure(store: store, auth: auth)
            damageRecordSync.configure(store: store, auth: auth)
            historicalYieldSync.configure(store: store, auth: auth)
            alertService.configure(store: store, auth: auth, accessControl: accessControl)
            appNoticeService.configure(auth: auth)
            Task { await appNoticeService.refresh() }
        }
        .task(id: store.selectedVineyardId) {
            // Hydrate portal spray templates from the offline cache immediately
            // (network-independent) so the template picker works offline.
            sprayJobTemplateService.loadCached(for: store.selectedVineyardId)
            await accessControl.refresh(for: store.selectedVineyardId, auth: auth)
            await runFullSweep(alertRefresh: .generate)
        }
        // Periodic active sync: every 3 minutes while the app is foregrounded
        // and a vineyard is selected. Task is cancelled automatically when
        // scenePhase changes (e.g. backgrounded) or the vineyard switches.
        .task(id: ScenePhaseVineyardKey(scenePhase: scenePhase, vineyardId: store.selectedVineyardId)) {
            guard scenePhase == .active, store.selectedVineyardId != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                if Task.isCancelled { return }
                if scenePhase != .active { return }
                await runFullSweep(alertRefresh: .refresh)
            }
        }
        .onChange(of: alertService.pendingNavigation) { _, action in
            guard let action else { return }
            switch action {
            case .openPins:
                selectedTab = 1
            case .openSprayProgram, .openSprayRecord:
                selectedTab = 3
            case .openIrrigationAdvisor, .openWeather, .openDiseaseRisk, .openWorkTasks, .openPaddocks, .openCostReports:
                // Handled in-place by AlertsCentreView via push.
                break
            }
            alertService.pendingNavigation = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await runFullSweep(alertRefresh: .refresh) }
                Task { await appNoticeService.refresh() }
            }
        }
        // Retry queued pushes the moment the network comes back.
        .onChange(of: network.isOnline) { _, online in
            guard online else {
                // Going offline: keep the indicator's backlog count fresh.
                syncStatusCenter.refreshPending(upserts: aggregatePendingUpserts, deletes: aggregatePendingDeletes, failedUpserts: aggregateFailedUpserts, failedDeletes: aggregateFailedDeletes)
                return
            }
            Task { await runFullSweep(alertRefresh: .refresh) }
        }
        // Manual "Sync now" requested from Sync settings or the status bar.
        .onChange(of: syncStatusCenter.manualSyncToken) { _, _ in
            Task { await runFullSweep(alertRefresh: .refresh) }
        }
        .sheet(item: $portalPromptTrigger) { trigger in
            VineTrackPortalPromptSheet(trigger: trigger, role: accessControl.currentRole)
        }
        // One-time reconciliation between this device's legacy local season
        // start and the shared vineyard value (owners/managers only).
        .alert(
            "Shared Season Settings",
            isPresented: Binding(
                get: { seasonMigrationPrompt != nil },
                set: { if !$0 { seasonMigrationPrompt = nil } }
            ),
            presenting: seasonMigrationPrompt
        ) { prompt in
            Button("Keep shared value (\(prompt.sharedLabel))") {
                store.applyRemoteVineyardSeasonSettings(
                    month: prompt.sharedMonth,
                    day: prompt.sharedDay,
                    vineyardId: prompt.vineyardId
                )
                SeasonSettingsMigrationTracker.markDecided(prompt.vineyardId)
            }
            Button("Use this device's value (\(prompt.localLabel))") {
                Task { await pushDeviceSeasonValue(prompt) }
            }
        } message: { prompt in
            Text("This vineyard's shared season start is \(prompt.sharedLabel), but this device was using \(prompt.localLabel). The season start is now shared with everyone in the vineyard and affects how records are grouped into vintages and \u{201C}This Season\u{201D} reports.")
        }
        .alert("Season Settings", isPresented: Binding(
            get: { seasonMigrationError != nil },
            set: { if !$0 { seasonMigrationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(seasonMigrationError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .vineTrackPortalPromptRequest)) { note in
            guard
                let raw = note.userInfo?["trigger"] as? String,
                let trigger = PortalPromptTrigger(rawValue: raw)
            else { return }
            // Only show for managers and supervisors. Operators get the
            // permanent Settings link instead.
            switch accessControl.currentRole {
            case .owner, .manager, .supervisor:
                break
            default:
                PortalPromptTracker.markSeen(trigger)
                return
            }
            guard !PortalPromptTracker.hasSeen(trigger) else { return }
            // Defer slightly so any presenting sheet has time to dismiss
            // before we present ours (avoids "already presenting" warning).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !PortalPromptTracker.hasSeen(trigger) else { return }
                portalPromptTrigger = trigger
            }
        }
    }

    private enum AlertRefreshMode { case generate, refresh, none }

    /// Runs a full sync sweep across every wired service. Overlapping calls
    /// are coalesced — a second invocation while a sweep is in flight is
    /// dropped so we never run two sweeps in parallel.
    private func runFullSweep(alertRefresh: AlertRefreshMode) async {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        // Always keep the glanceable backlog count current.
        syncStatusCenter.refreshPending(upserts: aggregatePendingUpserts, deletes: aggregatePendingDeletes, failedUpserts: aggregateFailedUpserts, failedDeletes: aggregateFailedDeletes)

        // Offline: everything stays queued locally and retries on reconnect.
        // We skip the network round-trips so we don't generate false errors
        // or drain the battery while out of range.
        guard network.isOnline else { return }

        syncStatusCenter.syncDidStart()
        await pinSync.syncPinsForSelectedVineyard()
        await paddockSync.syncPaddocksForSelectedVineyard()
        await tripSync.syncTripsForSelectedVineyard()
        await sprayRecordSync.syncSprayRecordsForSelectedVineyard()
        await sprayJobTemplateService.syncForSelectedVineyard()
        await buttonConfigSync.syncButtonConfigForSelectedVineyard()
        await savedChemicalSync.syncForSelectedVineyard()
        await savedSprayPresetSync.syncForSelectedVineyard()
        await sprayEquipmentSync.syncForSelectedVineyard()
        await tractorSync.syncForSelectedVineyard()
        await vineyardMachineSync.syncForSelectedVineyard()
        await fuelPurchaseSync.syncForSelectedVineyard()
        await tractorFuelLogSync.syncForSelectedVineyard()
        await operatorCategorySync.syncForSelectedVineyard()
        await workTaskTypeSync.syncForSelectedVineyard()
        await equipmentItemSync.syncForSelectedVineyard()
        await savedInputSync.syncForSelectedVineyard()
        await tripCostAllocationSync.syncForSelectedVineyard()
        await growthStageImageSync.syncForSelectedVineyard()
        await growthStageRecordSync.syncForSelectedVineyard()
        await workTaskSync.syncForSelectedVineyard()
        await workTaskLabourLineSync.syncForSelectedVineyard()
        await workTaskMachineLineSync.syncForSelectedVineyard()
        await workTaskPaddockSync.syncForSelectedVineyard()
        await maintenanceLogSync.syncForSelectedVineyard()
        await yieldSessionSync.syncForSelectedVineyard()
        await damageRecordSync.syncForSelectedVineyard()
        await historicalYieldSync.syncForSelectedVineyard()
        // Vineyard-scoped organisation region/unit settings (country, currency,
        // units, date format, terminology). Previously only pulled on vineyard
        // selection — pulling it here too means a manual/forced "Sync now"
        // picks up changes saved from the Lovable portal or another device.
        await syncVineyardRegionSettings()
        // Shared vineyard season settings (season start month/day, sql/108) —
        // one value per vineyard for every member. Server is authoritative.
        await syncVineyardSeasonSettings()
        switch alertRefresh {
        case .generate: await alertService.generateAndRefresh()
        case .refresh:  await alertService.refresh()
        case .none:     break
        }
        await appNoticeService.refresh()
        syncStatusCenter.syncDidFinish(
            upserts: aggregatePendingUpserts,
            deletes: aggregatePendingDeletes,
            failedUpserts: aggregateFailedUpserts,
            failedDeletes: aggregateFailedDeletes,
            error: aggregateSyncError
        )
    }

    // MARK: - Vineyard region settings

    /// Pull the vineyard-scoped organisation region settings from Supabase and
    /// merge them into local `AppSettings.regionSettings`. Server values win;
    /// any null server field keeps the local fallback (AU default unless an
    /// owner/manager changed it). Called from the full sweep so a manual/forced
    /// "Sync now" applies settings saved on the Lovable portal or another
    /// device, not just on vineyard selection.
    ///
    /// Backfill safety: if the server has *no* region values but the local copy
    /// diverges from AU defaults, push the local copy up exactly once — but
    /// ONLY if the current user is an owner/manager (the server RPC enforces
    /// this too; this is the client guard).
    private func syncVineyardRegionSettings() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        do {
            guard let remote = try await vineyardRegionRepository.getVineyardRegionSettings(vineyardId: vineyardId) else {
                #if DEBUG
                print("[RegionSync] vineyard=\(vineyardId) no server row — keeping local fallback")
                #endif
                return
            }
            #if DEBUG
            let before = store.settings.regionSettings
            #endif
            let merged = store.applyRemoteVineyardRegionSettings(remote, vineyardId: vineyardId)
            #if DEBUG
            let after = store.settings.regionSettings
            print("""
            [RegionSync] vineyard=\(vineyardId)
              server: country=\(remote.countryCode ?? "nil") currency=\(remote.currencyCode ?? "nil") area=\(remote.areaUnit ?? "nil") volume=\(remote.volumeUnit ?? "nil") distance=\(remote.distanceUnit ?? "nil") fuel=\(remote.fuelUnit ?? "nil") sprayRate=\(remote.sprayRateAreaUnit ?? "nil") date=\(remote.dateFormat ?? "nil") term=\(remote.terminologyRegion ?? "nil")
              before: country=\(before.countryCode) currency=\(before.currencyCode) area=\(before.areaUnit) date=\(before.dateFormat) term=\(before.terminologyRegion)
              after:  country=\(after.countryCode) currency=\(after.currencyCode) area=\(after.areaUnit) date=\(after.dateFormat) term=\(after.terminologyRegion)
              savedLocally=\(before != after) needsBackfill=\(merged.needsBackfill)
            """)
            #endif
            guard merged.needsBackfill else { return }

            // Owner/manager-only backfill guard (accessControl is refreshed for
            // the selected vineyard before the sweep runs).
            guard accessControl.canChangeSettings else { return }

            let region = merged.settingsToBackfill
            _ = try? await vineyardRegionRepository.setVineyardRegionSettings(
                BackendVineyardRegionSettings(
                    vineyardId: vineyardId,
                    countryCode: region.countryCode,
                    currencyCode: region.currencyCode,
                    timezone: region.timezone,
                    areaUnit: region.areaUnit,
                    volumeUnit: region.volumeUnit,
                    distanceUnit: region.distanceUnit,
                    fuelUnit: region.fuelUnit,
                    sprayRateAreaUnit: region.sprayRateAreaUnit,
                    dateFormat: region.dateFormat,
                    terminologyRegion: region.terminologyRegion
                )
            )
        } catch {
            // Offline / RPC missing / not a member — keep existing local settings.
            #if DEBUG
            print("[RegionSync] fetch failed for vineyard=\(vineyardId): \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Vineyard season settings

    /// Pull the shared vineyard season start (month/day) from Supabase.
    /// The shared value is authoritative for every member. The only exception
    /// is a one-time reconciliation on devices that carry a diverging legacy
    /// local value AND belong to a user who may edit vineyard settings — they
    /// get a prompt to either adopt the shared value or push their local one
    /// up. Read-only members always adopt the shared value.
    private func syncVineyardSeasonSettings() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        do {
            guard let remote = try await vineyardRegionRepository.getVineyardSeasonSettings(vineyardId: vineyardId) else { return }
            let localMonth = store.settings.seasonStartMonth
            let localDay = store.settings.seasonStartDay

            if localMonth == remote.seasonStartMonth && localDay == remote.seasonStartDay {
                SeasonSettingsMigrationTracker.markDecided(vineyardId)
                return
            }

            let decided = SeasonSettingsMigrationTracker.hasDecided(vineyardId)
            if decided || !accessControl.canChangeSettings {
                store.applyRemoteVineyardSeasonSettings(
                    month: remote.seasonStartMonth,
                    day: remote.seasonStartDay,
                    vineyardId: vineyardId
                )
                if !accessControl.canChangeSettings {
                    SeasonSettingsMigrationTracker.markDecided(vineyardId)
                }
                return
            }

            // Undecided divergence on an editing user's device — one-time prompt.
            guard seasonMigrationPrompt == nil else { return }
            seasonMigrationPrompt = SeasonMigrationPrompt(
                vineyardId: vineyardId,
                localMonth: localMonth,
                localDay: localDay,
                sharedMonth: remote.seasonStartMonth,
                sharedDay: remote.seasonStartDay
            )
        } catch {
            // Offline / RPC missing — keep the cached local value.
            #if DEBUG
            print("[SeasonSync] fetch failed for vineyard=\(vineyardId): \(error.localizedDescription)")
            #endif
        }
    }

    /// Migration choice: push this device's legacy local season value up to
    /// the shared vineyard setting. Only records the decision after the
    /// server confirms the write.
    private func pushDeviceSeasonValue(_ prompt: SeasonMigrationPrompt) async {
        do {
            let saved = try await vineyardRegionRepository.setVineyardSeasonSettings(
                vineyardId: prompt.vineyardId,
                seasonStartMonth: prompt.localMonth,
                seasonStartDay: prompt.localDay
            )
            store.applyRemoteVineyardSeasonSettings(
                month: saved.seasonStartMonth,
                day: saved.seasonStartDay,
                vineyardId: prompt.vineyardId
            )
            SeasonSettingsMigrationTracker.markDecided(prompt.vineyardId)
        } catch {
            seasonMigrationError = "Could not apply this device's season start to the vineyard. The shared value stays in effect — you can change it later in Operation Preferences."
        }
    }

    // MARK: - Aggregate sync state

    /// Total queued upserts across every field-data sync service.
    private var aggregatePendingUpserts: Int {
        pinSync.pendingUpsertCount
            + paddockSync.pendingUpsertCount
            + tripSync.pendingUpsertCount
            + sprayRecordSync.pendingUpsertCount
            + savedChemicalSync.pendingUpsertCount
            + savedSprayPresetSync.pendingUpsertCount
            + sprayEquipmentSync.pendingUpsertCount
            + tractorSync.pendingUpsertCount
            + vineyardMachineSync.pendingUpsertCount
            + fuelPurchaseSync.pendingUpsertCount
            + tractorFuelLogSync.pendingUpsertCount
            + operatorCategorySync.pendingUpsertCount
            + workTaskTypeSync.pendingUpsertCount
            + equipmentItemSync.pendingUpsertCount
            + savedInputSync.pendingUpsertCount
            + tripCostAllocationSync.pendingUpsertCount
            + growthStageRecordSync.pendingUpsertCount
            + workTaskSync.pendingUpsertCount
            + workTaskLabourLineSync.pendingUpsertCount
            + workTaskMachineLineSync.pendingUpsertCount
            + workTaskPaddockSync.pendingUpsertCount
            + maintenanceLogSync.pendingUpsertCount
            + yieldSessionSync.pendingUpsertCount
            + damageRecordSync.pendingUpsertCount
            + historicalYieldSync.pendingUpsertCount
    }

    /// Total queued deletes across every field-data sync service.
    private var aggregatePendingDeletes: Int {
        pinSync.pendingDeleteCount
            + paddockSync.pendingDeleteCount
            + tripSync.pendingDeleteCount
            + sprayRecordSync.pendingDeleteCount
            + savedChemicalSync.pendingDeleteCount
            + savedSprayPresetSync.pendingDeleteCount
            + sprayEquipmentSync.pendingDeleteCount
            + tractorSync.pendingDeleteCount
            + vineyardMachineSync.pendingDeleteCount
            + fuelPurchaseSync.pendingDeleteCount
            + tractorFuelLogSync.pendingDeleteCount
            + operatorCategorySync.pendingDeleteCount
            + workTaskTypeSync.pendingDeleteCount
            + equipmentItemSync.pendingDeleteCount
            + savedInputSync.pendingDeleteCount
            + tripCostAllocationSync.pendingDeleteCount
            + growthStageRecordSync.pendingDeleteCount
            + workTaskSync.pendingDeleteCount
            + workTaskLabourLineSync.pendingDeleteCount
            + workTaskMachineLineSync.pendingDeleteCount
            + workTaskPaddockSync.pendingDeleteCount
            + maintenanceLogSync.pendingDeleteCount
            + yieldSessionSync.pendingDeleteCount
            + damageRecordSync.pendingDeleteCount
            + historicalYieldSync.pendingDeleteCount
    }

    /// Total individual records whose last upload failed, across every
    /// per-record sync service. Used to surface "N records need retry" without
    /// making healthy records look failed.
    private var aggregateFailedUpserts: Int {
        pinSync.failedUpsertIds.count
            + tripSync.failedUpsertIds.count
            + sprayRecordSync.failedUpsertIds.count
            + damageRecordSync.failedUpsertIds.count
            + yieldSessionSync.failedUpsertIds.count
            + workTaskSync.failedUpsertIds.count
    }

    /// Total individual records whose last delete failed, across every
    /// per-record sync service.
    private var aggregateFailedDeletes: Int {
        pinSync.failedDeleteIds.count
            + tripSync.failedDeleteIds.count
            + sprayRecordSync.failedDeleteIds.count
            + damageRecordSync.failedDeleteIds.count
            + yieldSessionSync.failedDeleteIds.count
            + workTaskSync.failedDeleteIds.count
    }

    /// First meaningful sync error reported by any service this sweep, if any.
    /// Plain "not configured" notices are ignored — they aren't actionable
    /// field errors.
    private var aggregateSyncError: String? {
        let messages = [
            pinSync.errorMessage,
            paddockSync.errorMessage,
            tripSync.errorMessage,
            sprayRecordSync.errorMessage,
            savedChemicalSync.errorMessage,
            workTaskSync.errorMessage,
            maintenanceLogSync.errorMessage,
            damageRecordSync.errorMessage,
            yieldSessionSync.errorMessage,
            historicalYieldSync.errorMessage,
        ]
        return messages
            .compactMap { $0 }
            .first { !$0.lowercased().contains("not configured") }
    }
}

private struct ScenePhaseVineyardKey: Hashable {
    let scenePhase: ScenePhase
    let vineyardId: UUID?
}

// MARK: - Home Tab

private struct NewHomeTabView: View {
    @Binding var selectedTab: Int
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(TripTrackingService.self) private var tripTracking

    @State private var showQuickPin: Bool = false
    @State private var showTripChoice: Bool = false
    @State private var showStartTrip: Bool = false
    @State private var showSpraySetup: Bool = false
    @State private var showSetupWizard: Bool = false
    @AppStorage("setupWizardEnabled") private var setupWizardEnabled: Bool = true
    #if DEBUG
    @State private var showBackendDiagnostic: Bool = false
    @State private var showStoreDiagnostic: Bool = false
    #endif


    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    titleHeader
                    if shouldShowSetupWizard {
                        setupWizardCard
                    }
                    if tripTracking.activeTrip != nil {
                        Button {
                            selectedTab = 2
                        } label: {
                            ActiveTripCard()
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                    todaySection
                    if accessControl.canCreateOperationalRecords {
                        quickActionsSection
                    }
                    vineyardOverviewSection
                    operationsSection
                    managementSection
                    summarySection
                    #if DEBUG
                    debugSection
                    #endif
                    Spacer(minLength: 24)
                }
                .padding(.vertical)
            }
            .background(LoginVineyardBackground())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showQuickPin) {
                QuickPinSheet()
            }
            .sheet(isPresented: $showTripChoice) {
                TripTypeChoiceSheet { type in
                    showTripChoice = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        switch type {
                        case .maintenance:
                            showStartTrip = true
                        case .spray:
                            showSpraySetup = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showStartTrip) {
                StartTripSheet()
            }
            .sheet(isPresented: $showSpraySetup) {
                SprayTripSetupSheet()
            }
            .sheet(isPresented: $showSetupWizard) {
                SetupWizardView()
            }
            #if DEBUG
            .sheet(isPresented: $showBackendDiagnostic) {
                BackendDiagnosticHostView()
            }
            .sheet(isPresented: $showStoreDiagnostic) {
                MigratedDataStoreDiagnosticView()
            }
            #endif
        }
    }

    // MARK: Setup Wizard

    private var shouldShowSetupWizard: Bool {
        guard setupWizardEnabled else { return false }
        guard accessControl.canChangeSettings else { return false }
        let hasBlock = !store.paddocks.isEmpty
        let hasTractor = !store.tractors.isEmpty
        let hasRig = !store.sprayEquipment.isEmpty
        return !(hasBlock && hasTractor && hasRig)
    }

    private var setupWizardCard: some View {
        Button {
            showSetupWizard = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 48, height: 48)
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup Wizard")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(setupWizardSubtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [VineyardTheme.leafGreen, VineyardTheme.darkGreen],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: .rect(cornerRadius: 14)
            )
            .shadow(color: VineyardTheme.leafGreen.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var setupWizardSubtitle: String {
        var remaining: [String] = []
        if store.paddocks.isEmpty { remaining.append("block") }
        if store.tractors.isEmpty { remaining.append("tractor") }
        if store.sprayEquipment.isEmpty { remaining.append("spray rig") }
        if remaining.isEmpty {
            return "All set — tap to review"
        }
        return "Add a " + remaining.joined(separator: ", ") + " to get started"
    }

    // MARK: Header

    private var titleHeader: some View {
        HStack(spacing: 12) {
            if let data = store.selectedVineyard?.logoData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(VineyardTheme.leafGreen.gradient)
                        .frame(width: 40, height: 40)
                    GrapeVineLeafShape()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                }
            }
            // The vineyard name is a switcher only when the user belongs to
            // more than one vineyard (portal parity). Single-vineyard users
            // see a plain, finished-looking title with no dropdown affordance.
            if store.vineyards.count > 1 {
                Menu {
                    ForEach(store.vineyards, id: \.id) { vineyard in
                        Button {
                            guard vineyard.id != store.selectedVineyardId else { return }
                            store.selectVineyard(vineyard)
                        } label: {
                            if vineyard.id == store.selectedVineyardId {
                                Label(vineyard.name, systemImage: "checkmark")
                            } else {
                                Text(vineyard.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(store.selectedVineyard?.name ?? "Select vineyard")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                }
                .accessibilityLabel("Switch vineyard. Current: \(store.selectedVineyard?.name ?? "none selected")")
            } else {
                Text(store.selectedVineyard?.name ?? "No Vineyard")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            HomeSyncStatusChip()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func plainSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.subheadline.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.95))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }

    private func formattedNumber(_ value: Int) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1000.0)
        }
        return "\(value)"
    }

    /// Region-aware area value (hectares → configured unit) for the compact
    /// overview tile. Keeps the AU "%.0f / %.1f" rounding behaviour.
    private func formattedHectares(_ hectares: Double) -> String {
        let value = fmt.areaValue(hectares: hectares)
        if value >= 100 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    /// Full-word label for the configured area unit (e.g. "Hectares" / "Acres").
    private var areaUnitLabel: String {
        fmt.settings.area == .hectares ? "Hectares" : "Acres"
    }

    // MARK: Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppNoticesBanner()
            plainSectionHeader("Today")
            HomeRainSummaryCard()
            HomeAlertsCard()
        }
    }

    // MARK: Vineyard Overview

    private var totalHectares: Double {
        store.paddocks.reduce(0.0) { $0 + $1.areaHectares }
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var totalVines: Int {
        store.paddocks.reduce(0) { $0 + $1.effectiveVineCount }
    }

    private var vineyardOverviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            plainSectionHeader("Vineyard Overview")
            NavigationLink {
                VineyardDetailsView()
            } label: {
                VineyardCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(VineyardTheme.leafGreen.opacity(0.15))
                                    .frame(width: 48, height: 48)
                                if let data = store.selectedVineyard?.logoData, let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 48, height: 48)
                                        .clipShape(.rect(cornerRadius: 12))
                                } else {
                                    Image(systemName: "map.fill")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(VineyardTheme.leafGreen)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.selectedVineyard?.name ?? "No vineyard selected")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("View map & summary")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Divider()
                        HStack(spacing: 0) {
                            overviewStat(icon: "square.grid.2x2.fill", iconColor: VineyardTheme.leafGreen, value: "\(store.paddocks.count)", label: fmt.blockTermPluralCapitalised)
                            Divider().frame(height: 44)
                            overviewStat(icon: "square.dashed", iconColor: .orange, value: formattedHectares(totalHectares), label: areaUnitLabel)
                            Divider().frame(height: 44)
                            overviewStatCustom(value: formattedNumber(totalVines), label: "Vines") {
                                GrapeLeafIcon(size: 14, color: VineyardTheme.darkGreen)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
    }

    private func overviewStatCustom<Icon: View>(value: String, label: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 4) {
            icon()
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func overviewStat(icon: String, iconColor: Color, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(iconColor)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            plainSectionHeader("Quick Actions")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                NavigationLink {
                    RepairsGrowthView(initial: .repairs)
                } label: {
                    quickActionTileLabel(title: "Repairs", systemIcon: "wrench.fill", colors: [.orange, Color.orange.opacity(0.75)])
                }
                .buttonStyle(.plain)
                NavigationLink {
                    RepairsGrowthView(initial: .growth)
                } label: {
                    quickActionTileLabel(title: "Growth", grapeLeaf: true, colors: [VineyardTheme.leafGreen, VineyardTheme.darkGreen])
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
    }

    private func quickActionTileLabel(title: String, systemIcon: String? = nil, grapeLeaf: Bool = false, colors: [Color]) -> some View {
        VStack(spacing: 8) {
            Group {
                if grapeLeaf {
                    GrapeLeafIcon(size: 24, color: .white)
                } else if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, minHeight: 76)
        .padding(12)
        .background(
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 14)
        )
        .shadow(color: colors.first?.opacity(0.25) ?? .clear, radius: 4, y: 2)
    }

    // MARK: Operational Tools

    private var operationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            plainSectionHeader("Operational Tools")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                NavigationLink {
                    WorkTasksHubView()
                } label: {
                    iconTile(title: "Work Tasks", icon: "person.2.badge.gearshape.fill", tint: .indigo)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    MaintenanceLogListView()
                } label: {
                    iconTile(title: "Maintenance Log", icon: "wrench.and.screwdriver.fill", tint: VineyardTheme.earthBrown)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    FuelLogHubView()
                } label: {
                    iconTile(title: "Fuel Log", icon: "fuelpump.fill", tint: .red)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    IrrigationRecommendationView()
                } label: {
                    iconTile(title: "Irrigation Advisor", icon: "drop.fill", tint: .cyan)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    DiseaseRiskAdvisorView()
                } label: {
                    iconTile(title: "Disease Risk", icon: "leaf.arrow.triangle.circlepath", tint: .green)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    YieldHubView()
                } label: {
                    iconTile(title: "Yields", icon: "chart.bar.fill", tint: .orange)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    GrowthStageRecordsListView()
                } label: {
                    iconTile(title: "Growth Stage Records", icon: "leaf.fill", tint: VineyardTheme.leafGreen)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    OptimalRipenessHubView()
                } label: {
                    iconTile(title: "Optimal Ripeness", icon: "thermometer.sun.fill", tint: .pink)
                }
                .buttonStyle(.plain)
                if accessControl.canViewCosting {
                    NavigationLink {
                        CostReportsView()
                    } label: {
                        iconTile(title: "Cost Reports", icon: "dollarsign.circle.fill", tint: .green)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func iconTile(title: String, icon: String, tint: Color) -> some View {
        operationalTile(title: title, subtitle: subtitleFor(title), icon: icon, tint: tint)
    }

    private func subtitleFor(_ title: String) -> String {
        switch title {
        case "Work Tasks": return "Log & calculate"
        case "Maintenance Log": return "Repairs & jobs"
        case "Optimal Ripeness": return "GDD & harvest window"
        case "Cost Reports": return "Block & variety costing"
        case "Fuel Log": return "Purchases & refuelling"
        case "Growth Stage Records": return "Observations & PDF export"
        case "Yields": return "Forecasting, Sampling & Recording"
        case "Yield Forecasting": return "Potential, samples & reports"
        case "Yield Estimation": return "Forecast crop"
        case "Irrigation Advisor": return "Water planning"
        case "Disease Risk": return "Downy/Powdery/Botrytis"
        case "Yield Determination": return "Pruning bud-load"
        case "Manage Users": return "Team & roles"
        case "Vineyard Setup": return "Blocks & rows"
        default: return ""
        }
    }

    private func operationalTile(title: String, subtitle: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 138, maxHeight: 138, alignment: .topLeading)
        .padding(14)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(VineyardTheme.cardBorder, lineWidth: 0.5)
        )
    }

    // MARK: Management

    @ViewBuilder
    private var managementSection: some View {
        if accessControl.canChangeSettings {
            VStack(alignment: .leading, spacing: 10) {
                plainSectionHeader("Management")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    if let vineyard = store.selectedVineyard {
                        NavigationLink {
                            BackendTeamAccessView(vineyardId: vineyard.id, vineyardName: vineyard.name)
                        } label: {
                            iconTile(title: "Manage Users", icon: "person.2.fill", tint: .blue)
                        }
                        .buttonStyle(.plain)
                    }
                    NavigationLink {
                        VineyardSetupHubView()
                    } label: {
                        iconTile(title: "Vineyard Setup", icon: "gearshape.2.fill", tint: .gray)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            plainSectionHeader("Recent")

            VineyardCard {
                VStack(spacing: 10) {
                    NavigationLink {
                        PinsView(initialViewMode: .summary)
                    } label: {
                        HStack(spacing: 12) {
                            summaryRow("Pins", value: store.pins.count, icon: "mappin.circle.fill", tint: .red)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                    summaryRow("Trips", value: store.trips.count, icon: "map.fill", tint: .blue)
                    Divider()
                    summaryRow("Spray records", value: store.sprayRecords.count, icon: "sprinkler.and.droplets.fill", tint: .purple)
                    Divider()
                    summaryRow(fmt.blockTermPluralCapitalised, value: store.paddocks.count, icon: "square.grid.2x2.fill", tint: VineyardTheme.leafGreen)
                }
            }
            .padding(.horizontal)
        }
    }

    private func summaryRow(_ label: String, value: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(label)
                .foregroundStyle(VineyardTheme.textPrimary)
            Spacer()
            Text("\(value)")
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func hubRow(title: String, subtitle: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(VineyardTheme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            plainSectionHeader("Debug")
            VineyardCard(padding: 0) {
                VStack(spacing: 0) {
                    Button {
                        showBackendDiagnostic = true
                    } label: {
                        hubRow(title: "Backend Diagnostic", subtitle: "Inspect Supabase state", icon: "stethoscope", tint: .gray)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 60)
                    Button {
                        showStoreDiagnostic = true
                    } label: {
                        hubRow(title: "MigratedDataStore", subtitle: "Local storage", icon: "tray.full", tint: .gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
    #endif
}
