import SwiftUI

/// The E-L colour ramp, drawn from the contract's own stops so the legend can
/// never drift from the surface it describes.
struct ELRipenessLegendView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var gradient: LinearGradient {
        let span = ELRipeness.elMax - ELRipeness.elMin
        let stops: [Gradient.Stop] = ELRipeness.colourStops.map { stop in
            let rgb = stop.rgb
            return Gradient.Stop(
                color: Color(
                    red: Double(rgb.r) / 255,
                    green: Double(rgb.g) / 255,
                    blue: Double(rgb.b) / 255
                ),
                location: span > 0 ? (stop.el - ELRipeness.elMin) / span : 0
            )
        }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule()
                .fill(gradient)
                .frame(height: 10)
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ELRipeness.colourStops, id: \.el) { stop in
                        Text(stop.label).font(.caption2)
                    }
                }
            } else {
                HStack {
                    Text("E-L 1").font(.caption2)
                    Spacer()
                    Text("E-L 23").font(.caption2)
                    Spacer()
                    Text("E-L 43").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour scale from E-L 1 dormant, red, through E-L 23 mid-season, yellow, to E-L 43 harvest ripe, green")
    }
}

/// Explains what the surface is and — just as importantly — what it is not.
struct ELRipenessInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ELRipenessLegendView()
                        .padding(.vertical, 4)
                } header: {
                    Text("Colour scale")
                }

                Section {
                    infoRow(
                        title: "Current",
                        detail: "Recorded within the last 84 days. These observations shape the heat surface, and only these are used for the median."
                    )
                    infoRow(
                        title: "Stale",
                        detail: "Older than 84 days. Still shown on the map so you can see where you have been, but they no longer colour the surface."
                    )
                    infoRow(
                        title: "Unassigned",
                        detail: "No block recorded for the observation. It is drawn where it was captured but is excluded from every block's surface and median. Block identity is never guessed from GPS."
                    )
                } header: {
                    Text("Pin states")
                }

                Section {
                    infoRow(
                        title: "One observation",
                        detail: "A halo is drawn around the observation rather than filling the block, because a single point cannot describe a whole block."
                    )
                    infoRow(
                        title: "Two observations",
                        detail: "A limited gradient is drawn between them."
                    )
                    infoRow(
                        title: "Three or more",
                        detail: "The full interpolated surface fills the block."
                    )
                } header: {
                    Text("Sparse data")
                } footer: {
                    Text("Recent observations count for more than older ones, and influence fades to nothing at 84 days.")
                }

                Section {
                    Text("E-L 47 (harvest) sits outside the 1–43 ripeness scale, so it is never drawn on the heat surface and never counted in a median. It is not rounded down to E-L 43 — that would invent ripeness data. E-L 47 records remain in the Growth Stage Summary.")
                        .font(.footnote)
                } header: {
                    Text("Why E-L 47 is not shown")
                }

                Section {
                    Text("Each block is drawn independently and clipped to its own boundary, so an observation in one block can never tint a neighbouring block — even where two blocks share an edge.")
                        .font(.footnote)
                } header: {
                    Text("Block isolation")
                }
            }
            .navigationTitle("About this map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func infoRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
