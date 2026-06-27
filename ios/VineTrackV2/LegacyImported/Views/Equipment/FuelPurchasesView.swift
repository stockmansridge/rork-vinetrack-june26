import SwiftUI

/// Lists `fuel_purchases` for the selected vineyard and shows the season's
/// average cost per litre. Reached from the FUEL section of the Equipment screen.
struct FuelPurchasesView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    @State private var showAddFuelSheet: Bool = false
    @State private var editingFuelPurchase: FuelPurchase?

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    /// Region-aware display formatter (AU defaults when no settings exist).
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    var body: some View {
        List {
            Section {
                ForEach(store.fuelPurchases.sorted(by: { $0.date > $1.date })) { purchase in
                    Group {
                        if canManageSetup {
                            Button { editingFuelPurchase = purchase } label: { FuelPurchaseRow(purchase: purchase) }
                        } else {
                            FuelPurchaseRow(purchase: purchase)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if canManageSetup {
                            Button(role: .destructive) {
                                store.deleteFuelPurchase(purchase)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                if !store.fuelPurchases.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Season Average")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if accessControl?.canViewFinancials ?? false {
                                Text(fmt.formatFuelCostPerUnit(perLitre: store.seasonFuelCostPerLitre))
                                    .font(.headline.bold())
                                    .foregroundStyle(VineyardTheme.olive)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Total Purchased")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            let totalVol = store.fuelPurchases.reduce(0) { $0 + $1.volumeLitres }
                            Text(fmt.formatFuel(litres: totalVol, fractionDigits: 0))
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Label("Fuel Purchases", systemImage: "fuelpump.circle.fill")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                    Spacer()
                    if canManageSetup {
                        Button {
                            showAddFuelSheet = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.body)
                        }
                    }
                }
            } footer: {
                if canManageSetup {
                    Text("Record fuel purchases to calculate an average cost per litre for the season.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Fuel Purchases")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.fuelPurchases.isEmpty {
                ContentUnavailableView {
                    Label("No Fuel Purchases", systemImage: "fuelpump.circle.fill")
                } description: {
                    Text(canManageSetup
                         ? "Record fuel purchases to calculate an average cost per litre."
                         : "No fuel purchases have been recorded yet.")
                }
            }
        }
        .sheet(isPresented: $showAddFuelSheet) {
            FuelPurchaseFormSheet(purchase: nil)
        }
        .sheet(item: $editingFuelPurchase) { item in
            FuelPurchaseFormSheet(purchase: item)
        }
    }
}
