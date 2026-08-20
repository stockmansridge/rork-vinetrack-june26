import SwiftUI

/// Resistance Planner — the PLAN LIST.
///
/// Opening the Planner always lands here: every live plan for the selected vineyard,
/// filterable by season and disease. A vineyard may legitimately hold several plans
/// for the SAME season and disease (a trial-block plan, a "plan B"), so nothing here
/// ever auto-selects a plan — tapping a row opens `ResistancePlanEditorView` by stable
/// `resistance_plans.id`, and returning always comes back to this list.
///
/// Mirrors `ResistancePlannerScreen.kt` on Android.
struct ResistancePlannerView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth

    /// Server-authoritative with a local cache. The remote is attached only when Supabase
    /// is configured; without it the repository degrades to a device-local cache rather
    /// than failing, so the Planner still works for a signed-out or offline grower.
    @State private var planRepository = ResistancePlannerView.makeRepository()
    /// Nil = all seasons. Matched against `seasonId` (`"2026/27"`).
    @State private var seasonFilter: String?
    /// Nil = all diseases.
    @State private var diseaseFilter: ResistanceDisease?
    @State private var showNewPlan: Bool = false
    @State private var openRoute: ResistancePlanRoute?
    @State private var renamingPlan: ResistancePlan?
    @State private var renameText: String = ""
    @State private var archivingPlan: ResistancePlan?

    private var vineyard: Vineyard? {
        store.vineyards.first { $0.id == store.selectedVineyardId }
    }

    private var jurisdiction: ResistanceJurisdiction {
        ResistanceJurisdiction.fromCountryCode(vineyard?.country)
    }

    private var seasonCalendar: ResistanceSeasonCalendar {
        ResistanceSeasonCalendar(
            startMonth: store.settings.seasonStartMonth,
            startDay: store.settings.seasonStartDay,
            timeZoneIdentifier: store.settings.timezone.isEmpty
                ? TimeZone.current.identifier
                : store.settings.timezone
        )
    }

    private var currentSeasonStartYear: Int {
        seasonCalendar.season(epochMs: nowMs).startYear
    }

    /// The four completed seasons, the current one and the season ahead — the whole
    /// point of the tool is deciding a rotation before the season starts.
    private var selectableSeasonYears: [Int] {
        ((currentSeasonStartYear - 4)...(currentSeasonStartYear + 1)).reversed()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.selectedVineyardId == nil {
                    noVineyardCard
                } else {
                    filterBar

                    if planRepository.plans.isEmpty {
                        emptyStateCard
                    } else if filteredPlans.isEmpty {
                        noMatchesCard
                    } else {
                        ForEach(filteredPlans) { plan in
                            planRow(plan)
                        }
                    }

                    Text(planRepository.syncState.notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Resistance Planner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.selectedVineyardId != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewPlan = true
                    } label: {
                        Label("New Plan", systemImage: "plus")
                    }
                    .accessibilityLabel("New resistance plan")
                }
            }
        }
        .task { bootstrap() }
        .refreshable { await syncNow() }
        .navigationDestination(item: $openRoute) { route in
            // Opened by STABLE id. Never re-resolved by season/disease, so two plans
            // for the same season and disease can never swap under the editor.
            ResistancePlanEditorView(planId: route.id, planRepository: planRepository)
        }
        .sheet(isPresented: $showNewPlan) {
            NewResistancePlanSheet(
                seasonYears: Array(selectableSeasonYears),
                defaultYear: currentSeasonStartYear,
                onCreate: { year, disease, name in
                    createPlan(seasonStartYear: year, disease: disease, name: name)
                }
            )
        }
        .alert("Rename plan", isPresented: renameAlertBinding) {
            TextField("Plan name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingPlan = nil }
        } message: {
            Text("Shown in the plan list. Clear it to fall back to season and disease.")
        }
        .confirmationDialog(
            "Archive this plan?",
            isPresented: archiveDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Archive plan", role: .destructive) { commitArchive() }
            Button("Cancel", role: .cancel) { archivingPlan = nil }
        } message: {
            Text("Archives the plan for the whole vineyard. Spray jobs and records created from it are never touched.")
        }
    }

    // MARK: - Filters

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All seasons") { seasonFilter = nil }
                ForEach(seasonOptions, id: \.self) { seasonId in
                    Button(seasonId) { seasonFilter = seasonId }
                }
            } label: {
                filterChip(title: seasonFilter ?? "All seasons", isActive: seasonFilter != nil)
            }

            Menu {
                Button("All diseases") { diseaseFilter = nil }
                ForEach(ResistanceDisease.allCases, id: \.self) { option in
                    Button(option.label) { diseaseFilter = option }
                }
            } label: {
                filterChip(title: diseaseFilter?.label ?? "All diseases", isActive: diseaseFilter != nil)
            }

            Spacer()

            if seasonFilter != nil || diseaseFilter != nil {
                Button("Clear") {
                    seasonFilter = nil
                    diseaseFilter = nil
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    private func filterChip(title: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isActive ? VineyardTheme.leafGreen.opacity(0.18) : Color(.secondarySystemGroupedBackground),
            in: .capsule
        )
        .foregroundStyle(isActive ? VineyardTheme.leafGreen : Color.primary)
    }

    /// Seasons that actually have plans, newest first.
    private var seasonOptions: [String] {
        var seen: Set<String> = []
        return planRepository.plans
            .sorted { $0.seasonStartYear > $1.seasonStartYear }
            .compactMap { seen.insert($0.seasonId).inserted ? $0.seasonId : nil }
    }

    private var filteredPlans: [ResistancePlan] {
        planRepository.plans.filter { plan in
            (seasonFilter == nil || plan.seasonId == seasonFilter)
                && (diseaseFilter == nil || plan.disease == diseaseFilter)
        }
    }

    // MARK: - Rows

    private func planRow(_ plan: ResistancePlan) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Button {
                openRoute = ResistancePlanRoute(id: plan.id)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        rowTag(plan.seasonId)
                        rowTag(plan.disease.label)
                    }
                    Text(metaLine(plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if planRepository.conflict(id: plan.id) != nil {
                        Label("Changes need review", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else if planRepository.isPending(id: plan.id) {
                        Label("Waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Menu {
                rowActions(plan)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Plan actions")
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .contextMenu { rowActions(plan) }
    }

    @ViewBuilder
    private func rowActions(_ plan: ResistancePlan) -> some View {
        Button {
            openRoute = ResistancePlanRoute(id: plan.id)
        } label: {
            Label("Open", systemImage: "arrow.right.circle")
        }
        Button {
            renameText = plan.notes ?? ""
            renamingPlan = plan
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            duplicate(plan)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button(role: .destructive) {
            archivingPlan = plan
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
    }

    private func rowTag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(VineyardTheme.leafGreen.opacity(0.14), in: .capsule)
            .foregroundStyle(VineyardTheme.leafGreen)
    }

    private func metaLine(_ plan: ResistancePlan) -> String {
        let blocks = plan.blockIds.count
        let positions = plan.positions.count
        return "\(blocks) block\(blocks == 1 ? "" : "s") • "
            + "\(positions) position\(positions == 1 ? "" : "s") • "
            + "Updated \(listDate(plan.updatedAtEpochMs))"
    }

    private func listDate(_ epochMs: Int64) -> String {
        Date(timeIntervalSince1970: Double(epochMs) / 1000)
            .formatted(.dateTime.day().month(.abbreviated).year())
    }

    // MARK: - Empty states

    private var noVineyardCard: some View {
        Text("Select a vineyard to plan a resistance strategy.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No resistance plans yet", systemImage: "calendar.badge.plus")
                .font(.subheadline.weight(.semibold))
            Text("Plan a season-long FRAC rotation per disease. You can keep several plans for the same season and disease — nothing is ever selected for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showNewPlan = true
            } label: {
                Label("New Resistance Plan", systemImage: "plus.circle.fill")
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var noMatchesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No plans match the filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Clear filters") {
                seasonFilter = nil
                diseaseFilter = nil
            }
            .font(.footnote.weight(.semibold))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Actions

    /// Creates the plan immediately with a device-minted id, then opens it. Creating
    /// before first edit gives the plan its stable identity up front — the same id the
    /// server, other devices and (later) spray jobs will use.
    private func createPlan(seasonStartYear: Int, disease: ResistanceDisease, name: String) {
        guard let vineyardId = store.selectedVineyardId?.uuidString else { return }
        let now = nowMs
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var plan = ResistancePlan(
            vineyardId: vineyardId,
            seasonId: ResistanceSeasonCalendar.seasonId(startYear: seasonStartYear),
            seasonStartYear: seasonStartYear,
            disease: disease,
            jurisdiction: jurisdiction,
            notes: trimmed.isEmpty ? nil : trimmed,
            createdAtEpochMs: now,
            updatedAtEpochMs: now
        )
        if let ruleset = ResistanceRulesets.registry.current(
            jurisdiction: plan.jurisdiction,
            crop: plan.crop,
            disease: plan.disease
        ) {
            plan = plan.stampingRuleset(id: ruleset.id, version: ruleset.rulesetVersion)
        }
        planRepository.save(plan)
        openRoute = ResistancePlanRoute(id: plan.id)
    }

    /// New stable plan AND position ids — see `ResistancePlan.duplicated`. The copy
    /// stays in the list (not auto-opened) so both plans are visibly side by side.
    /// `createdBy` is left nil; the sql/196 attribution guard stamps the uploader.
    private func duplicate(_ plan: ResistancePlan) {
        planRepository.save(plan.duplicated(atEpochMs: nowMs, by: nil))
    }

    private func commitRename() {
        guard let plan = renamingPlan else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        planRepository.save(plan.settingNotes(trimmed.isEmpty ? nil : trimmed, atEpochMs: nowMs))
        renamingPlan = nil
    }

    /// Soft-delete via the existing tombstone contract (sql/196): the archive
    /// propagates to the server and other devices, and can be restored server-side.
    private func commitArchive() {
        guard let plan = archivingPlan else { return }
        planRepository.delete(id: plan.id)
        archivingPlan = nil
    }

    // MARK: - Plumbing

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingPlan != nil },
            set: { if !$0 { renamingPlan = nil } }
        )
    }

    private var archiveDialogBinding: Binding<Bool> {
        Binding(
            get: { archivingPlan != nil },
            set: { if !$0 { archivingPlan = nil } }
        )
    }

    private func bootstrap() {
        guard let vineyardId = store.selectedVineyardId?.uuidString else { return }
        // Cache first so the list paints immediately, then reconcile with the server.
        // A plan saved on another device appears once the pull lands; nothing on this
        // screen waits for the network to become interactive.
        planRepository.load(vineyardId: vineyardId)
        Task { await planRepository.sync(vineyardId: vineyardId) }
    }

    private func syncNow() async {
        guard let vineyardId = store.selectedVineyardId?.uuidString else { return }
        await planRepository.sync(vineyardId: vineyardId)
    }

    private static func makeRepository() -> ResistancePlanRepository {
        let provider = SupabaseClientProvider.shared
        return ResistancePlanRepository(
            local: ResistancePlanStore(),
            remote: provider.isConfigured ? SupabaseResistancePlanRepository(provider: provider) : nil
        )
    }
}

/// Navigation payload: the STABLE plan id, nothing else. Carrying the id (not the
/// plan value) means the pushed editor always renders the repository's live copy.
private struct ResistancePlanRoute: Identifiable, Hashable {
    let id: String
}

/// Season, disease and an optional name for a NEW plan.
///
/// Duplicates by season+disease are allowed on purpose — the list is the place that
/// tells them apart, and the optional name makes that easy.
private struct NewResistancePlanSheet: View {
    @Environment(\.dismiss) private var dismiss

    let seasonYears: [Int]
    let defaultYear: Int
    let onCreate: (Int, ResistanceDisease, String) -> Void

    @State private var seasonStartYear: Int = 0
    @State private var disease: ResistanceDisease = .powderyMildew
    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Season", selection: $seasonStartYear) {
                        ForEach(seasonYears, id: \.self) { year in
                            Text(ResistanceSeasonCalendar.seasonId(startYear: year)).tag(year)
                        }
                    }
                    Picker("Disease", selection: $disease) {
                        ForEach(ResistanceDisease.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    TextField("Plan name (optional)", text: $name)
                } footer: {
                    Text("You can keep several plans for the same season and disease — a name makes them easy to tell apart.")
                }
            }
            .navigationTitle("New Resistance Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(seasonStartYear, disease, name)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if seasonStartYear == 0 { seasonStartYear = defaultYear }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
