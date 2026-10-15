#if DEBUG
import SwiftUI

/// Exercises the production chemical card with synthetic local evidence; never an authenticated workflow.
struct SprayChemicalEditingValidationView: View {
    private static let chemical = SavedChemical(name: "Synthetic editing product", unit: .litres,
        rates: [ChemicalRate(label: "Confirmed example", value: 1000, basis: .perHectare)])
    @State private var line: ChemicalLine = ChemicalLine(chemicalId: chemical.id, selectedRateId: UUID(), overrideRate: 1000)
    @State private var showsCard: Bool = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Production card — synthetic data").accessibilityIdentifier("chemical.validation.ready")
                    Text(line.overrideRate.map(String.init(describing:)) ?? "nil").accessibilityIdentifier("chemical.validation.base")
                    Text(line.applicationRateDraft ?? "none").accessibilityIdentifier("chemical.validation.raw")
                    if showsCard {
                        CalcChemicalLineCard(line: $line, chemicals: [Self.chemical], preferredRateBases: [.perHectare], onInspect: {}, onDelete: {})
                    }
                    Button("Reopen card") { showsCard.toggle() }
                    Button("Confirmed rate") {
                        line.applicationRateDraft = nil
                        line.overrideRate = nil
                        line.selectedRateId = Self.chemical.rates.first?.id ?? UUID()
                    }
                }.padding()
            }
        }
    }
}
#endif
