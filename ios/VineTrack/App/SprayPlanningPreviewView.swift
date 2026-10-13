#if DEBUG
import SwiftUI

/// Synthetic UI-only fixture: production cards, no store, authentication or transport.
struct SprayPlanningPreviewView: View {
    let configuration: SprayPassConfiguration
    let specification: SprayFullTankSpecification

    private var intent: SprayPlanningIntent {
        SprayPlanningIntent(configuration: configuration, method: .fullTank, fullTankSpecification: specification,
            intendedTankLitres: 1500, targetAreaHa: specification == .targetArea ? 3 : nil,
            calibratedLitresPerHectare: specification == .calibratedRate ? 500 : nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Spray Calculator").font(.title2.bold())
                Text("SYNTHETIC UI PREVIEW • NOT DEVICE ACCEPTANCE").font(.caption.bold()).foregroundStyle(.secondary)
                Text("Application volume basis: L/100m controller travel").font(.subheadline)
                SprayPlanningCardsView(configuration: .constant(configuration), method: .constant(.fullTank),
                    specification: .constant(specification), tankText: .constant("1500"), areaText: .constant("3"),
                    rateText: .constant(configuration == .standardPass ? "14" : "28"), region: .australian,
                    rateUnit: "L/100m", rowSpacingMetres: 2.8,
                    resolution: intent.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 500))
            }.padding(16)
        }.background(Color(.systemGroupedBackground))
    }
}

#Preview("Standard Pass • 1500 L / 3 ha") {
    SprayPlanningPreviewView(configuration: .standardPass, specification: .targetArea)
}

#Preview("Over-Row • 1500 L / 3 ha") {
    SprayPlanningPreviewView(configuration: .overRow, specification: .targetArea)
}

#Preview("Over-Row • selected L/100m") {
    SprayPlanningPreviewView(configuration: .overRow, specification: .calibratedRate)
}
#endif
