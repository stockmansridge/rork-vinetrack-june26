import SwiftUI

// MARK: - Shared irrigation display formatting

enum IrrigationFormat {
    /// Auto-scaling volume: litres → kL → ML for metric; gallons for US/imperial.
    static func volume(_ litres: Double, formatter: RegionFormatter) -> String {
        switch formatter.settings.volume {
        case .litres:
            if litres >= 1_000_000 {
                return String(format: "%.2f ML", litres / 1_000_000)
            } else if litres >= 10_000 {
                return String(format: "%.1f kL", litres / 1_000)
            }
            return formatter.formatVolume(litres: litres, fractionDigits: litres < 100 ? 1 : 0)
        case .gallons:
            return formatter.formatVolume(litres: litres, fractionDigits: 0)
        }
    }

    static func flow(_ litresPerHour: Double, formatter: RegionFormatter) -> String {
        "\(formatter.formatVolume(litres: litresPerHour, fractionDigits: 0))/h"
    }

    static func perVine(_ litres: Double, formatter: RegionFormatter) -> String {
        "\(formatter.formatVolume(litres: litres, fractionDigits: 2))/vine"
    }

    static func perHectare(_ litresPerHectare: Double, formatter: RegionFormatter) -> String {
        switch (formatter.settings.volume, formatter.settings.area) {
        case (.litres, .hectares):
            return String(format: "%.0f L/ha", litresPerHectare)
        default:
            let galPerAcre = IrrigationLocalCalculator.litresPerHectareToGallonsPerAcre(
                litresPerHectare, usGallon: formatter.settings.usesUSGallon)
            return String(format: "%.0f gal/ac", galPerAcre)
        }
    }

    static func depth(_ mm: Double, formatter: RegionFormatter) -> String {
        switch formatter.settings.area {
        case .hectares:
            return String(format: "%.2f mm", mm)
        case .acres:
            return String(format: "%.3f in", IrrigationLocalCalculator.millimetresToInches(mm))
        }
    }

    static func duration(minutes: Int) -> String {
        RegionFormatter.formatDuration(seconds: TimeInterval(minutes * 60))
    }

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func displayDate(_ isoDate: String) -> String {
        guard let date = dateFormat.date(from: isoDate) else { return isoDate }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Session start/end times (SQL 130)

    /// Parses the ISO-8601 timestamptz strings returned by the session RPCs
    /// (with or without fractional seconds).
    static func parseTimestamp(_ iso: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: iso) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso)
    }

    /// "8:30 am–11:45 am" (with " next day" for overnight sessions), or the
    /// start alone when no end was recorded. `nil` when no times exist.
    static func timeRange(startedAt: String?, finishedAt: String?) -> String? {
        guard let startedAt, let start = parseTimestamp(startedAt) else { return nil }
        let startText = start.formatted(date: .omitted, time: .shortened)
        guard let finishedAt, let finish = parseTimestamp(finishedAt) else { return startText }
        let finishText = finish.formatted(date: .omitted, time: .shortened)
        let sameDay = Calendar.current.isDate(start, inSameDayAs: finish)
        return sameDay ? "\(startText)–\(finishText)" : "\(startText)–\(finishText) next day"
    }
}

// MARK: - Irrigation Records hub (feature-gated)

/// Operational Tools → Irrigation Records.
///
/// Phase 1 gate: System Administrators only. The gate is enforced here for
/// navigation AND server-side by `has_irrigation_records_access` — hiding the
/// card is never the security boundary.
struct IrrigationRecordsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(SystemAdminService.self) private var systemAdmin

    @State private var status: IrrigationSetupStatus?
    @State private var summary: IrrigationVintageSummary?
    @State private var recent: [IrrigationSession] = []
    @State private var pendingCount = 0
    @State private var isLoading = true
    @State private var accessDenied = false
    @State private var errorMessage: String?
    @State private var showWizard = false

    private let repository = SupabaseIrrigationRepository.shared

    private var vineyardId: UUID? { store.selectedVineyardId }
    private var vineyardName: String {
        store.vineyards.first { $0.id == store.selectedVineyardId }?.name ?? "Vineyard"
    }
    private var formatter: RegionFormatter {
        RegionFormatter(settings: store.settings.regionSettings)
    }

    var body: some View {
        Group {
            if !systemAdmin.isSystemAdmin || accessDenied {
                unavailableView
            } else if isLoading && status == nil {
                ProgressView("Loading Irrigation Records…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let status, !status.isOperational || showWizard {
                IrrigationSetupWizardView(status: status, showWizard: $showWizard) {
                    await reload()
                }
            } else {
                landing
            }
        }
        .navigationTitle("Irrigation Records")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: vineyardId) { await reload() }
        .refreshable { await reload() }
    }

    private var unavailableView: some View {
        ContentUnavailableView(
            "Not Available",
            systemImage: "drop.circle",
            description: Text("Irrigation Records is not available for this account.")
        )
    }

    // MARK: Landing

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if pendingCount > 0 {
                    pendingBanner
                }

                if let message = errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                if let status, let warning = degradedWarning(status) {
                    warningCard(warning)
                }

                primaryActions
                summaryCards
                recentSection
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(vineyardName)
                .font(.headline)
            if let vintage = status?.season.currentVintageYear {
                Text("Vintage \(String(vintage))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private var pendingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("\(pendingCount) irrigation record\(pendingCount == 1 ? "" : "s") waiting to sync")
                .font(.footnote)
            Spacer()
            Button("Retry") {
                Task { await flushPending() }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func degradedWarning(_ status: IrrigationSetupStatus) -> String? {
        let broken = status.valves.filter { !$0.allocationOk }
        guard !broken.isEmpty else { return nil }
        let names = broken.map { $0.valveName }.joined(separator: ", ")
        return "Block allocations need attention for: \(names). Open Setup → Block Connections to fix them before recording with these valves."
    }

    private func warningCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.footnote)
                Button("Open Setup Wizard") { showWizard = true }
                    .font(.footnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.yellow.opacity(0.12), in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var primaryActions: some View {
        VStack(spacing: 12) {
            NavigationLink {
                IrrigationRecordEntryView(onSaved: { Task { await reload() } })
            } label: {
                Label("Record Irrigation", systemImage: "drop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.cyan.gradient, in: .rect(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                secondaryButton("History", icon: "clock.arrow.circlepath") {
                    IrrigationHistoryView()
                }
                secondaryButton("Setup", icon: "gearshape.fill") {
                    IrrigationSetupView(onChanged: { Task { await reload() } })
                }
                secondaryButton("Reports", icon: "chart.bar.doc.horizontal") {
                    IrrigationReportsCentreView()
                }
            }
        }
        .padding(.horizontal)
    }

    private func secondaryButton<D: View>(_ title: String, icon: String,
                                          @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var summaryCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Vintage")
                .font(.headline)
                .padding(.horizontal)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statCard("Vintage Water",
                         summary.map { IrrigationFormat.volume($0.totalVolumeLitres, formatter: formatter) } ?? "—",
                         icon: "drop.fill", tint: .cyan)
                statCard("This Month",
                         summary.map { IrrigationFormat.volume($0.monthVolumeLitres, formatter: formatter) } ?? "—",
                         icon: "calendar", tint: .blue)
                statCard("Irrigation Hours",
                         summary.map { String(format: "%.1f h", Double($0.totalRuntimeMinutes) / 60) } ?? "—",
                         icon: "timer", tint: .indigo)
                statCard("Sessions",
                         summary.map { "\($0.sessionCount)" } ?? "—",
                         icon: "list.number", tint: .teal)
                if let perVine = summary?.waterLitresPerVine {
                    statCard("Avg Water / Vine",
                             IrrigationFormat.perVine(perVine, formatter: formatter),
                             icon: "leaf.fill", tint: .green)
                }
                if let depth = summary?.irrigationDepthMm {
                    statCard("Irrigation Depth",
                             IrrigationFormat.depth(depth, formatter: formatter),
                             icon: "ruler", tint: .orange)
                }
            }
            .padding(.horizontal)
        }
    }

    private func statCard(_ title: String, _ value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Irrigation")
                .font(.headline)
                .padding(.horizontal)

            if recent.isEmpty {
                Text("No irrigation recorded yet this vintage.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                VStack(spacing: 8) {
                    ForEach(recent) { session in
                        NavigationLink {
                            IrrigationSessionDetailView(sessionId: session.id) {
                                Task { await reload() }
                            }
                        } label: {
                            IrrigationSessionRow(session: session, formatter: formatter)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Data

    private func reload() async {
        guard let vineyardId, systemAdmin.isSystemAdmin else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            await flushPending()
            let status = try await repository.setupStatus(vineyardId: vineyardId)
            self.status = status
            accessDenied = false
            if status.isOperational {
                async let summaryTask = repository.vintageSummary(vineyardId: vineyardId)
                async let recentTask = repository.listSessions(vineyardId: vineyardId, limit: 5)
                self.summary = try await summaryTask
                self.recent = try await recentTask.sessions
            }
        } catch {
            let text = error.localizedDescription
            if text.contains("irrigation_access_denied") {
                accessDenied = true
            } else if status == nil {
                errorMessage = "Irrigation Records could not be loaded. \(text)"
            } else {
                errorMessage = "Latest data could not be refreshed."
            }
        }
    }

    private func flushPending() async {
        guard let vineyardId else { return }
        _ = await repository.flushPending(vineyardId: vineyardId)
        pendingCount = repository.pendingSessions().filter { $0.vineyardId == vineyardId }.count
    }
}

// MARK: - Session row

struct IrrigationSessionRow: View {
    let session: IrrigationSession
    let formatter: RegionFormatter

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(IrrigationFormat.displayDate(session.sessionDate))
                        .font(.subheadline.weight(.semibold))
                    if session.status != "completed" {
                        Text(session.status == "imported" ? "Imported" : session.status.capitalized)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(session.status == "reversed" ? Color.red.opacity(0.15) :
                                        (session.status == "imported" ? Color.cyan.opacity(0.15) : Color.orange.opacity(0.15)),
                                        in: .capsule)
                            .foregroundStyle(session.status == "reversed" ? .red :
                                             (session.status == "imported" ? .cyan : .orange))
                    }
                }
                Text("\(session.valveName ?? "Valve") · \(session.blockNames.isEmpty ? "No blocks" : session.blockNames)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if session.isImported {
                    Text(session.importInfo?.providerLabel ?? "Controller import")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(IrrigationFormat.volume(session.totalVolumeLitres, formatter: formatter))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.status == "reversed" ? .secondary : .primary)
                    .strikethrough(session.status == "reversed")
                Text(IrrigationFormat.duration(minutes: session.durationMinutes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }
}

// MARK: - Setup wizard

struct IrrigationSetupWizardView: View {
    let status: IrrigationSetupStatus
    @Binding var showWizard: Bool
    let onRefresh: () async -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Irrigation Setup", systemImage: "drop.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.cyan)
                    Text("Before recording irrigation, VineTrack needs the growing season, at least one block, an irrigation system, a valve, and block connections totalling 100%. Items already configured in Vineyard Setup are reused — nothing is entered twice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Required") {
                wizardRow(
                    title: "Growing season & vintage",
                    detail: "Season starts \(monthName(status.season.seasonStartMonth)) \(status.season.seasonStartDay) · Vintage \(String(status.season.currentVintageYear))",
                    complete: true,
                    actionLabel: "Open Growing Season Settings"
                ) { OperationPreferencesView() }

                wizardRow(
                    title: "At least one active block",
                    detail: status.required.blocksOk
                        ? "\(status.required.activeBlockCount) active block\(status.required.activeBlockCount == 1 ? "" : "s")"
                        : "No active blocks yet — irrigation valves connect to blocks",
                    complete: status.required.blocksOk,
                    actionLabel: "Open Vineyard Blocks"
                ) { BlocksHubView() }

                wizardRow(
                    title: "Irrigation system",
                    detail: status.required.systemsOk
                        ? "\(status.required.activeSystemCount) active system\(status.required.activeSystemCount == 1 ? "" : "s")"
                        : "Create your first irrigation system (e.g. Main Vineyard Irrigation)",
                    complete: status.required.systemsOk,
                    actionLabel: "Create Irrigation System"
                ) { IrrigationSetupView(initialSection: .systems, onChanged: { Task { await onRefresh() } }) }

                wizardRow(
                    title: "Irrigation valve",
                    detail: status.required.valvesOk
                        ? "\(status.required.activeValveCount) active valve\(status.required.activeValveCount == 1 ? "" : "s")"
                        : "Add at least one valve connected to an irrigation system",
                    complete: status.required.valvesOk,
                    actionLabel: "Create Irrigation Valve"
                ) { IrrigationSetupView(initialSection: .valves, onChanged: { Task { await onRefresh() } }) }

                wizardRow(
                    title: "Valve-to-block connections",
                    detail: status.required.allocationsOk
                        ? "\(status.required.fullyAllocatedValveCount) valve\(status.required.fullyAllocatedValveCount == 1 ? "" : "s") fully allocated (100%)"
                        : "Connect each valve to its blocks — allocations must total 100%",
                    complete: status.required.allocationsOk,
                    actionLabel: "Assign Blocks to Valves"
                ) { IrrigationSetupView(initialSection: .connections, onChanged: { Task { await onRefresh() } }) }

                wizardRow(
                    title: "Valve flow rate",
                    detail: "A configured valve flow rate is required for automatic water calculations from irrigation duration. You may still record irrigation by entering total volume or meter readings. \(status.required.valvesWithConfiguredFlow) of \(status.required.activeValveCount) valves have a flow rate.",
                    complete: status.required.valvesWithConfiguredFlow > 0,
                    recommended: true,
                    actionLabel: "Configure Valve Flow"
                ) { IrrigationSetupView(initialSection: .valves, onChanged: { Task { await onRefresh() } }) }
            }

            Section("Recommended for full reporting") {
                recommendedRow("Block area", status.recommended.blocksWithArea,
                               of: status.recommended.totalActiveBlocks,
                               usedFor: "Water per hectare & irrigation depth") { BlocksHubView() }
                recommendedRow("Vine count", status.recommended.blocksWithVineCount,
                               of: status.recommended.totalActiveBlocks,
                               usedFor: "Water per vine") { BlocksHubView() }
                recommendedRow("Vine spacing", status.recommended.blocksWithVineSpacing,
                               of: status.recommended.totalActiveBlocks,
                               usedFor: "Emitters per vine") { BlocksHubView() }
                recommendedRow("Dripper output", status.recommended.blocksWithDripperOutput,
                               of: status.recommended.totalActiveBlocks,
                               usedFor: "Expected water delivery") { BlocksHubView() }
                recommendedRow("Dripper spacing", status.recommended.blocksWithDripperSpacing,
                               of: status.recommended.totalActiveBlocks,
                               usedFor: "Expected emitters per vine") { BlocksHubView() }
                recommendedRow("Irrigation efficiency", status.recommended.blocksWithEfficiency,
                               of: status.recommended.totalActiveBlocks,
                               usedFor: "Estimated effective water delivered") { BlocksHubView() }
            }

            if status.isOperational {
                Section {
                    Button {
                        showWizard = false
                    } label: {
                        Label("Continue to Irrigation Records", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                }
            }
        }
        .refreshable { await onRefresh() }
    }

    private func monthName(_ month: Int) -> String {
        let symbols = DateFormatter().monthSymbols ?? []
        guard month >= 1 && month <= symbols.count else { return "\(month)" }
        return symbols[month - 1]
    }

    private func wizardRow<D: View>(title: String, detail: String, complete: Bool,
                                    recommended: Bool = false, actionLabel: String,
                                    @ViewBuilder destination: @escaping () -> D) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: complete ? "checkmark.circle.fill" : (recommended ? "info.circle.fill" : "exclamationmark.circle.fill"))
                    .foregroundStyle(complete ? .green : (recommended ? .blue : .orange))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(complete ? "Complete" : (recommended ? "Recommended" : "Required"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((complete ? Color.green : (recommended ? Color.blue : Color.orange)).opacity(0.14),
                                in: .capsule)
                    .foregroundStyle(complete ? .green : (recommended ? .blue : .orange))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !complete || recommended {
                NavigationLink {
                    destination()
                } label: {
                    Text(actionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func recommendedRow<D: View>(_ title: String, _ done: Int, of total: Int,
                                         usedFor: String,
                                         @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    Text(usedFor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(done)/\(total)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(done >= total && total > 0 ? .green : .secondary)
            }
        }
    }
}
