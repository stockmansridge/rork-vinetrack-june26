import SwiftUI

/// Shared by the production tab shell and isolated mounted performance fixture.
struct VineyardLoadingPresentation: ViewModifier {
    @Environment(MigratedDataStore.self) private var store
    func body(content: Content) -> some View {
        content
            .allowsHitTesting(store.preparingVineyard == nil)
            .overlay {
                if let vineyard = store.preparingVineyard {
                    VStack(spacing: 12) {
                        Text(vineyard.name).font(.headline)
                        ProgressView("Loading vineyard…")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .accessibilityIdentifier("vineyard-selection-loading")
                }
            }
    }
}
