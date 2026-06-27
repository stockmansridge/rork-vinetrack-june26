import SwiftUI

// MARK: - Analysis

/// Owner/manager-only audit of the data required to produce reliable cost
/// reports. Reuses the same store data that `TripCostService` and
/// `TripCostAllocationCalculator` consume so the wizard always matches the
/// warnings users see in Trip Detail and Cost Reports.
@MainActor
struct CostingSetupAnalysis {
    enum Topic: String, CaseIterable, Identifiable, Hashable {
        case labour
        case fuel
        case chemicals
        case inputs
        case area
        case yield
        var id: String { rawValue }
    }

    struct Item: Identifiable, Hashable {
        let topic: Topic
        let title: String
        let isComplete: Bool
        let detail: String
        let icon: String
        var id: Topic { topic }
    }

    let items: [Item]

    var allComplete: Bool { items.allSatisfy(\.isComplete) }
    var missingCount: Int { items.filter { !$0.isComplete }.count }

    static func make(store: MigratedDataStore, vineyardId: UUID) -> CostingSetupAnalysis {
        let trips = store.trips.filter { $0.vineyardId == vineyardId }
        let paddocks = store.paddocks.filter { $0.vineyardId == vineyardId }
        let tractors = store.tractors.filter { $0.vineyardId == vineyardId }
        let fuelPurchases = store.fuelPurchases.filter { $0.vineyardId == vineyardId }
        let cats = store.operatorCategories.filter { $0.vineyardId == vineyardId }
        let chems = store.savedChemicals.filter { $0.vineyardId == vineyardId }
        let inputs = store.savedInputs.filter { $0.vineyardId == vineyardId }
        let yields = store.historicalYieldRecords.filter { $0.vineyardId == vineyardId }

        // Labour
        let catsWithRate = cats.filter { $0.costPerHour > 0 }
        let labourComplete = !cats.isEmpty && !catsWithRate.isEmpty
        let labourDetail: String = {
            if cats.isEmpty {
                return "Assign operator categories and hourly rates in Team & Access."
            }
            if catsWithRate.isEmpty {
                return "Operator categories have no hourly rate. Open Operator Categories to add one."
            }
            return "\(catsWithRate.count) operator categor\(catsWithRate.count == 1 ? "y" : "ies") with hourly rate."
        }()

        // Fuel
        let tractorsWithUsage = tractors.filter { $0.fuelUsageLPerHour > 0 }
        let tripsWithoutTractor = trips.filter { $0.tractorId == nil }.count
        let fuelComplete = !tractors.isEmpty
            && !tractorsWithUsage.isEmpty
            && !fuelPurchases.isEmpty
            && tripsWithoutTractor == 0
        let fuelDetail: String = {
            if tractors.isEmpty {
                return "Select tractors on trips, set fuel use in L/hr, and add fuel purchases."
            }
            if tractorsWithUsage.isEmpty {
                return "Tractors are missing fuel use (L/hr). Open Equipment to set."
            }
            if fuelPurchases.isEmpty {
                return "No fuel purchases recorded yet. Add one to enable fuel cost."
            }
            if tripsWithoutTractor > 0 {
                return "\(tripsWithoutTractor) trip\(tripsWithoutTractor == 1 ? "" : "s") missing a tractor link."
            }
            return "Tractors, fuel use and purchases configured."
        }()

        // Chemicals
        let chemsWithCost = chems.filter { ($0.purchase?.costPerBaseUnit ?? 0) > 0 }
        let chemicalComplete: Bool = {
            if chems.isEmpty { return false }
            return chemsWithCost.count == chems.count
        }()
        let chemicalDetail: String = {
            if chems.isEmpty {
                return "Add purchase information to Saved Chemicals so spray costs can be calculated."
            }
            if chemsWithCost.isEmpty {
                return "Saved chemicals are missing purchase costs. Open Saved Chemicals."
            }
            if chemsWithCost.count < chems.count {
                let n = chems.count - chemsWithCost.count
                return "\(n) saved chemical\(n == 1 ? "" : "s") missing purchase cost."
            }
            return "\(chemsWithCost.count) saved chemical\(chemsWithCost.count == 1 ? "" : "s") with purchase cost."
        }()

        // Inputs
        let inputsWithCost = inputs.filter { ($0.costPerUnit ?? 0) > 0 }
        let inputComplete: Bool = {
            if inputs.isEmpty { return false }
            return inputsWithCost.count == inputs.count
        }()
        let inputDetail: String = {
            if inputs.isEmpty {
                return "Add seed, fertiliser or input costs in Saved Inputs and select them in trip lines."
            }
            if inputsWithCost.count < inputs.count {
                let n = inputs.count - inputsWithCost.count
                return "\(n) saved input\(n == 1 ? "" : "s") missing cost per unit."
            }
            return "\(inputsWithCost.count) saved input\(inputsWithCost.count == 1 ? "" : "s") with cost per unit."
        }()

        // Area
        let paddocksWithGeometry = paddocks.filter { $0.polygonPoints.count >= 3 }
        let tripsWithoutPaddock = trips.filter {
            $0.paddockId == nil && $0.paddockIds.isEmpty
        }.count
        let areaComplete = !paddocksWithGeometry.isEmpty && tripsWithoutPaddock == 0
        let areaDetail: String = {
            if paddocksWithGeometry.isEmpty {
                return "Link trips to mapped blocks so treated area and cost/ha can be calculated."
            }
            if tripsWithoutPaddock > 0 {
                return "\(tripsWithoutPaddock) trip\(tripsWithoutPaddock == 1 ? "" : "s") not linked to a block."
            }
            return "\(paddocksWithGeometry.count) block\(paddocksWithGeometry.count == 1 ? "" : "s") mapped."
        }()

        // Yield
        let hasActuals = yields.contains { rec in
            rec.blockResults.contains { ($0.actualYieldTonnes ?? 0) > 0 }
        }
        let yieldDetail: String = hasActuals
            ? "Actual yield records found for cost-per-tonne."
            : "Add actual yield records so cost/tonne can be calculated."

        let items: [Item] = [
            Item(topic: .labour, title: "Operator labour",
                 isComplete: labourComplete, detail: labourDetail,
                 icon: "person.2.fill"),
            Item(topic: .fuel, title: "Fuel costing",
                 isComplete: fuelComplete, detail: fuelDetail,
                 icon: "fuelpump.fill"),
            Item(topic: .chemicals, title: "Chemical costing",
                 isComplete: chemicalComplete, detail: chemicalDetail,
                 icon: "flask.fill"),
            Item(topic: .inputs, title: "Seed / input costing",
                 isComplete: inputComplete, detail: inputDetail,
                 icon: "leaf.fill"),
            Item(topic: .area, title: "Treated area",
                 isComplete: areaComplete, detail: areaDetail,
                 icon: "square.grid.2x2.fill"),
            Item(topic: .yield, title: "Yield tonnes",
                 isComplete: hasActuals, detail: yieldDetail,
                 icon: "scalemass.fill"),
        ]
        return CostingSetupAnalysis(items: items)
    }
}

// MARK: - Section view

/// Embedded section for the Cost Reports list. Owner/manager only — gate at
/// the caller via `accessControl.canViewCosting`.
struct CostingSetupWizardSection: View {
    let analysis: CostingSetupAnalysis

    @State private var expanded: Bool = true

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Complete these setup items so VineTrack can calculate cost by block, variety, hectare and tonne.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(analysis.items) { item in
                        rowDestination(item)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                headerLabel
            }
        } header: {
            Text("Costing setup")
        }
    }

    private var headerLabel: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(headerTint.opacity(0.15))
                    .frame(width: 30, height: 30)
                Image(systemName: analysis.allComplete ? "checkmark.seal.fill" : "list.bullet.clipboard")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(headerTint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(analysis.allComplete ? "Costing setup complete" : "Costing setup")
                    .font(.subheadline.weight(.semibold))
                if !analysis.allComplete {
                    Text("\(analysis.missingCount) item\(analysis.missingCount == 1 ? "" : "s") need attention")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("All required cost inputs are configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var headerTint: Color {
        analysis.allComplete ? VineyardTheme.leafGreen : .orange
    }

    @ViewBuilder
    private func rowDestination(_ item: CostingSetupAnalysis.Item) -> some View {
        switch item.topic {
        case .labour:
            NavigationLink { OperatorCategoriesView() } label: { rowLabel(item) }
        case .fuel:
            NavigationLink { SprayEquipmentHubView() } label: { rowLabel(item) }
        case .chemicals:
            NavigationLink { ChemicalsManagementView() } label: { rowLabel(item) }
        case .inputs:
            NavigationLink { SavedInputsManagementView() } label: { rowLabel(item) }
        case .area:
            NavigationLink { VineyardSetupHubView() } label: { rowLabel(item) }
        case .yield:
            NavigationLink { YieldHubView() } label: { rowLabel(item) }
        }
    }

    private func rowLabel(_ item: CostingSetupAnalysis.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill((item.isComplete ? VineyardTheme.leafGreen : Color.orange).opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: item.isComplete ? "checkmark" : item.icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(item.isComplete ? VineyardTheme.leafGreen : .orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !item.isComplete {
                        Text("Needs setup")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
