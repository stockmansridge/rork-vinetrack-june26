#if DEBUG
import SwiftUI

/// Isolated native presentation fixture; no account, persistence or transport.
struct SprayPresentationValidationView: View {
    @State private var configuration: SprayPassConfiguration? = .standardPass
    @State private var method: SprayPlanningMethod = .fullTank
    @State private var specification: SprayFullTankSpecification = .targetArea
    @State private var tank: String = "1500"
    @State private var area: String = "3"
    @State private var rate: String = "500"
    @State private var operatorDraft: String = "125"
    @State private var selected: UUID?
    @State private var showingRates: Bool = false
    private let firstID: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let secondID: UUID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private var options: [SpraySelectableRate] {
        [SpraySelectableRate(id: firstID, origin: .registeredUse, crop: "Wine grapevines", targetRaw: "Powdery mildew",
            label: "Dilute", basis: .per100Litres, seed: .range(minimum: 200, maximum: 600), displayText: "200–600 g/100 L", labelUnit: "g",
            condition: "Apply from budburst onwards. Preserve the complete registered-use conditions without truncation.",
            registeredUse: ChemicalRegisteredUse(crop: "Wine grapevines", targetRaw: "Powdery mildew", restrictions: "Do not exceed the seasonal maximum.")),
         SpraySelectableRate(id: secondID, origin: .registeredUse, crop: "Wine grapevines", targetRaw: "Downy mildew",
            label: "Separate registered direction", basis: .per100Litres, seed: .range(minimum: 150, maximum: 200), displayText: "150–200 g/100 L", labelUnit: "g")]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SYNTHETIC PRESENTATION FIXTURE — NOT AUTHENTICATED ACCEPTANCE").font(.caption)
                    Text(selected == nil ? "No rate selected" : "Explicit rate selected").accessibilityIdentifier("spray.fixture.selection")
                    TextField("Operator draft", text: $operatorDraft)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("spray.fixture.draft")
                    Button("Select label rate") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        showingRates = true
                    }
                    SprayConcentrationWarningView(products: ["Synthetic sulphur", "Synthetic copper"])
                    SprayPlanningCardsView(configuration: $configuration, method: $method, specification: $specification,
                        tankText: $tank, areaText: $area, rateText: $rate, region: .australian, rowSpacingMetres: 2.8,
                        resolution: SprayPlanningIntent(configuration: configuration, method: method, fullTankSpecification: specification,
                            intendedTankLitres: 1500, targetAreaHa: 3).resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 713))
                }.padding()
            }.navigationTitle("Spray presentation")
            .sheet(isPresented: $showingRates) {
                SprayLabelRateSelectionView(rates: options, selectedID: selected) { selected = $0.id }
            }
        }
    }
}

#Preview("Single Row / Only Full Tanks / warning") { SprayPresentationValidationView() }
#endif
