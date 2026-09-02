import SwiftUI

/// Grape Allocation tool (Yields hub): allocate the vintage's canonical
/// seasonal estimate to Own Use destinations or external Sale/Commitment
/// contracts.
///
/// Supply comes from ONE authority — `get_season_yield_base_overview`
/// (sql/221) via ``SeasonYieldEstimateService`` — with damage applied per
/// block by ``SeasonYieldDamage`` when Apply Damage is on. When the DB
/// withholds the canonical total (any active block still unconfigured) the
/// screen shows "—" and refuses to compute a balance: allocating against an
/// invented 0 t is how a grower over-commits a crop nobody has measured.
///
/// Money (price, contract values, income) is Owner/Manager only.
struct GrapeAllocationView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(GrapeAllocationService.self) private var allocationService
    @Environment(SeasonYieldEstimateService.self) private var seasonYield
    @Environment(\.accessControl) private var accessControl

    @State private var selectedVintage: Int?
    @State private var editorContext: EditorContext?
    @State private var deleteCandidate: GrapeAllocation?

    private struct EditorContext: Identifiable {
        let id = UUID()
        let allocation: GrapeAllocation?
        let defaultVintage: Int
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }

    private var currentVintage: Int {
        VintageResolver.vintageYear(
            for: Date(),
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
    }

    private var reportVintage: Int { selectedVintage ?? currentVintage }

    private var availableVintages: [Int] {
        var all = Set(YieldVintageReport.availableVintages(
            currentVintage: currentVintage,
            sessions: store.yieldSessions,
            yieldRecords: store.historicalYieldRecords,
            pickingRecords: store.pickingRecords,
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        ))
        for allocation in allocationService.allocations { all.insert(allocation.vintage) }
        return all.sorted(by: >)
    }

    /// The canonical contract for the selected vintage, damage applied per
    /// block when the toggle is on. nil until the overview has loaded.
    private var projection: SeasonYieldProjection.Result? {
        guard seasonYield.loadedVintage == reportVintage else { return nil }
        return seasonYield.projection(
            damageRecords: store.damageRecords,
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
    }

    private var canonicalSupply: [String: GrapeAllocationCalculator.CanonicalSupply] {
        guard let projection else { return [:] }
        return GrapeAllocationCalculator.canonicalSupply(projection: projection)
    }

    private var summary: GrapeAllocationCalculator.CanonicalSummary {
        GrapeAllocationCalculator.canonicalSummary(
            projection: projection,
            allocations: allocationService.allocations,
            vintage: reportVintage
        )
    }

    private var varietyRows: [GrapeAllocationCalculator.CanonicalVarietyRow] {
        GrapeAllocationCalculator.canonicalVarietyRows(
            supply: canonicalSupply,
            allocations: allocationService.allocations,
            vintage: reportVintage
        )
    }

    private var vintageAllocations: [GrapeAllocation] {
        allocationService.allocations.filter { $0.vintage == reportVintage }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                vintageSelector
                summaryCard
                if canViewFinancials {
                    incomeSection
                }
                varietySection
                allocationsSection
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Grape Allocation")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorContext = EditorContext(allocation: nil, defaultVintage: reportVintage)
                } label: {
                    Label("Add Allocation", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editorContext) { context in
            GrapeAllocationEditorView(
                existing: context.allocation,
                defaultVintage: context.defaultVintage
            )
        }
        .confirmationDialog(
            "Delete this allocation?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let candidate = deleteCandidate {
                    Task { try? await allocationService.delete(id: candidate.id) }
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        }
        .task(id: reportVintage) {
            guard let vineyardId = store.selectedVineyardId else { return }
            await allocationService.load(vineyardId: vineyardId)
            await seasonYield.load(vineyardId: vineyardId, vintage: reportVintage)
        }
        .refreshable {
            guard let vineyardId = store.selectedVineyardId else { return }
            await allocationService.load(vineyardId: vineyardId)
            await seasonYield.load(vineyardId: vineyardId, vintage: reportVintage)
        }
    }

    // MARK: - Vintage selector

    private var vintageSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Vintage", systemImage: "calendar")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableVintages, id: \.self) { vintage in
                        let isSelected = vintage == reportVintage
                        Button {
                            selectedVintage = vintage == currentVintage ? nil : vintage
                        } label: {
                            Text(vintage == currentVintage ? "\(String(vintage)) · Current" : String(vintage))
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .white : .secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(isSelected ? VineyardTheme.leafGreen : Color(.tertiarySystemFill), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                summaryStat(title: "Estimated", tonnes: summary.estimatedTonnes, color: .indigo)
                summaryStat(title: "Own Use", tonnes: summary.ownUseTonnes, color: .purple)
                summaryStat(title: "Committed", tonnes: summary.committedTonnes, color: .orange)
            }
            estimateStatusRow
            Divider()
            HStack {
                Label(
                    availabilityLabel,
                    systemImage: availabilitySymbol
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(availabilityColor)
                Spacer()
                Text(summary.balanceTonnes.map { tonnesText(abs($0)) } ?? "—")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(balanceColor)
            }
            if canViewFinancials {
                Divider()
                HStack {
                    Label("Contracted Income", systemImage: "dollarsign.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.formatCurrency(GrapeAllocationCalculator.totalContractedIncome(
                        allocations: allocationService.allocations,
                        vintage: reportVintage
                    )))
                    .font(.title3.weight(.bold).monospacedDigit())
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func summaryStat(title: String, tonnes: Double?, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(tonnes.map { tonnesText($0) } ?? "—")
                .font(.headline.monospacedDigit())
                .foregroundStyle(tonnes == nil ? Color.secondary : color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var availabilityLabel: String {
        if summary.isSupplyUnknown { return "Available" }
        return summary.isShortfall ? "Shortfall" : "Available"
    }

    private var availabilitySymbol: String {
        if summary.isSupplyUnknown { return "questionmark.circle.fill" }
        return summary.isShortfall ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var availabilityColor: Color {
        if summary.isSupplyUnknown { return Color.secondary }
        return summary.isShortfall ? Color.red : VineyardTheme.leafGreen
    }

    private var balanceColor: Color {
        if summary.isSupplyUnknown { return Color.secondary }
        return summary.isShortfall ? Color.red : Color.primary
    }

    /// Why the estimate is "—", or what it is based on when it isn't. This is
    /// the difference between "you have no crop" and "we don't know your crop
    /// yet", so it is always spelled out rather than left to the dash.
    @ViewBuilder
    private var estimateStatusRow: some View {
        if seasonYield.isLoading && projection == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading the seasonal estimate…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if let error = seasonYield.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let projection, !projection.isEstimateComplete {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    projection.blocksMissingEstimates > 0
                        ? "\(projection.blocksMissingEstimates) of \(projection.blocksTotal) blocks have no estimate yet"
                        : "Some blocks are missing calculator inputs",
                    systemImage: "info.circle"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                Text("Allocating needs a complete estimate. \(tonnesText(summary.knownEstimatedTonnes)) is known so far — finish the Pruning Yield Calculator for every block.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let projection {
            Text(estimateBasisText(projection))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func estimateBasisText(_ projection: SeasonYieldProjection.Result) -> String {
        let source = SeasonYieldFormat.sourceLabel(projection.estimateSource)
        let damage = projection.damageApplied ? "damage applied" : "before damage"
        return "\(source) · \(projection.blocksTotal) blocks · \(damage)"
    }

    // MARK: - Income (Owner/Manager)

    private var incomeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Income Breakdown", systemImage: "chart.pie.fill")
                .font(.headline)
            incomeGroup(title: "By Purchaser", lines: GrapeAllocationCalculator.incomeByPurchaser(
                allocations: allocationService.allocations, vintage: reportVintage))
            incomeGroup(title: "By Variety", lines: GrapeAllocationCalculator.incomeByVariety(
                allocations: allocationService.allocations, vintage: reportVintage))
            incomeGroup(title: "By Block", lines: GrapeAllocationCalculator.incomeByBlock(
                allocations: allocationService.allocations, vintage: reportVintage))
        }
    }

    @ViewBuilder
    private func incomeGroup(title: String, lines: [GrapeAllocationCalculator.IncomeLine]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(lines) { line in
                    HStack {
                        Text(line.label)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(tonnesText(line.tonnes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(fmt.formatCurrency(line.value))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
    }

    // MARK: - Varieties

    private var varietySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Varieties", systemImage: "leaf.fill")
                .font(.headline)
            if varietyRows.isEmpty {
                Text("No seasonal estimate and no allocations for this vintage yet. Save the Pruning Yield Calculator for your blocks to see the estimated supply per variety.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            } else {
                ForEach(varietyRows) { row in
                    varietyCard(row)
                }
            }
        }
    }

    private func varietyCard(_ row: GrapeAllocationCalculator.CanonicalVarietyRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if row.isShortfall {
                    Label("Shortfall", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                } else if row.isSupplyUnknown {
                    Label("Estimate incomplete", systemImage: "questionmark.circle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 0) {
                varietyStat("Estimated", row.estimatedTonnes, .indigo)
                varietyStat("Own Use", row.ownUseTonnes, .purple)
                varietyStat("External", row.externalTonnes, .orange)
                VStack(spacing: 2) {
                    Text(row.balanceTonnes.map { tonnesText($0) } ?? "—")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(
                            row.isSupplyUnknown
                                ? Color.secondary
                                : (row.isShortfall ? .red : VineyardTheme.leafGreen)
                        )
                    Text("Balance")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            if row.isSupplyUnknown && row.knownEstimatedTonnes > 0 {
                Text("\(tonnesText(row.knownEstimatedTonnes)) known so far — not enough to allocate against.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func varietyStat(_ title: String, _ tonnes: Double?, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(tonnes.map { tonnesText($0) } ?? "—")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tonnes == nil ? Color.secondary : color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Allocation list

    private var allocationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Allocations", systemImage: "shippingbox.fill")
                    .font(.headline)
                Spacer()
                if allocationService.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let error = allocationService.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if vintageAllocations.isEmpty {
                Text("No allocations for Vintage \(String(reportVintage)) yet. Tap + to add an Own Use allocation or a Sale / Commitment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            } else {
                ForEach(vintageAllocations) { allocation in
                    allocationCard(allocation)
                }
            }
        }
    }

    private func allocationCard(_ allocation: GrapeAllocation) -> some View {
        Button {
            editorContext = EditorContext(allocation: allocation, defaultVintage: allocation.vintage)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(allocation.allocationType.displayName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            allocation.allocationType == .ownUse ? Color.purple.opacity(0.15) : Color.orange.opacity(0.15),
                            in: .capsule
                        )
                        .foregroundStyle(allocation.allocationType == .ownUse ? .purple : .orange)
                    Spacer()
                    Text(tonnesText(allocation.quantityTonnes))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                }
                Text(allocation.varietyName)
                    .font(.subheadline.weight(.semibold))
                if allocation.allocationType == .external {
                    if let purchaser = allocation.purchaserName, !purchaser.isEmpty {
                        Text(purchaser)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    contactLinks(allocation)
                    if canViewFinancials, let price = allocation.pricePerTonne {
                        HStack {
                            Text("\(fmt.formatCurrency(price)) / t")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let value = allocation.contractValue {
                                Text(fmt.formatCurrency(value))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                            }
                        }
                    }
                } else if let destination = allocation.destinationName, !destination.isEmpty {
                    Text(destination)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !allocation.blocks.isEmpty {
                    Text(allocation.blocks.map { block in
                        block.quantityTonnes.map { "\(block.paddockName) (\(tonnesText($0)))" } ?? block.paddockName
                    }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                deleteCandidate = allocation
            } label: {
                Label("Delete Allocation", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func contactLinks(_ allocation: GrapeAllocation) -> some View {
        HStack(spacing: 14) {
            if let email = allocation.contactEmail, !email.isEmpty,
               let url = URL(string: "mailto:\(email)") {
                Link(destination: url) {
                    Label(email, systemImage: "envelope.fill")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            if let phone = allocation.contactPhone, !phone.isEmpty,
               let url = URL(string: "tel:\(phone.replacingOccurrences(of: " ", with: ""))") {
                Link(destination: url) {
                    Label(phone, systemImage: "phone.fill")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    private func tonnesText(_ tonnes: Double) -> String {
        String(format: "%.2f t", tonnes)
    }
}

// MARK: - Editor

/// Add / edit sheet for one allocation. Money entry (price per tonne) is
/// only rendered for Owner/Manager; the server routing trigger enforces it
/// regardless of what the client sends.
struct GrapeAllocationEditorView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(GrapeAllocationService.self) private var allocationService
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss

    let existing: GrapeAllocation?
    let defaultVintage: Int

    @State private var allocationType: GrapeAllocationType = .ownUse
    @State private var vintage: Int = 0
    @State private var varietyName: String = ""
    @State private var varietyKey: String?
    @State private var varietyId: UUID?
    @State private var destinationName: String = ""
    @State private var quantityText: String = ""
    @State private var notes: String = ""
    @State private var purchaserName: String = ""
    @State private var contactName: String = ""
    @State private var contactEmail: String = ""
    @State private var contactPhone: String = ""
    @State private var contactAddress: String = ""
    @State private var priceText: String = ""
    @State private var purchaserId: UUID?
    @State private var purchaserFormContext: PurchaserFormContext?
    @State private var blockRows: [BlockRowDraft] = []
    @State private var isSaving: Bool = false
    @State private var saveError: String?
    @State private var didLoad: Bool = false

    /// One additive block-assignment row: block dropdown + tonnes + remove.
    private struct BlockRowDraft: Identifiable {
        let id: UUID
        var paddockId: UUID?
        var tonnesText: String
    }

    private struct PurchaserFormContext: Identifiable {
        let id = UUID()
        let existing: GrapePurchaser?
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }

    private var currentVintage: Int {
        VintageResolver.vintageYear(
            for: Date(),
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
    }

    private var vintageOptions: [Int] {
        var all: Set<Int> = [currentVintage, currentVintage + 1, defaultVintage, vintage]
        for allocation in allocationService.allocations { all.insert(allocation.vintage) }
        return all.filter { $0 > 0 }.sorted(by: >)
    }

    /// Unique planted varieties across the vineyard's blocks (name + key).
    private var varietyOptions: [(name: String, key: String?, id: UUID?)] {
        var seen: Set<String> = []
        var options: [(name: String, key: String?, id: UUID?)] = []
        for paddock in store.paddocks {
            for allocation in paddock.varietyAllocations {
                let name = (allocation.name ?? "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let canonical = PickingYieldAggregator.normalisedVariety(name)
                guard !seen.contains(canonical) else { continue }
                seen.insert(canonical)
                options.append((name, allocation.varietyKey, allocation.varietyId))
            }
        }
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var quantityTonnes: Double? {
        Double(quantityText.replacingOccurrences(of: ",", with: "."))
    }

    private var pricePerTonne: Double? {
        Double(priceText.replacingOccurrences(of: ",", with: "."))
    }

    /// Blocks compatible with the chosen variety — falls back to ALL blocks
    /// when no variety is chosen or nothing matches (a block without variety
    /// data must never be unselectable).
    private var compatiblePaddocks: [Paddock] {
        let canonical = PickingYieldAggregator.normalisedVariety(varietyName)
        guard !canonical.isEmpty else { return store.paddocks }
        let matching = store.paddocks.filter { paddock in
            paddock.varietyAllocations.contains {
                PickingYieldAggregator.normalisedVariety($0.name ?? "") == canonical
            }
        }
        return matching.isEmpty ? store.paddocks : matching
    }

    private var blockAssignment: GrapeAllocationFormLogic.BlockAssignmentSummary {
        GrapeAllocationFormLogic.blockAssignmentSummary(
            quantityTonnes: quantityTonnes ?? 0,
            blockTonnes: blockRows
                .filter { $0.paddockId != nil }
                .map { Double($0.tonnesText.replacingOccurrences(of: ",", with: ".")) }
        )
    }

    private var selectedPurchaser: GrapePurchaser? {
        purchaserId.flatMap { id in allocationService.purchasers.first { $0.id == id } }
    }

    private var canSave: Bool {
        guard let tonnes = quantityTonnes, tonnes > 0 else { return false }
        guard !varietyName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !blockAssignment.exceedsQuantity else { return false }
        if allocationType == .external {
            return !purchaserName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Allocation") {
                    Picker("Type", selection: $allocationType) {
                        ForEach(GrapeAllocationType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Vintage", selection: $vintage) {
                        ForEach(vintageOptions, id: \.self) { option in
                            Text(option == currentVintage ? "\(String(option)) · Current" : String(option)).tag(option)
                        }
                    }

                    varietyPicker

                    HStack(spacing: 6) {
                        Text("Tonnes")
                        FieldInfoButton(
                            title: "Quantity",
                            message: "Total tonnes committed under this allocation."
                        )
                        Spacer()
                        TextField("0.0", text: $quantityText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }

                    if allocationType == .ownUse {
                        TextField("Destination / use (e.g. Estate wine)", text: $destinationName)
                    } else {
                        TextField("Destination (optional)", text: $destinationName)
                    }
                }

                if allocationType == .external {
                    Section {
                        purchaserPicker
                        TextField("Purchaser name", text: $purchaserName)
                        TextField("Contact person", text: $contactName)
                        TextField("Email", text: $contactEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                        TextField("Phone", text: $contactPhone)
                            .keyboardType(.phonePad)
                        TextField("Address", text: $contactAddress)
                    } header: {
                        Text("Purchaser")
                    } footer: {
                        Text("Details are saved as a snapshot on this commitment — later edits to the saved purchaser never change existing allocations.")
                    }

                    if canViewFinancials {
                        Section {
                            HStack(spacing: 6) {
                                Text("Price per tonne")
                                FieldInfoButton(
                                    title: "Price per tonne",
                                    message: "Agreed price for this individual commitment. Contract value is calculated from quantity × price per tonne."
                                )
                                Spacer()
                                Text(fmt.currencyCode)
                                    .foregroundStyle(.secondary)
                                TextField("0", text: $priceText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 100)
                            }
                            if let tonnes = quantityTonnes, let price = pricePerTonne {
                                HStack {
                                    Text("Contract value")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(fmt.formatCurrency(tonnes * price))
                                        .font(.body.weight(.semibold).monospacedDigit())
                                }
                            }
                        } header: {
                            Text("Pricing")
                        } footer: {
                            Text("Visible to Owner and Manager only.")
                        }
                    }
                }

                Section {
                    ForEach($blockRows) { $row in
                        blockRowView($row)
                    }
                    Button {
                        blockRows.append(BlockRowDraft(id: UUID(), paddockId: nil, tonnesText: ""))
                    } label: {
                        Label("Add block", systemImage: "plus")
                    }
                    if !blockRows.isEmpty, let tonnes = quantityTonnes, tonnes > 0 {
                        assignmentSummary(tonnes)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Block allocations (optional)")
                        FieldInfoButton(
                            title: "Block allocations",
                            message: "Optionally nominate which blocks will supply this commitment. Enter the tonnes expected from each block. Assigned tonnes cannot exceed the committed quantity."
                        )
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Allocation" : "Edit Allocation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave || isSaving)
                }
            }
            .onAppear { loadExisting() }
            .sheet(item: $purchaserFormContext) { context in
                GrapePurchaserFormView(existing: context.existing) { saved in
                    selectPurchaser(saved)
                }
            }
        }
    }

    // MARK: - Purchaser picker

    private var purchaserPicker: some View {
        HStack {
            Menu {
                ForEach(allocationService.purchasers) { purchaser in
                    Button(purchaser.wineryName) { selectPurchaser(purchaser) }
                }
                if purchaserId != nil {
                    Button("Unlink saved purchaser") { purchaserId = nil }
                }
                Divider()
                Button {
                    purchaserFormContext = PurchaserFormContext(existing: nil)
                } label: {
                    Label("New Purchaser", systemImage: "plus")
                }
            } label: {
                HStack {
                    Text("Saved purchaser")
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Text(selectedPurchaser?.wineryName ?? "Select\u{2026}")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if selectedPurchaser != nil {
                Button("Edit") {
                    purchaserFormContext = PurchaserFormContext(existing: selectedPurchaser)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Copies the purchaser's CURRENT details into the snapshot fields —
    /// exactly what gets stored on the allocation.
    private func selectPurchaser(_ purchaser: GrapePurchaser) {
        purchaserId = purchaser.id
        purchaserName = purchaser.wineryName
        contactName = purchaser.contactName ?? ""
        contactEmail = purchaser.contactEmail ?? ""
        contactPhone = purchaser.contactPhone ?? ""
        contactAddress = purchaser.contactAddress ?? ""
    }

    // MARK: - Block assignment rows

    private func blockRowView(_ row: Binding<BlockRowDraft>) -> some View {
        HStack {
            Menu {
                ForEach(availablePaddocks(for: row.wrappedValue)) { paddock in
                    Button(paddock.name) { row.wrappedValue.paddockId = paddock.id }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(paddockName(row.wrappedValue.paddockId) ?? "Select block\u{2026}")
                        .foregroundStyle(row.wrappedValue.paddockId == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField("Tonnes", text: row.tonnesText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
            Button {
                blockRows.removeAll { $0.id == row.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove block row")
        }
    }

    /// Variety-compatible blocks not already used by another row (the row's
    /// own selection stays available).
    private func availablePaddocks(for row: BlockRowDraft) -> [Paddock] {
        let used = Set(blockRows.filter { $0.id != row.id }.compactMap(\.paddockId))
        return compatiblePaddocks.filter { !used.contains($0.id) }
    }

    private func paddockName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return store.paddocks.first { $0.id == id }?.name
    }

    @ViewBuilder
    private func assignmentSummary(_ tonnes: Double) -> some View {
        let summary = blockAssignment
        Text("Assigned \(tonnesLabel(summary.assignedTonnes)) of \(tonnesLabel(tonnes)) \u{00B7} Unassigned \(tonnesLabel(summary.unassignedTonnes))")
            .font(.caption)
            .foregroundStyle(summary.exceedsQuantity ? Color.red : Color.secondary)
        if summary.exceedsQuantity {
            Text("Assigned tonnes exceed the committed quantity.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        }
    }

    private func tonnesLabel(_ tonnes: Double) -> String {
        String(format: "%.1f t", tonnes)
    }

    private var varietyPicker: some View {
        Picker("Variety", selection: Binding(
            get: { PickingYieldAggregator.normalisedVariety(varietyName) },
            set: { canonical in
                if let option = varietyOptions.first(where: { PickingYieldAggregator.normalisedVariety($0.name) == canonical }) {
                    varietyName = option.name
                    varietyKey = option.key
                    varietyId = option.id
                }
            }
        )) {
            if varietyName.isEmpty {
                Text("Select…").tag("")
            } else if !varietyOptions.contains(where: {
                PickingYieldAggregator.normalisedVariety($0.name) == PickingYieldAggregator.normalisedVariety(varietyName)
            }) {
                Text(varietyName).tag(PickingYieldAggregator.normalisedVariety(varietyName))
            }
            ForEach(varietyOptions, id: \.name) { option in
                Text(option.name).tag(PickingYieldAggregator.normalisedVariety(option.name))
            }
        }
    }

    private func loadExisting() {
        guard !didLoad else { return }
        didLoad = true
        vintage = existing?.vintage ?? defaultVintage
        guard let existing else { return }
        allocationType = existing.allocationType
        varietyName = existing.varietyName
        varietyKey = existing.varietyKey
        varietyId = existing.varietyId
        destinationName = existing.destinationName ?? ""
        quantityText = String(format: "%g", existing.quantityTonnes)
        notes = existing.notes ?? ""
        purchaserName = existing.purchaserName ?? ""
        contactName = existing.contactName ?? ""
        contactEmail = existing.contactEmail ?? ""
        contactPhone = existing.contactPhone ?? ""
        contactAddress = existing.contactAddress ?? ""
        purchaserId = existing.purchaserId
        if let price = existing.pricePerTonne {
            priceText = String(format: "%g", price)
        }
        blockRows = existing.blocks.map { block in
            BlockRowDraft(
                id: block.id,
                paddockId: block.paddockId,
                tonnesText: block.quantityTonnes.map { String(format: "%g", $0) } ?? ""
            )
        }
    }

    private func save() {
        guard let vineyardId = store.selectedVineyardId, let tonnes = quantityTonnes else { return }
        let paddockById = Dictionary(store.paddocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let existingBlockIds = Dictionary(
            (existing?.blocks ?? []).map { ($0.paddockId, $0.id) },
            uniquingKeysWith: { a, _ in a }
        )
        var seenPaddocks: Set<UUID> = []
        let blocks: [GrapeAllocationBlock] = blockRows.compactMap { row in
            guard let paddockId = row.paddockId, let paddock = paddockById[paddockId] else { return nil }
            guard seenPaddocks.insert(paddockId).inserted else { return nil }
            let blockTonnes = Double(row.tonnesText.replacingOccurrences(of: ",", with: "."))
            return GrapeAllocationBlock(
                id: existingBlockIds[paddockId] ?? UUID(),
                paddockId: paddockId,
                paddockName: paddock.name,
                quantityTonnes: (blockTonnes ?? 0) > 0 ? blockTonnes : nil
            )
        }
        .sorted { $0.paddockName.localizedCaseInsensitiveCompare($1.paddockName) == .orderedAscending }

        let isExternal = allocationType == .external
        let allocation = GrapeAllocation(
            id: existing?.id ?? UUID(),
            vineyardId: vineyardId,
            vintage: vintage,
            allocationType: allocationType,
            varietyId: varietyId,
            varietyKey: varietyKey,
            varietyName: varietyName.trimmingCharacters(in: .whitespaces),
            destinationName: destinationName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : destinationName.trimmingCharacters(in: .whitespaces),
            quantityTonnes: tonnes,
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes.trimmingCharacters(in: .whitespaces),
            purchaserId: isExternal ? purchaserId : nil,
            purchaserName: isExternal && !purchaserName.trimmingCharacters(in: .whitespaces).isEmpty ? purchaserName.trimmingCharacters(in: .whitespaces) : nil,
            contactName: isExternal && !contactName.trimmingCharacters(in: .whitespaces).isEmpty ? contactName.trimmingCharacters(in: .whitespaces) : nil,
            contactEmail: isExternal && !contactEmail.trimmingCharacters(in: .whitespaces).isEmpty ? contactEmail.trimmingCharacters(in: .whitespaces) : nil,
            contactPhone: isExternal && !contactPhone.trimmingCharacters(in: .whitespaces).isEmpty ? contactPhone.trimmingCharacters(in: .whitespaces) : nil,
            contactAddress: isExternal && !contactAddress.trimmingCharacters(in: .whitespaces).isEmpty ? contactAddress.trimmingCharacters(in: .whitespaces) : nil,
            pricePerTonne: isExternal && canViewFinancials ? pricePerTonne : (isExternal ? existing?.pricePerTonne : nil),
            blocks: blocks,
            updatedAt: existing?.updatedAt
        )

        isSaving = true
        saveError = nil
        Task {
            do {
                try await allocationService.save(allocation, createdBy: nil)
                dismiss()
            } catch {
                saveError = "Couldn't save the allocation. Check your connection and try again."
                print("[GrapeAllocationEditor] save failed: \(error)")
            }
            isSaving = false
        }
    }
}
