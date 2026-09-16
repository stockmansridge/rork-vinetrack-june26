import SwiftUI

/// Vineyard Insights — System Admin preview (SQL 236, Round 1).
///
/// Hosts Scout, Vintage Notes and the prepared Vintage Report workspace behind
/// a single continuously re-checked access gate.
struct VineyardInsightsView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(SystemAdminService.self) private var systemAdmin
    @Environment(VineyardInsightsService.self) private var insights

    /// Access is resolved on EVERY evaluation, not once on entry. A restored
    /// navigation state, a deep link, a sign-out, or a System Admin row revoked
    /// while the screen is open must close the preview — an entry-time check
    /// would leave it visible until the user happened to navigate away.
    private var access: VineyardInsightsAccess {
        VineyardInsightsAccess.resolve(
            isAuthenticated: auth.isSignedIn,
            isResolving: systemAdmin.isLoading || systemAdmin.lastLoadedAt == nil,
            isSystemAdmin: systemAdmin.isSystemAdmin,
            selectedVineyardID: store.selectedVineyardId,
            isMemberOfSelectedVineyard: accessControl.currentRole != nil
        )
    }

    var body: some View {
        Group {
            if access.isAllowed {
                hub
            } else {
                unavailable
            }
        }
        .navigationTitle(VineyardInsightsCatalog.toolTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Shown when access is refused while the screen is somehow open.
    ///
    /// Deliberately says nothing about System Admin or about a preview
    /// existing — an explanation would disclose the feature to exactly the
    /// person who may not have it. A still-resolving session reads as "not
    /// yet", never as "denied", so a launch race is not a permissions error.
    private var unavailable: some View {
        let isResolving: Bool = {
            if case .unavailable(.stillResolving) = access { return true }
            return false
        }()
        return ContentUnavailableView(
            isResolving ? "Loading…" : "This tool is not available.",
            systemImage: "lock"
        )
    }

    private var hub: some View {
        List {
            Section {
                PreviewBadge()
                    .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink {
                    ScoutWorkspaceView()
                } label: {
                    HubCard(
                        title: "Scout",
                        subtitle: "Block assessments, observations & photos",
                        icon: "figure.walk",
                        tint: VineyardTheme.leafGreen,
                        actions: ["New Scout", "Draft Scouts", "Completed Scouts"]
                    )
                }
                NavigationLink {
                    VintageNotesWorkspaceView()
                } label: {
                    HubCard(
                        title: "Vintage Notes",
                        subtitle: "Record important events during the vintage",
                        icon: "note.text",
                        tint: .orange,
                        actions: ["Add Vintage Note", "View notes for selected Vintage"]
                    )
                }
                NavigationLink {
                    VintageReportWorkspaceView()
                } label: {
                    HubCard(
                        title: "Vintage Report",
                        subtitle: "Build the plain-English story of the vintage",
                        icon: "doc.text",
                        tint: .indigo,
                        actions: ["Open report workspace"]
                    )
                }
            }
        }
    }
}

// MARK: - Shared pieces

struct PreviewBadge: View {
    var body: some View {
        Label(VineyardInsightsCatalog.previewBadge, systemImage: "lock.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.purple.opacity(0.14), in: .capsule)
            .accessibilityLabel("System Admin preview")
    }
}

private struct HubCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let actions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.16), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(actions, id: \.self) { action in
                Text("•  \(action)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Scout

struct ScoutWorkspaceView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(VineyardInsightsService.self) private var insights

    @State private var showReview = false

    private var openVisit: ScoutVisit? { insights.openVisit }

    var body: some View {
        List {
            if insights.lastWriteFailed {
                Section {
                    // An observation that silently failed to save is the worst
                    // outcome this feature can produce, so the failure is shown
                    // rather than swallowed.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This device could not save your latest change.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                        Text("Earlier work is still saved. Try the change again before leaving this Scout.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let visit = openVisit {
                visitSections(visit)
            } else {
                listSections
            }
        }
        .navigationTitle("Scout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if openVisit != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { insights.openVisit(nil) }
                }
            }
        }
        .sheet(isPresented: $showReview) {
            if let visit = openVisit {
                ScoutReviewSheet(
                    review: ScoutReview.of(visit),
                    isEditable: visit.isEditable
                ) {
                    insights.completeVisit(visit.id)
                    showReview = false
                }
            }
        }
    }

    @ViewBuilder
    private var listSections: some View {
        Section {
            Button {
                guard let vineyardID = store.selectedVineyardId else { return }
                insights.startVisit(
                    vineyardID: vineyardID,
                    scoutUserID: auth.userId,
                    scoutName: auth.userName,
                    seasonStartMonth: store.settings.seasonStartMonth,
                    seasonStartDay: store.settings.seasonStartDay
                )
            } label: {
                Label("New Scout", systemImage: "plus.circle.fill")
            }
        } footer: {
            Text(
                "Everything is saved on this device first, so a Scout started out "
                + "of signal is never lost."
            )
        }

        scoutListSection("Draft Scouts", visits: insights.visits(status: .draft))
        scoutListSection("Completed Scouts", visits: insights.visits(status: .completed))
    }

    private func scoutListSection(_ title: String, visits: [ScoutVisit]) -> some View {
        Section(title) {
            if visits.isEmpty {
                Text("None yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(visits) { visit in
                Button {
                    insights.openVisit(visit.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(visit.scoutDate, format: .dateTime.day().month().year())
                                .foregroundStyle(.primary)
                            Text(blockNames(visit))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Vintage \(String(visit.vintageYear))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func blockNames(_ visit: ScoutVisit) -> String {
        let names = visit.assessments.compactMap { assessment in
            store.paddocks.first { $0.id == assessment.paddockID }?.name
        }
        return names.isEmpty ? "No blocks yet" : names.joined(separator: ", ")
    }

    @ViewBuilder
    private func visitSections(_ visit: ScoutVisit) -> some View {
        Section("Scout visit") {
            LabeledContent("Date") {
                Text(visit.scoutDate, format: .dateTime.day().month().year())
            }
            LabeledContent("Vintage", value: String(visit.vintageYear))
            LabeledContent("Scout", value: visit.scoutNameSnapshot ?? auth.userName ?? "—")
            LabeledContent("Status", value: visit.status.label)
            // Weather never blocks saving and is never invented: when no
            // reading is held the record says so rather than leaving a
            // confident blank.
            Text(weatherLine(visit)).font(.caption).foregroundStyle(.secondary)
            TextField(
                "Visit summary (optional)",
                text: Binding(
                    get: { visit.visitSummary ?? "" },
                    set: { insights.setSummary(visitID: visit.id, summary: $0) }
                ),
                axis: .vertical
            )
            .lineLimit(2...5)
            .disabled(!visit.isEditable)
        }

        Section("Blocks") {
            if store.paddocks.isEmpty {
                Text("No blocks in this vineyard.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.paddocks) { paddock in
                let selected = visit.assessment(paddockID: paddock.id) != nil
                Button {
                    insights.toggleBlock(visitID: visit.id, paddockID: paddock.id)
                } label: {
                    HStack {
                        Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(selected ? VineyardTheme.leafGreen : .secondary)
                        Text(paddock.name).foregroundStyle(.primary)
                    }
                }
                .disabled(!visit.isEditable)
            }
        }

        ForEach(visit.assessments) { assessment in
            ScoutAssessmentSection(
                visitID: visit.id,
                assessment: assessment,
                paddock: store.paddocks.first { $0.id == assessment.paddockID },
                vintageYear: visit.vintageYear,
                isEditable: visit.isEditable
            )
        }

        Section {
            Button(visit.isEditable ? "Review & complete" : "Review") { showReview = true }
            if !visit.isEditable {
                Button("Return to Draft") { insights.reopenVisit(visit.id) }
            }
        }
    }

    private func weatherLine(_ visit: ScoutVisit) -> String {
        guard let weather = visit.weather else { return "Weather  not captured" }
        if weather.isUnavailable { return "Weather  unavailable at capture time" }
        if weather.isStale { return "Weather  last reading may be out of date" }
        var parts: [String] = []
        if let temperature = weather.temperatureCelsius {
            parts.append("\(Int(temperature.rounded()))°C")
        }
        if let humidity = weather.humidityPercent {
            parts.append("\(Int(humidity.rounded()))% RH")
        }
        if let wind = weather.windSpeedKph {
            parts.append("wind \(Int(wind.rounded())) km/h")
        }
        return parts.isEmpty ? "Weather  not captured" : "Weather  " + parts.joined(separator: "  ")
    }
}

private struct ScoutAssessmentSection: View {
    @Environment(VineyardInsightsService.self) private var insights

    let visitID: UUID
    let assessment: ScoutBlockAssessment
    let paddock: Paddock?
    let vintageYear: Int
    let isEditable: Bool

    var body: some View {
        Section {
            ForEach(ScoutItem.allCases) { item in
                itemView(item)
            }
        } header: {
            Text(paddock?.name ?? "Block")
        } footer: {
            // Existing block information is DISPLAYED, never re-asked. A scout
            // who already knows the block should not be retyping its details.
            Text(detailLine)
        }
    }

    private var detailLine: String {
        var parts: [String] = []
        let varieties = (paddock?.varietyAllocations ?? [])
            .compactMap { $0.name?.isEmpty == false ? $0.name : nil }
        if !varieties.isEmpty { parts.append(varieties.joined(separator: ", ")) }
        if let rows = paddock?.rows.count, rows > 0 { parts.append("\(rows) rows") }
        parts.append("Vintage \(String(vintageYear))")
        return parts.joined(separator: "  •  ")
    }

    @ViewBuilder
    private func itemView(_ item: ScoutItem) -> some View {
        let observation = assessment.observation(item)

        VStack(alignment: .leading, spacing: 8) {
            Text(item.label).font(.subheadline.weight(.semibold))

            if item == .growthStage {
                Text(observation?.valueLabel ?? "Not recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "Recording an E-L stage here creates the same Growth Stage pin "
                    + "and record as the normal workflow — never a second value."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if item.isFreeText {
                notesField(item, observation)
            } else {
                Picker(
                    item.label,
                    selection: Binding(
                        get: { observation?.valueCode ?? VineyardInsightsCatalog.notAssessedCode },
                        set: { code in
                            guard let option = VineyardInsightsCatalog.option(for: item, code: code) else { return }
                            insights.setObservationValue(
                                visitID: visitID,
                                assessmentID: assessment.id,
                                item: item,
                                option: option
                            )
                        }
                    )
                ) {
                    ForEach(VineyardInsightsCatalog.options(for: item)) { option in
                        Text(option.label).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(!isEditable)

                notesField(item, observation)
            }

            photoRow(item, observation)
        }
        .padding(.vertical, 4)
    }

    private func notesField(_ item: ScoutItem, _ observation: ScoutObservation?) -> some View {
        TextField(
            "Notes (optional)",
            text: Binding(
                get: { observation?.notes ?? "" },
                set: {
                    insights.setObservationNotes(
                        visitID: visitID,
                        assessmentID: assessment.id,
                        item: item,
                        notes: $0
                    )
                }
            ),
            axis: .vertical
        )
        .lineLimit(1...4)
        .disabled(!isEditable)
    }

    @ViewBuilder
    private func photoRow(_ item: ScoutItem, _ observation: ScoutObservation?) -> some View {
        let photos = observation?.photos ?? []
        let blockOnly = photos.filter { $0.locationStatus == .unavailable }.count

        VStack(alignment: .leading, spacing: 4) {
            if !photos.isEmpty {
                Text("\(photos.count) photo\(photos.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if blockOnly > 0 {
                // Stated plainly rather than hidden: a photo without a
                // qualifying fix is block-associated, and presenting it as
                // positioned would be a false claim about evidence.
                Text("\(blockOnly) \(PhotoLocationStatus.unavailable.label)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct ScoutReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let review: ScoutReview
    let isEditable: Bool
    let onComplete: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Blocks assessed", value: String(review.blocksAssessed))
                    LabeledContent("Blocks still incomplete", value: String(review.blocksIncomplete))
                    LabeledContent("E-L observations created", value: String(review.growthStageObservations))
                    LabeledContent("Items needing attention", value: String(review.attentionItems))
                    LabeledContent("Photographs", value: String(review.photoCount))
                    LabeledContent("Other issues", value: String(review.otherIssues))
                    LabeledContent("General recommendations", value: String(review.generalRecommendations))
                } footer: {
                    Text(review.blockedReason() ?? ScoutReview.completionHint)
                }

                Section {
                    Button("Complete Scout", action: onComplete)
                        .disabled(!isEditable || !review.canComplete)
                }
            }
            .navigationTitle("Review Scout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Keep editing") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Vintage Notes

struct VintageNotesWorkspaceView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(VineyardInsightsService.self) private var insights

    @State private var draft = VintageNoteDraft()
    @State private var isEditing = false
    @State private var showTypePicker = false

    private var vintage: Int {
        draft.resolvedVintage(
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
    }

    private var customTypes: [VintageNoteType] {
        guard let vineyardID = store.selectedVineyardId else { return [] }
        return insights.customNoteTypes(vineyardID: vineyardID)
    }

    var body: some View {
        List {
            Section {
                DatePicker("Date", selection: $draft.date, displayedComponents: .date)

                // The Vintage moves with the date so the observer can see which
                // season they are filing against before they save.
                LabeledContent("Vintage", value: String(vintage))

                Button {
                    showTypePicker = true
                } label: {
                    LabeledContent("Note type") {
                        Text(draft.noteTypeLabel ?? "Optional")
                            .foregroundStyle(draft.noteTypeLabel == nil ? .secondary : .primary)
                    }
                }

                TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...8)

                LabeledContent("Observation made by", value: auth.userName ?? "—")
            } header: {
                Text(isEditing ? "Edit Vintage Note" : "Add Vintage Note")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(VintageNoteRules.vintageServerNote)
                    if let reason = draft.blockedReason {
                        Text(reason).foregroundStyle(.red)
                    }
                }
            }

            Section {
                Button("Save note") { save() }
                    .disabled(!draft.canSave)
                if isEditing {
                    Button("Cancel", role: .cancel) {
                        draft = VintageNoteDraft()
                        isEditing = false
                    }
                }
            }

            Section("Notes for Vintage \(String(vintage))") {
                let notes = insights.notes(vintageYear: vintage)
                if notes.isEmpty {
                    Text("No notes for this Vintage yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(note.displayType()).font(.subheadline.weight(.semibold))
                            Spacer()
                            if note.isEdited {
                                Text("Edited").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(note.noteDate, format: .dateTime.day().month().year())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !note.preview().isEmpty {
                            Text(note.preview()).font(.callout)
                        }
                        Text(note.observerNameSnapshot ?? "—")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { insights.deleteNote(note.id) }
                        Button("Edit") { beginEdit(note) }
                    }
                }
            }
        }
        .navigationTitle("Vintage Notes")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTypePicker) {
            VintageNoteTypePicker(customTypes: customTypes) { type in
                draft.noteTypeID = type.code
                draft.noteTypeLabel = type.label
                showTypePicker = false
            }
        }
    }

    private func save() {
        guard let vineyardID = store.selectedVineyardId else { return }
        insights.saveNote(
            draft: draft,
            vineyardID: vineyardID,
            observedByUserID: auth.userId,
            observerName: auth.userName,
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
        draft = VintageNoteDraft()
        isEditing = false
    }

    private func beginEdit(_ note: VintageNote) {
        isEditing = true
        draft = VintageNoteDraft(
            id: note.id,
            date: note.noteDate,
            noteTypeID: note.noteTypeID,
            noteTypeLabel: note.noteTypeLabelSnapshot,
            notes: note.notes ?? ""
        )
    }
}

private struct VintageNoteTypePicker: View {
    @Environment(\.dismiss) private var dismiss

    let customTypes: [VintageNoteType]
    let onSelect: (VintageNoteType) -> Void

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                // Grouped, weather first — see VintageNoteCatalog ordering.
                ForEach(VintageNoteCatalog.grouped(customTypes: customTypes), id: \.group) { entry in
                    let matches = entry.types.filter { type in
                        VintageNoteCatalog.search(query, customTypes: customTypes)
                            .contains { $0.code == type.code }
                    }
                    if !matches.isEmpty {
                        Section(entry.group.label) {
                            ForEach(matches) { type in
                                Button(type.label) { onSelect(type) }
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search note types")
            .navigationTitle("Note type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Vintage Report

/// The prepared report workspace.
///
/// Round 1 deliberately shows an EMPTY report area and disabled controls. There
/// is no template prose and no model call: a plausible-looking narrative
/// produced before the capture data has been reviewed would be
/// indistinguishable from a real one, and a grower would reasonably believe it.
/// The information architecture is settled here so the next round only has to
/// fill it.
struct VintageReportWorkspaceView: View {
    @Environment(MigratedDataStore.self) private var store

    @State private var vintage: Int?

    /// Shown under the disabled Round 1 report controls. Mirrored on Android.
    static let disabledMessage =
        "Vintage Report generation will be enabled after the Scout and Vintage Notes "
        + "data foundation is verified."

    private var resolvedVintage: Int {
        vintage ?? VintageResolver.vintageYear(
            for: Date(),
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
    }

    var body: some View {
        List {
            Section {
                PreviewBadge().listRowBackground(Color.clear)
            }

            Section("Vintage") {
                Stepper(
                    "Vintage \(String(resolvedVintage))",
                    value: Binding(
                        get: { resolvedVintage },
                        set: { vintage = $0 }
                    ),
                    in: 1900...2200
                )
            }

            Section("Report status") {
                LabeledContent("Status", value: "Not generated")
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 140)
                    .overlay {
                        Text("The report will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }

            Section {
                ForEach(
                    [
                        "Scout visits and block observations",
                        "Vintage Notes",
                        "Growth Stage records",
                        "Spray dates, blocks, targets and applications",
                        "Rainfall and available weather history",
                        "Frost, heat, wind, hail, smoke and prolonged wet or dry periods",
                        "Work Tasks and operational Trips",
                        "Pruning, thinning, wire lifting, plucking and trimming activity",
                        "Disease pressure and the responses to it",
                        "Yield estimates, damage, picking and actual yield",
                    ],
                    id: \.self
                ) { source in
                    Text("•  \(source)").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Where the report will come from")
            } footer: {
                Text(
                    "The report will state plainly where data is missing, and will not "
                    + "compare a season against an “average” unless the baseline period "
                    + "and source coverage are known."
                )
            }

            Section {
                Button("Generate / Re-generate Report") {}.disabled(true)
                Button("Add to Existing Report") {}.disabled(true)
                Button("Export PDF") {}.disabled(true)
                Button("Export Word") {}.disabled(true)
            } footer: {
                Text(Self.disabledMessage)
            }
        }
        .navigationTitle("Vintage Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}
