import SwiftUI

/// Bundled operator help. Presentation state only; no store or network access.
struct SprayProgramHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    helpCard("How the Spray Program Works") {
                        Text("Your **Program** is your vineyard’s seasonal application plan. It is built from reusable **Program Steps**.")
                    }
                    helpCard("Program Steps") {
                        Text("Each Program Step describes an application you may want to use during the season, including the products, rates, application method, target and E-L growth stage.")
                        Text("A Program Step can use one of the supported application methods:")
                        Text("• **Foliar Spray** — applications to the vine canopy")
                        Text("• **Banded Spray** — targeted applications such as under-vine spraying")
                        Text("• **Spreader** — applications made using spreading equipment")
                        Text("• **Fertigation** — products applied through the irrigation system")
                        Text("A Program Step is a reusable plan — it is **not** a completed application.")
                        Text("You can use the **same Program Step more than once during a season**. Each use creates its own application record while the original Program Step remains available to use again.")
                    }
                    helpCard("Program tab") {
                        Text("The **Program** tab contains the reusable Program Steps for the vineyard.")
                        Text("Program Steps are sorted by **E-L growth stage from lowest to highest by default**, helping operators work through the program in approximate seasonal order.")
                        Text("The existing sort controls can still be used to change this order.")
                        Text("Select a Program Step to review it and use **Plan from Program** when preparing an application.")
                    }
                    helpCard("Sprays tab") {
                        Text("The **Sprays** tab shows the actual applications for the season.")
                        definition("Upcoming", "Applications that have been planned but not yet started, together with the next relevant Program Steps in the seasonal program.")
                        definition("In Progress", "Applications that have been started but have not yet been completed.")
                        definition("Completed", "Applications that have been finished and recorded.")
                        definition("All", "All spray/application records.")
                    }
                    helpCard("Program vs Sprays") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Program = what you plan to do.")
                            Text("Sprays = what you are doing or have done.")
                        }
                        .font(.headline)
                        .foregroundStyle(VineyardTheme.leafGreen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(VineyardTheme.leafGreen.opacity(0.1), in: .rect(cornerRadius: 10))
                        Text("Your Program Steps remain reusable and can be used multiple times during the season. Each actual application is recorded separately.")
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("How the Spray Program Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func helpCard<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VineyardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                content()
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func definition(_ title: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            Text(explanation)
        }
    }
}
