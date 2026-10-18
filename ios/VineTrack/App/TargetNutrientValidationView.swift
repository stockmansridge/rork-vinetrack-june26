#if DEBUG
import SwiftUI

/// Isolated production preview with synthetic blocks; no store, account or network callbacks.
struct TargetNutrientValidationView: View {
    var body: some View {
        NavigationStack {
            TargetNutrientPreviewView(products: [], paddocks: [
                Paddock(name: "Synthetic A", vineSpacing: 2, vineCountOverride: 4200, rowLengthOverride: 10000),
                Paddock(name: "Synthetic B", vineSpacing: 2, vineCountOverride: 3600, rowLengthOverride: 8000)
            ], formatter: RegionFormatter(settings: OrganizationRegionSettings()), isSystemAdmin: !CommandLine.arguments.contains("--nutrient-non-admin"))
            .navigationTitle("Target Nutrient fixture")
        }
    }
}
#endif
