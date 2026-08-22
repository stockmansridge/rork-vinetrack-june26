import SwiftUI

/// Start Trip → how this spray is being set up.
///
/// Exactly TWO choices, in this order:
///   1. Resume a Spray Program — pick where you are in the vineyard program
///   2. One-off Spray — a blank guided calculator
///
/// The separate "Plan from Program" card is gone. It and "Resume a Spray
/// Program" were two doors into the same act — "start from the program" — and
/// offering both forced the operator to guess which one meant what. Resuming
/// now absorbs the Program Step selection that used to sit behind Plan from
/// Program.
///
/// Program → Program Step → Plan Spray is UNTOUCHED. That route still exists in
/// the Spray Program tab, where planning a step is the obvious thing to do to a
/// step you are already looking at. What changed is only this entry point.
///
/// Wording speaks the Program vocabulary; the underlying source objects
/// (`isTemplate`, `SprayJobTemplateService`) are unchanged.
struct SprayTripSetupSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(TripTrackingService.self) private var tracking
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(SprayJobTemplateService.self) private var portalTemplates
    @Environment(\.dismiss) private var dismiss

    @State private var showResumeProgram: Bool = false
    @State private var showCalculator: Bool = false
    @State private var planningStep: SprayProgramStep?

    /// The vineyard's Program, from the SAME sources the Spray Program tab
    /// reads: local steps, portal steps, one dedup rule, one offline cache.
    /// Nothing is copied into `spray_records` by looking at it.
    private var programSteps: [SprayProgramStep] {
        SprayProgramCatalog.steps(
            localRecords: store.sprayRecords,
            portalRecords: portalTemplates.templateRecords,
            portalRows: portalTemplates.templates
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    Image(systemName: "sprinkler.and.droplets.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(VineyardTheme.leafGreen.gradient)
                        .padding(.top, 24)

                    VStack(spacing: 6) {
                        Text("Spray Trip Setup")
                            .font(.title2.bold())
                        Text("How would you like to set up this spray?")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.bottom, 24)

                VStack(spacing: 12) {
                    SprayTripSetupCard(
                        icon: "list.bullet.rectangle.portrait.fill",
                        title: SprayTripSetupOption.resumeProgram.title,
                        subtitle: SprayTripSetupOption.resumeProgram.subtitle(
                            programStepCount: programSteps.count
                        ),
                        color: VineyardTheme.leafGreen,
                        disabled: false
                    ) {
                        showResumeProgram = true
                    }

                    SprayTripSetupCard(
                        icon: "plus.rectangle.on.rectangle",
                        title: SprayTripSetupOption.oneOffSpray.title,
                        subtitle: SprayTripSetupOption.oneOffSpray.subtitle(
                            programStepCount: programSteps.count
                        ),
                        color: .blue,
                        disabled: false
                    ) {
                        showCalculator = true
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Spray Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showResumeProgram) {
                SprayProgramResumePickerSheet(
                    steps: programSteps,
                    onSelectStep: { step in
                        showResumeProgram = false
                        // Let the picker finish dismissing before the
                        // calculator is presented.
                        DispatchQueue.main.async { planningStep = step }
                    },
                    onResumeRecord: { record in
                        showResumeProgram = false
                        DispatchQueue.main.async { startTripFromRecord(record) }
                    }
                )
            }
            .sheet(item: $planningStep, onDismiss: { dismiss() }) { step in
                NavigationStack {
                    // THE shared Program → Calculator route, identical to the
                    // Spray Program tab's Plan Spray. One prefill
                    // implementation: two that build prefill differently is how
                    // the two drift apart.
                    SprayCalculatorView(
                        prefillRecord: step.record,
                        prefillProgram: step.calculatorPrefill
                    )
                }
            }
            .sheet(isPresented: $showCalculator, onDismiss: { dismiss() }) {
                NavigationStack { SprayCalculatorView() }
            }
            .task {
                // Offline-safe hydration of portal Program Steps for this
                // vineyard, so Resume works in a shed with no signal.
                portalTemplates.loadCached(for: store.selectedVineyardId)
            }
        }
    }

    private func startTripFromRecord(_ record: SprayRecord) {
        let trip = store.trips.first(where: { $0.id == record.tripId })
        let paddockId: UUID? = trip?.paddockId ?? trip?.paddockIds.first
        let paddockName: String = trip?.paddockName
            ?? (paddockId.flatMap { id in store.paddocks.first(where: { $0.id == id })?.name } ?? "")

        tracking.startTrip(
            type: .spray,
            paddockId: paddockId,
            paddockName: paddockName,
            trackingPattern: trip?.trackingPattern ?? .sequential,
            personName: auth.userName ?? ""
        )

        if let activeTrip = tracking.activeTrip, record.tripId != activeTrip.id {
            var updated = record
            updated.tripId = activeTrip.id
            store.updateSprayRecord(updated)
        }

        dismiss()
    }
}

/// The Start Trip choices, as data.
///
/// Enumerated rather than written inline so the two-option contract — what they
/// are, and which comes first — is something tests can assert instead of
/// something a future edit can quietly add a third card to.
nonisolated enum SprayTripSetupOption: String, CaseIterable, Sendable {
    /// Start from the vineyard's spray program.
    case resumeProgram
    /// Start from nothing.
    case oneOffSpray

    /// The options Start Trip presents, in display order.
    static var presentationOrder: [SprayTripSetupOption] { [.resumeProgram, .oneOffSpray] }

    var title: String {
        switch self {
        case .resumeProgram: return "Resume a Spray Program"
        case .oneOffSpray: return SprayProgramTerminology.oneOffSpray
        }
    }

    func subtitle(programStepCount: Int) -> String {
        switch self {
        case .resumeProgram:
            return programStepCount == 0
                ? "No Program Steps yet — add one in Spray Program or the admin portal"
                : "Pick up where you are in the vineyard program (\(programStepCount) steps)"
        case .oneOffSpray:
            return "Open the spray calculator and configure a spray from scratch"
        }
    }
}

private struct SprayTripSetupCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(disabled ? .secondary : color)
                    .frame(width: 44, height: 44)
                    .background((disabled ? Color.secondary : color).opacity(0.12))
                    .clipShape(.rect(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(disabled ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
        }
        .disabled(disabled)
    }
}

// MARK: - Resume a Spray Program

/// The vineyard's Spray Program, in phenological order.
///
/// This screen replaced a list of historical spray RECORDS. That list answered
/// "which spray did we do?", which is not the question Start Trip asks —
/// resuming a program means "where are we up to in the season", and completed
/// records, trip links, dates and tank counts are noise against it.
///
/// So the body is the actual reusable Program, grouped by E-L stage. Genuinely
/// in-progress work keeps a small section of its own at the top, because
/// abandoning a spray that is mid-flight would be a real regression — but it is
/// deliberately separate, and completed history does not appear at all.
struct SprayProgramResumePickerSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let steps: [SprayProgramStep]
    /// A Program Step to plan. Prefills the calculator; the step is untouched.
    let onSelectStep: (SprayProgramStep) -> Void
    /// A genuinely in-progress spray record to carry on with.
    let onResumeRecord: (SprayRecord) -> Void

    @State private var searchText: String = ""

    /// Sprays that are actually still running: linked to an active trip and not
    /// yet ended. Completed records are excluded outright — they are history,
    /// and history is not something you resume.
    private var inProgressRecords: [SprayRecord] {
        store.sprayRecords
            .filter { record in
                guard !record.isTemplate, record.endTime == nil else { return false }
                guard let trip = store.trips.first(where: { $0.id == record.tripId }) else { return false }
                return trip.isActive
            }
            .sorted { $0.date > $1.date }
    }

    private var sections: [SprayProgramStageSection] {
        SprayProgramCatalog.groupedByStage(
            SprayProgramCatalog.filtered(steps, query: searchText)
        )
    }

    private var isEmpty: Bool {
        sections.isEmpty && inProgressRecords.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if !inProgressRecords.isEmpty && searchText.isEmpty {
                    Section {
                        ForEach(inProgressRecords) { record in
                            Button {
                                onResumeRecord(record)
                                dismiss()
                            } label: {
                                inProgressRow(record)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label("In Progress", systemImage: "record.circle")
                    } footer: {
                        Text("Sprays already under way on an active trip.")
                    }
                }

                ForEach(sections) { section in
                    Section {
                        ForEach(section.steps) { step in
                            Button {
                                onSelectStep(step)
                                dismiss()
                            } label: {
                                SprayProgramResumeRow(step: step)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(section.title)
                    }
                }

                if !sections.isEmpty {
                    Section {
                        Label {
                            Text("Choosing a Program Step pre-fills a new spray. The Program Step itself is not changed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Resume a Spray Program")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search program")
            .overlay {
                if isEmpty {
                    ContentUnavailableView {
                        Label(
                            searchText.isEmpty ? "No Program Steps" : "No matches",
                            systemImage: "list.bullet.rectangle.portrait"
                        )
                    } description: {
                        Text(
                            searchText.isEmpty
                                ? "Build your vineyard spray program by adding reusable Program Steps, or create them in the Admin Portal."
                                : "No Program Steps match \u{201C}\(searchText)\u{201D}."
                        )
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func inProgressRow(_ record: SprayRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.title3)
                .foregroundStyle(VineyardTheme.warning)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.sprayReference.isEmpty ? "Spray in progress" : record.sprayReference)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Started \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// One Program Step, as the program describes it.
///
/// Name, targets, products with their programmed rates, and the application
/// method. Deliberately no date, tank count, trip, duration, completion state
/// or sync metadata: those describe an application that happened, and a Program
/// Step never happened.
private struct SprayProgramResumeRow: View {
    let step: SprayProgramStep

    private var productSummary: String {
        step.products
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { product in
                let rate = product.displayReportedRate
                guard rate > 0 else { return product.name }
                let basis = product.reportedRateBasis == .per100Litres ? "/100L" : "/ha"
                return "\(product.name) \(SprayProgramResumeRow.format(rate)) \(product.unit.rawValue)\(basis)"
            }
            .joined(separator: " · ")
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(step.name.isEmpty ? "Untitled Program Step" : step.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let targets = step.targetDisplay {
                    Label(targets, systemImage: "scope")
                        .font(.caption)
                        .foregroundStyle(VineyardTheme.olive)
                        .lineLimit(2)
                }

                if !productSummary.isEmpty {
                    Text(productSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // The method belongs on the row, not as the list's sequence.
                Text(step.operationType.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
