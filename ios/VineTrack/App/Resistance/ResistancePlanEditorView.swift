import SwiftUI

/// Editor for ONE Resistance Plan, opened from the plan list by stable
/// `resistance_plans.id`.
///
/// The season and disease are the plan's identity, fixed at creation and shown
/// read-only here — changing them can never silently switch which plan is being
/// edited. A different season or disease is a different plan, created from the list.
///
/// Every verdict on this screen comes from `ResistanceEngine` via `ResistancePlanner`.
/// The view formats and explains; it never counts.
struct ResistancePlanEditorView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BackendAccessControl.self) private var accessControl

    /// Stable plan identity. NEVER re-resolved by season/disease — a vineyard may hold
    /// several plans for the same season and disease, and this editor must only ever
    /// show the one that was tapped.
    let planId: String
    /// Shared with the plan list so edits, sync results and conflicts stay one source
    /// of truth while navigating back and forth.
    let planRepository: ResistancePlanRepository

    @State private var evaluation: ResistancePlanEvaluation?
    @State private var editingPositionId: String?
    @State private var expandedPositionIds: Set<String> = []
    @State private var showStrategy: Bool = false
    @State private var showUnresolvedDetail: Bool = false
    /// Spray jobs created from plan positions (sql/201 provenance).
    @State private var jobService = ResistancePlanJobService()
    @State private var jobDetail: BackendPlanSprayJob?
    @State private var recordingJob: BackendPlanSprayJob?

    /// Always read live from the repository so a sync pull or a rename from the list
    /// is reflected without a reload. Nil means the plan was archived or removed.
    private var plan: ResistancePlan? { planRepository.plan(id: planId) }

    private var vineyard: Vineyard? {
        store.vineyards.first { $0.id == store.selectedVineyardId }
    }

    private var disease: ResistanceDisease { plan?.disease ?? .powderyMildew }

    /// The plan's stamped jurisdiction — the one its ruleset was chosen under.
    private var jurisdiction: ResistanceJurisdiction { plan?.jurisdiction ?? .unknown }

    private var seasonCalendar: ResistanceSeasonCalendar {
        ResistanceSeasonCalendar(
            startMonth: store.settings.seasonStartMonth,
            startDay: store.settings.seasonStartDay,
            timeZoneIdentifier: store.settings.timezone.isEmpty
                ? TimeZone.current.identifier
                : store.settings.timezone
        )
    }

    private var season: ResistanceSeason {
        seasonCalendar.seasonStarting(
            plan?.seasonStartYear ?? seasonCalendar.season(epochMs: nowMs).startYear
        )
    }

    private var blocks: [Paddock] {
        store.paddocks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if plan != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        planHeaderSection

                        if jurisdiction == .unknown || evaluation?.isSupported == false {
                            unsupportedCard
                        } else {
                            blockSelectionSection
                            if let plan, !plan.blockIds.isEmpty {
                                historyStatusSection
                                timelineSection
                                plannedPositionsSection
                                seasonTotalsSection
                                strategySection
                            } else {
                                chooseBlocksPrompt
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
            } else {
                // Archived or removed — possibly on another device, pulled mid-session.
                // Never silently substitute a different plan.
                ContentUnavailableView(
                    "Plan no longer available",
                    systemImage: "archivebox",
                    description: Text("This plan was archived or removed. Go back to the plan list to pick or create another.")
                )
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(plan?.displayTitle ?? "Resistance Plan")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            recompute()
            refreshPlanJobs()
        }
        .onChange(of: plan) { _, _ in recompute() }
        .sheet(item: $editingPositionId) { positionId in
            if let plan, let position = plan.position(id: positionId) {
                ResistancePlanPositionEditorSheet(
                    position: position,
                    positionIndex: plan.positions.firstIndex(where: { $0.id == positionId }) ?? 0,
                    plannerRequest: plannerRequest(for: plan),
                    chemicalCandidates: chemicalCandidates,
                    jurisdiction: jurisdiction,
                    onSave: { updated in
                        apply { $0.replacingPosition(updated, atEpochMs: nowMs) }
                    }
                )
            }
        }
        .sheet(item: $jobDetail) { job in
            PlanSprayJobDetailSheet(
                job: job,
                planLabel: plan?.displayTitle ?? "\(disease.label) — \(season.id)",
                positionOrdinal: evaluation?.positions.first { $0.positionId == job.resistancePositionId }?.displayOrdinal,
                liveEvaluation: evaluation?.positions.first { $0.positionId == job.resistancePositionId },
                blockName: { blockName($0) },
                canRecordSpray: accessControl.canCreateOperationalRecords,
                isPendingSync: jobService.isPendingSync(job.id),
                onRecordSpray: {
                    jobDetail = nil
                    recordingJob = job
                }
            )
        }
        .sheet(item: $recordingJob) { job in
            NavigationStack {
                SprayCalculatorView(
                    prefillRecord: job.toPrefillRecord(),
                    originSprayJobId: job.id,
                    prefillPaddockIds: plan?.blockIds.compactMap(UUID.init(uuidString:)) ?? []
                )
            }
        }
    }

    // MARK: - Plan identity header

    /// Season and disease, read-only. These identify the plan (together with its name)
    /// and are fixed at creation — the pickers that used to live here silently switched
    /// to a DIFFERENT plan, which is exactly what the plan list exists to prevent.
    private var planHeaderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Season", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                // Stated as a span, never a bare calendar year: an Australian season
                // starts in one year and finishes in the next.
                Text(plan?.seasonId ?? season.id)
                    .font(.subheadline.weight(.medium))
            }

            Divider()

            HStack {
                Label("Disease", systemImage: "allergens")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(disease.label)
                    .font(.subheadline.weight(.medium))
            }

            Text("One disease is planned at a time. A spray recorded against both diseases still counts in both histories.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Season and disease identify this plan. For a different season or disease, create another plan from the list.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var unsupportedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Strategy not available", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(ResistancePlanner.unsupportedJurisdictionMessage)
                .font(.subheadline)
            // Stated explicitly so nobody assumes the Australian rules are a sensible
            // default. They are a jurisdiction-specific published strategy, and
            // applying them to another country's label conditions would be wrong.
            Text("VineTrack applies a published strategy only where one has been configured for the vineyard's country. No resistance limits are being evaluated.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var chooseBlocksPrompt: some View {
        Text("Select at least one block to see its recorded history and plan a sequence.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Blocks

    private var blockSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Blocks")
                .font(.subheadline.weight(.semibold))
            Text("Each block is assessed against its own history. Selecting several never merges them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if blocks.isEmpty {
                Text("This vineyard has no blocks yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(blocks) { block in
                        blockChip(block)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func blockChip(_ block: Paddock) -> some View {
        let id = block.id.uuidString
        let isSelected = plan?.blockIds.contains(id) ?? false
        return Button {
            toggleBlock(id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                Text(block.name)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.footnote.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 8)
            .background(
                isSelected ? VineyardTheme.leafGreen.opacity(0.18) : Color(.tertiarySystemFill),
                in: .rect(cornerRadius: 10)
            )
            .foregroundStyle(isSelected ? VineyardTheme.leafGreen : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - History status

    private var historyStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History check")
                .font(.subheadline.weight(.semibold))
            // Deliberately ABOVE the plan. A grower who scrolls to a green sequence
            // first has already been reassured before learning the history behind it
            // is incomplete.
            Text("Checked before any recommendation, so a plan never looks settled on top of history that isn't.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let evaluation {
                ForEach(evaluation.historyChecks, id: \.blockId) { check in
                    historyCheckRow(check)
                }

                if evaluation.unresolvedApplicationCount > 0 {
                    unresolvedSummary(count: evaluation.unresolvedApplicationCount)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func historyCheckRow(_ check: ResistanceBlockHistoryCheck) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(blockName(check.blockId))
                .font(.footnote.weight(.semibold))
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: check.isCompleteEnoughToAssess
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(check.isCompleteEnoughToAssess ? VineyardTheme.leafGreen : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.headline(disease: disease))
                        .font(.footnote)
                    ForEach(detailLines(check), id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
    }

    private func detailLines(_ check: ResistanceBlockHistoryCheck) -> [String] {
        var lines: [String] = []
        if check.relevantApplicationCount > 0 {
            lines.append("\(check.relevantApplicationCount) relevant application\(check.relevantApplicationCount == 1 ? "" : "s") this season")
        }
        if check.unresolvedVineyardApplicationCount > 0 {
            lines.append("\(check.unresolvedVineyardApplicationCount) older spray record\(check.unresolvedVineyardApplicationCount == 1 ? "" : "s") cannot be assigned to a block")
        }
        if check.unknownTargetCount > 0 {
            lines.append("\(check.unknownTargetCount) spray\(check.unknownTargetCount == 1 ? "" : "s") with no recorded disease target")
        }
        if check.conflictingCount > 0 {
            lines.append("\(check.conflictingCount) application\(check.conflictingCount == 1 ? "" : "s") with conflicting chemistry")
        }
        if check.unavailableCount > 0 {
            lines.append("\(check.unavailableCount) application\(check.unavailableCount == 1 ? "" : "s") with no usable chemistry")
        }
        if check.unverifiedCount > 0 {
            lines.append("\(check.unverifiedCount) application\(check.unverifiedCount == 1 ? "" : "s") with unverified chemistry")
        }
        return lines
    }

    private func unresolvedSummary(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Resistance history incomplete", systemImage: "questionmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            Text("\(count) older spray\(count == 1 ? "" : "s") in this vineyard cannot be assigned to individual blocks, so VineTrack cannot confirm that every strategy limit is still available for these blocks.")
                .font(.caption)
            Button(showUnresolvedDetail ? "Hide details" : "Show details") {
                withAnimation(.easeInOut(duration: 0.2)) { showUnresolvedDetail.toggle() }
            }
            .font(.caption.weight(.semibold))
            if showUnresolvedDetail {
                // Counts by default, records only on request: a vineyard with years of
                // legacy history would otherwise bury the plan under a list nobody
                // asked for.
                Text("These applications happened somewhere in this vineyard. Because the treated blocks were never recorded, they are not assigned to any block — and not assumed to be absent from one either.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Season history")
                .font(.subheadline.weight(.semibold))
            if let evaluation {
                ForEach(evaluation.timelines, id: \.blockId) { timeline in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(blockName(timeline.blockId))
                                .font(.footnote.weight(.semibold))
                            Spacer()
                            Text("\(timeline.entries.count) relevant application\(timeline.entries.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if timeline.entries.isEmpty {
                            Text("No recorded \(disease.label) sprays this season")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(timeline.entries.enumerated()), id: \.element.id) { index, entry in
                                timelineRow(index: index, entry: entry)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func timelineRow(index: Int, entry: ResistancePlanTimelineEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(shortDate(entry.appliedAtEpochMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // FRAC identity leads; the brand is supporting detail. Rotation is
                    // a property of the chemistry group, not of the label on the drum.
                    Text(entry.groupsLabel)
                        .font(.footnote.weight(.semibold))
                    verificationBadge(entry.availability)
                }
                if !entry.productNames.isEmpty {
                    Text(entry.productNames.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            // Completed work is labelled as such so it can never be mistaken for a
            // planning slot.
            Text("Completed")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(VineyardTheme.leafGreen.opacity(0.16), in: .capsule)
                .foregroundStyle(VineyardTheme.leafGreen)
        }
    }

    @ViewBuilder
    private func verificationBadge(_ availability: ChemicalIntelligenceAvailability) -> some View {
        switch availability {
        case .availableVerified:
            Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(VineyardTheme.leafGreen)
        case .availablePartiallyVerified:
            Image(systemName: "circle.lefthalf.filled").font(.caption2).foregroundStyle(.orange)
        case .availableUnverified:
            Image(systemName: "questionmark.circle").font(.caption2).foregroundStyle(.orange)
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
        case .unavailable:
            Image(systemName: "slash.circle").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Planned positions

    private var plannedPositionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Planned sequence")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    apply { $0.addingPosition(atEpochMs: nowMs) }
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.footnote.weight(.semibold))
                }
            }

            Text("Planning positions only — nothing here is a spray record. Create Spray Job hands a position to operations; progress is derived and job activity never edits this plan.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let evaluation, !evaluation.positions.isEmpty {
                ForEach(evaluation.positions, id: \.positionId) { positionEval in
                    positionCard(positionEval)
                }
            } else {
                Text("No planned positions yet. Add one to start building the sequence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Where this plan actually lives is stated where plans are edited, so neither
            // the sharing nor the offline queue is a surprise discovered by losing work.
            Text(planRepository.syncState.notice)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func positionCard(_ positionEval: ResistancePlanPositionEvaluation) -> some View {
        let position = plan?.position(id: positionEval.positionId)
        let isExpanded = expandedPositionIds.contains(positionEval.positionId)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spray \(positionEval.displayOrdinal)")
                        .font(.footnote.weight(.bold))
                    Text(position?.groupsLabel ?? "No chemistry selected")
                        .font(.subheadline.weight(.semibold))
                    if let timing = timingLabel(position) {
                        Text(timing)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusBadge(positionEval.status)
            }

            if positionEval.awaitingChemistry {
                Text("Choose a FRAC group to evaluate this position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let position, !position.productsRequiringCaveat.isEmpty {
                ForEach(position.productsRequiringCaveat) { product in
                    Label(
                        "\(product.displayLabel): recorded as \(product.groups.displayLabel) — \(product.effectiveAvailability.label.lowercased())",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            if positionEval.blocksDisagree {
                // The blocks differ, so the summary badge alone would hide a real
                // difference. Per-block rows are always shown in that case.
                ForEach(positionEval.blocks, id: \.blockId) { outcome in
                    HStack {
                        Text(blockName(outcome.blockId))
                            .font(.caption)
                        Spacer()
                        Text(outcome.status.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor(outcome.status))
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Edit chemistry") { editingPositionId = positionEval.positionId }
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    apply { $0.movingPositionUp(id: positionEval.positionId, atEpochMs: nowMs) }
                } label: { Image(systemName: "arrow.up") }
                    .disabled(positionEval.index == 0)
                Button {
                    apply { $0.movingPositionDown(id: positionEval.positionId, atEpochMs: nowMs) }
                } label: { Image(systemName: "arrow.down") }
                    .disabled(positionEval.index >= (plan?.positions.count ?? 1) - 1)
                Button(role: .destructive) {
                    apply { $0.removingPosition(id: positionEval.positionId, atEpochMs: nowMs) }
                } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)
            .font(.footnote)

            if !positionEval.findings.isEmpty {
                Button(isExpanded ? "Hide reasons" : "Why?") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedPositionIds.remove(positionEval.positionId)
                        } else {
                            expandedPositionIds.insert(positionEval.positionId)
                        }
                    }
                }
                .font(.caption.weight(.semibold))

                if isExpanded {
                    ForEach(positionEval.blocks, id: \.blockId) { outcome in
                        ForEach(outcome.evaluation.findings) { finding in
                            findingRow(finding, blockName: blockName(outcome.blockId))
                        }
                    }
                }
            }

            planJobsSection(positionEval, position: position)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // Planned positions are visually distinct from the completed timeline: dashed
        // border, no "Completed" chip.
        .background(Color(.tertiarySystemFill).opacity(0.6), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(statusColor(positionEval.status).opacity(0.5))
        )
    }

    // MARK: - Plan -> Spray Jobs (sql/201)

    /// `spray_jobs` INSERT is owner/manager-gated by RLS, so the button is too.
    private var canCreateSprayJobs: Bool {
        accessControl.currentRole == .owner || accessControl.currentRole == .manager
    }

    @ViewBuilder
    private func planJobsSection(
        _ positionEval: ResistancePlanPositionEvaluation,
        position: ResistancePlannedPosition?
    ) -> some View {
        let jobs = plan.map { jobService.jobs(planId: $0.id, positionId: positionEval.positionId) } ?? []
        if !jobs.isEmpty || (canCreateSprayJobs && position != nil) {
            Divider()
            HStack {
                Label("Spray Jobs", systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if canCreateSprayJobs, let position {
                    Button {
                        createSprayJob(for: positionEval, position: position)
                    } label: {
                        Label("Create Spray Job", systemImage: "plus.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }
            }
            ForEach(jobs) { job in
                planJobRow(job)
            }
            if jobs.isEmpty {
                Text("No spray jobs yet. Creating one freezes this position's current intent into the job — later plan edits never rewrite it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func planJobRow(_ job: BackendPlanSprayJob) -> some View {
        Button {
            jobDetail = job
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name.isEmpty ? "Spray job" : job.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text((job.status ?? "planned").capitalized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if jobService.isPendingSync(job.id) {
                            Label("Waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if job.deviatesFromPlan {
                            Label("Differs from plan", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Color(.systemBackground).opacity(0.6), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Creates the job with the position frozen VERBATIM as its snapshot.
    /// Prefills only what the plan genuinely knows: blocks, disease target and
    /// planned chemistry identity — never carrier volumes or rates.
    private func createSprayJob(
        for positionEval: ResistancePlanPositionEvaluation,
        position: ResistancePlannedPosition
    ) {
        guard let plan, let vineyardId = store.selectedVineyardId else { return }
        let name = "\(disease.label) \(season.id) — Spray \(positionEval.displayOrdinal)"
        jobService.createJob(
            name: name,
            vineyardId: vineyardId,
            plan: plan,
            position: position,
            target: disease.label,
            paddockIds: plan.blockIds.compactMap(UUID.init(uuidString:)),
            createdBy: auth.userId
        )
    }

    private func refreshPlanJobs() {
        guard let plan, let vineyardId = store.selectedVineyardId else { return }
        jobService.load(planId: plan.id)
        Task { await jobService.refresh(planId: plan.id, vineyardId: vineyardId) }
    }

    private func timingLabel(_ position: ResistancePlannedPosition?) -> String? {
        guard let position else { return nil }
        var parts: [String] = []
        if let date = position.targetDateEpochMs { parts.append("Target \(shortDate(date))") }
        if let stage = position.growthStage, !stage.isEmpty { parts.append(stage) }
        if parts.isEmpty { return nil }
        return parts.joined(separator: " • ")
    }

    private func findingRow(_ finding: ResistanceRuleResult, blockName: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(blockName) — \(finding.thresholdDescription.capitalizedFirst)")
                .font(.caption.weight(.semibold))
            Text(finding.explanation)
                .font(.caption)
            // Observed vs threshold vs source, so the operator can check the claim
            // rather than take it on faith.
            Text("Observed: \(finding.observedDescription). Strategy: \(finding.thresholdDescription).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !finding.contributingDatesEpochMs.isEmpty {
                Text("Contributing: \(finding.contributingDatesEpochMs.map(shortDate).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let mixture = finding.mixtureRequirement, mixture == .unknown {
                Label("Mixture requirement cannot be fully confirmed", systemImage: "questionmark.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text("\(finding.sourceReference) • \(finding.rulesetId) \(finding.rulesetVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.systemBackground).opacity(0.6), in: .rect(cornerRadius: 8))
    }

    private func statusBadge(_ status: ResistancePlanPositionStatus) -> some View {
        Text(status.label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor(status).opacity(0.16), in: .capsule)
            .foregroundStyle(statusColor(status))
    }

    private func statusColor(_ status: ResistancePlanPositionStatus) -> Color {
        switch status {
        case .goodFit: return VineyardTheme.leafGreen
        case .reachesStrategyLimit: return .orange
        case .wouldExceedStrategy: return .red
        case .needsReview: return .orange
        case .unableToFullyAssess: return .purple
        }
    }

    // MARK: - Season totals

    private var seasonTotalsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Season totals")
                .font(.subheadline.weight(.semibold))
            Text("Counted from resistance applications, not tank lines — a three-product tank is one application.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let evaluation {
                ForEach(evaluation.seasonTotals, id: \.blockId) { totals in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(blockName(totals.blockId))
                            .font(.footnote.weight(.semibold))
                        Text("\(disease.label) sprays this season: \(totals.diseaseSprayCount)")
                            .font(.caption)
                        ForEach(totals.orderedGroups, id: \.self) { group in
                            Text("FRAC \(group) applications: \(totals.applicationsByGroup[group] ?? 0)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Strategy reference

    private var strategySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showStrategy.toggle() }
            } label: {
                HStack {
                    Label("Strategy", systemImage: "book.closed")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showStrategy ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)

            if showStrategy, let evaluation {
                VStack(alignment: .leading, spacing: 3) {
                    if let organisation = evaluation.sourceOrganisation {
                        Text(organisation).font(.footnote.weight(.semibold))
                    }
                    if let name = evaluation.strategyName {
                        Text(name).font(.caption)
                    }
                    if let validFrom = evaluation.rulesetValidFrom {
                        Text("Valid \(validFrom)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let version = evaluation.rulesetVersion {
                        Text("Ruleset: \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let plan, plan.isStrategyOutdated(against: ResistanceRulesets.registry) {
                        Label(
                            "A newer resistance strategy is available — review this plan.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                    }
                    Text("The Planner supports resistance management. It does not replace the product label or agronomic judgement.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Plumbing

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private var chemicalCandidates: [ResistancePlanChemicalCandidate] {
        ResistancePlanChemicalSource.candidates(
            from: store.savedChemicals,
            disease: disease,
            vineyardCountry: vineyard?.country
        )
    }

    private func blockName(_ blockId: String) -> String {
        // Current live name, falling back to a stable stand-in for a block that has
        // since been removed. Matches the spray-export display rule.
        blocks.first { $0.id.uuidString.caseInsensitiveCompare(blockId) == .orderedSame }?.name
            ?? "Unknown block"
    }

    private func shortDate(_ epochMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(epochMs) / 1000)
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func toggleBlock(_ blockId: String) {
        apply { current in
            var ids = current.blockIds
            if let index = ids.firstIndex(of: blockId) { ids.remove(at: index) } else { ids.append(blockId) }
            return current.settingBlockIds(ids, atEpochMs: nowMs)
        }
    }

    /// Applies an edit, persists it, and re-runs the engine.
    ///
    /// Every mutation goes through here so re-evaluation can never be forgotten — the
    /// rules are sequence-dependent, so a change to position 4 can alter positions 5
    /// and 6, and a stale later warning would be worse than none.
    private func apply(_ transform: (ResistancePlan) -> ResistancePlan) {
        guard let current = plan else { return }
        var updated = transform(current)
        if let ruleset = ResistanceRulesets.registry.current(
            jurisdiction: updated.jurisdiction,
            crop: updated.crop,
            disease: updated.disease
        ) {
            updated = updated.stampingRuleset(id: ruleset.id, version: ruleset.rulesetVersion)
        }
        // Local commit + outbox. Returns immediately, works offline, and never blocks the
        // edit the grower just made on a network round trip.
        planRepository.save(updated)
        recompute()
    }

    private func recompute() {
        guard let plan else { evaluation = nil; return }
        evaluation = ResistancePlanner.evaluate(plannerRequest(for: plan))
    }

    private func plannerRequest(for plan: ResistancePlan) -> ResistancePlanner.Request {
        let inputs = store.sprayRecords.map { ResistanceEventSource.input(from: $0) }
        let result = ResistanceEventSource.events(from: inputs, seasonCalendar: seasonCalendar)
        return ResistancePlanner.Request(
            plan: plan,
            season: season,
            seasonCalendar: seasonCalendar,
            events: result.events,
            unresolvedApplications: result.unresolvedBlockApplications,
            registry: ResistanceRulesets.registry
        )
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// Lets an optional `String` id drive a sheet.
private extension View {
    func sheet<Content: View>(
        item: Binding<String?>,
        @ViewBuilder content: @escaping (String) -> Content
    ) -> some View {
        sheet(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}
