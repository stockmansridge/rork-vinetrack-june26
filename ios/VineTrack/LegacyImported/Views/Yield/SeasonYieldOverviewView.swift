import SwiftUI

/// Yield Overview — the vintage's canonical seasonal estimate.
///
/// Every figure here comes from `get_season_yield_base_overview` (sql/221),
/// the single base-estimate authority. Damage is layered on top per block by
/// ``SeasonYieldDamage`` and is OFF by default.
///
/// An incomplete estimate shows "—", never `0 t`, and names the blocks that
/// still need configuring.
struct SeasonYieldOverviewView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(SeasonYieldEstimateService.self) private var seasonYield

    @State private var selectedVintage: Int?
    @State private var infoBlock: SeasonYieldProjection.BlockRow?

    private var currentVintage: Int {
        VintageResolver.vintageYear(
            for: Date(),
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
    }

    private var reportVintage: Int { selectedVintage ?? currentVintage }

    private var vintageOptions: [Int] {
        [currentVintage + 1, currentVintage, currentVintage - 1, currentVintage - 2]
            .filter { $0 > 0 }
    }

    private var projection: SeasonYieldProjection.Result? {
        guard seasonYield.loadedVintage == reportVintage else { return nil }
        return seasonYield.projection(
            damageRecords: store.damageRecords,
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                vintageSelector
                if let projection {
                    totalCard(projection)
                    damageToggle(projection)
                    if !projection.isEstimateComplete {
                        incompleteCard(projection)
                    }
                    varietySection(projection)
                    blockSection(projection)
                } else if seasonYield.isLoading {
                    loadingCard
                } else {
                    errorCard
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Yield Overview")
        .navigationBarTitleDisplayMode(.large)
        .task(id: reportVintage) { await load() }
        .refreshable { await load() }
        .sheet(item: $infoBlock) { block in
            NavigationStack {
                SeasonYieldBlockInfoView(block: block, damageApplied: projection?.damageApplied ?? false)
            }
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.scrolls)
        }
    }

    private func load() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        await seasonYield.load(vineyardId: vineyardId, vintage: reportVintage)
    }

    // MARK: - Vintage

    private var vintageSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Vintage", systemImage: "calendar")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vintageOptions, id: \.self) { vintage in
                        let isSelected = vintage == reportVintage
                        Button {
                            selectedVintage = vintage
                        } label: {
                            Text(vintage == currentVintage ? "\(String(vintage)) · Current" : String(vintage))
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .white : .secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    isSelected ? VineyardTheme.leafGreen : Color(.tertiarySystemFill),
                                    in: .capsule
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Total

    private func totalCard(_ projection: SeasonYieldProjection.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(projection.damageApplied ? "Estimated crop (damage applied)" : "Estimated crop")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(SeasonYieldFormat.tonnes(projection.displayTotalTonnes))
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(projection.displayTotalTonnes == nil ? Color.secondary : .primary)
                .contentTransition(.numericText())
                .animation(.snappy, value: projection.displayTotalTonnes)

            if projection.damageApplied,
               let base = projection.totalBaseTonnes,
               let adjusted = projection.totalAdjustedTonnes,
               base > adjusted {
                Label(
                    "\(SeasonYieldFormat.tonnes(base - adjusted)) removed by recorded damage (base \(SeasonYieldFormat.tonnes(base)))",
                    systemImage: "arrow.down.right"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack(spacing: 14) {
                statPill(
                    label: "Blocks",
                    value: "\(projection.blocksWithEstimates)/\(projection.blocksTotal)",
                    systemImage: "square.grid.2x2"
                )
                statPill(
                    label: "Source",
                    value: SeasonYieldFormat.sourceLabel(projection.estimateSource),
                    systemImage: "function"
                )
            }
            Text("Calculated \(SeasonYieldFormat.calculatedAt(projection.calculatedAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

    private func statPill(label: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(VineyardTheme.leafGreen)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Damage

    private func damageToggle(_ projection: SeasonYieldProjection.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { seasonYield.applyDamage },
                set: { seasonYield.applyDamage = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apply recorded damage")
                        .font(.subheadline.weight(.semibold))
                    Text("Area-weighted: each record reduces the block by its mapped area × its intensity. The base estimate is always kept.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(VineyardTheme.leafGreen)

            if projection.hasExcludedDamageRecords {
                Label(
                    "Some damage records have no valid mapped area and were excluded.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Incomplete

    private func incompleteCard(_ projection: SeasonYieldProjection.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Estimate incomplete", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("The crop total stays \"—\" until every active block has an estimate. \(SeasonYieldFormat.tonnes(projection.damageApplied ? projection.knownAdjustedTonnes : projection.knownBaseTonnes)) is known so far.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let missing = projection.blocksMissingEstimateNames
            if !missing.isEmpty {
                Text("Needs setting up: \(missing.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 14))
    }

    // MARK: - Varieties

    private func varietySection(_ projection: SeasonYieldProjection.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("By Variety", systemImage: "leaf.fill")
                .font(.headline)
            if projection.varieties.isEmpty {
                emptyHint("No variety estimates for this vintage yet.")
            } else {
                ForEach(projection.varieties) { variety in
                    let tonnes = projection.damageApplied ? variety.adjustedTonnes : variety.baseTonnes
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(variety.displayName)
                                .font(.subheadline.weight(.semibold))
                            if !variety.isEstimateComplete {
                                Text("\(SeasonYieldFormat.tonnes(projection.damageApplied ? variety.knownAdjustedTonnes : variety.knownBaseTonnes)) known so far")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(SeasonYieldFormat.tonnes(tonnes))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(tonnes == nil ? Color.secondary : .primary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Blocks

    private func blockSection(_ projection: SeasonYieldProjection.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("By Block", systemImage: "square.grid.2x2.fill")
                .font(.headline)
            if projection.blocks.isEmpty {
                emptyHint("This vineyard has no blocks yet.")
            } else {
                ForEach(projection.blocks) { block in
                    blockCard(block, damageApplied: projection.damageApplied)
                }
            }
        }
    }

    private func blockCard(_ block: SeasonYieldProjection.BlockRow, damageApplied: Bool) -> some View {
        let tonnes = damageApplied ? block.adjustedTonnes : block.baseTonnes
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(block.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(SeasonYieldFormat.tonnes(tonnes))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(tonnes == nil ? Color.secondary : .primary)
                // The info button: estimate source, calculation date, pruning
                // inputs, damage adjustment and warnings for THIS block.
                Button {
                    infoBlock = block
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .accessibilityLabel("Estimate details for \(block.name)")
            }

            HStack(spacing: 10) {
                Text(SeasonYieldFormat.hectares(block.areaHectares))
                Text("·")
                Text(SeasonYieldFormat.sourceLabel(block.estimateSource))
                if damageApplied, block.damage.damageLossFraction > 0 {
                    Text("·")
                    Text("\(SeasonYieldFormat.percent(fraction: block.damage.damageLossFraction)) damage")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !block.hasEstimates {
                Text("No estimate yet — save the Pruning Yield Calculator for this block.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if !block.isEstimateComplete {
                Text("Missing inputs — tap the info button for details.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - States

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading the seasonal estimate…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var errorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Estimate unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(seasonYield.lastError ?? "Pull down to load the seasonal estimate for this vintage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
    }
}

// MARK: - Block info sheet

/// Everything behind one block's number: where the estimate came from, when it
/// was calculated, the exact pruning inputs the server used, the damage
/// adjustment and every warning.
struct SeasonYieldBlockInfoView: View {
    let block: SeasonYieldProjection.BlockRow
    let damageApplied: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Estimate") {
                infoRow("Source", SeasonYieldFormat.sourceLabel(block.estimateSource))
                infoRow("Calculated", SeasonYieldFormat.calculatedAt(block.calculatedAt))
                infoRow("Block area", SeasonYieldFormat.hectares(block.areaHectares))
                infoRow("Base estimate", SeasonYieldFormat.tonnes(block.baseTonnes))
                if block.baseTonnes == nil {
                    infoRow("Known so far", SeasonYieldFormat.tonnes(block.knownBaseTonnes))
                }
                infoRow(
                    "Status",
                    block.hasEstimates
                        ? (block.isEstimateComplete ? "Complete" : "Missing inputs")
                        : "Not estimated yet"
                )
            }

            Section("Damage adjustment") {
                infoRow("Applied to totals", damageApplied ? "Yes" : "No (base figures shown)")
                infoRow("Damage records used", "\(block.damage.eligibleRecordCount)")
                if block.damage.excludedRecordCount > 0 {
                    infoRow("Excluded (no valid area)", "\(block.damage.excludedRecordCount)")
                }
                infoRow("Damaged area", SeasonYieldFormat.hectares(block.damage.mappedAreaHectares))
                infoRow("Effective loss area", SeasonYieldFormat.hectares(block.damage.effectiveLossHectares))
                infoRow("Loss fraction", SeasonYieldFormat.percent(fraction: block.damage.damageLossFraction))
                infoRow("Remaining yield", SeasonYieldFormat.percent(fraction: block.damage.remainingYieldMultiplier))
                if damageApplied {
                    infoRow("Adjusted estimate", SeasonYieldFormat.tonnes(block.adjustedTonnes))
                }
                Text("Loss = mapped area × intensity ÷ block area, capped at 100%.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let inputs = block.sourceInputs {
                Section("Pruning inputs") {
                    infoRow("Prune method", (inputs.pruneMethod ?? "—").capitalized)
                    if inputs.pruneMethod == "cane" {
                        infoRow("Canes per vine", SeasonYieldFormat.number(inputs.canesPerVine, fractionDigits: 2))
                        infoRow("Buds per cane", SeasonYieldFormat.number(inputs.budsPerCane, fractionDigits: 2))
                    } else {
                        infoRow("Spurs per vine", SeasonYieldFormat.number(inputs.spursPerVine, fractionDigits: 2))
                        infoRow("Buds per spur", SeasonYieldFormat.number(inputs.budsPerSpur, fractionDigits: 2))
                    }
                    infoRow("Buds per vine", SeasonYieldFormat.number(inputs.budsPerVine, fractionDigits: 2))
                    infoRow("Bunches per bud", SeasonYieldFormat.number(inputs.bunchesPerBud, fractionDigits: 2))
                    infoRow("Bunch weight", inputs.bunchWeightGrams.map { String(format: "%.0f g", $0) } ?? "—")
                    infoRow("Vines per ha", SeasonYieldFormat.number(inputs.vinesPerHa))
                    infoRow("Vine count", SeasonYieldFormat.number(inputs.vineCount))
                    infoRow("Vine count basis", SeasonYieldFormat.vineCountBasisLabel(inputs.vineCountBasis))
                    if let formula = inputs.formula {
                        Text(formula)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if (inputs.allocationGroupCount ?? 0) > 0 {
                    Section("Variety allocations") {
                        infoRow("Planting groups", "\(inputs.allocationGroupCount ?? 0)")
                        infoRow(
                            "Allocated",
                            inputs.allocationPercentTotalOriginal.map { String(format: "%.1f%%", $0) } ?? "—"
                        )
                        if inputs.allocationPercentNormalized == true {
                            Text("Allocations exceeded 100% and were scaled back proportionally, so the groups still sum to the block estimate.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !block.groups.isEmpty {
                Section("Planting groups") {
                    ForEach(block.groups) { group in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.displayName)
                                    .font(.subheadline)
                                Text(String(format: "%.1f%% of block", group.allocationPercent))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(SeasonYieldFormat.tonnes(
                                damageApplied ? group.adjustedTonnes : group.baseTonnes
                            ))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(group.baseTonnes == nil ? Color.secondary : .primary)
                        }
                    }
                }
            }

            if !block.warnings.isEmpty {
                Section("Warnings") {
                    ForEach(Array(Set(block.warnings)).sorted(), id: \.self) { code in
                        Label(SeasonYieldWarningCopy.text(for: code), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle(block.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }
}
