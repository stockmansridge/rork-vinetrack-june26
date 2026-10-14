import SwiftUI

/// Optional advisory with view-local presentation state; opening it never mutates the recipe.
struct SprayConcentrationWarningView: View {
    let products: [String]
    @State private var isPresented: Bool = false

    var body: some View {
        if !products.isEmpty {
            Button { isPresented = true } label: {
                Label("WARNING", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("spray.concentrationWarning")
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(SprayPlanningOperationalGate.warningMessage)
                            Text("Affected chemicals").font(.headline)
                            ForEach(products, id: \.self) { Text($0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .navigationTitle(SprayPlanningOperationalGate.warningTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { isPresented = false }
                    } }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}
