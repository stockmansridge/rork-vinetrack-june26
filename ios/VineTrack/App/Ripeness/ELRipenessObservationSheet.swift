import SwiftUI

/// Detail for a single observation, presented as a bottom sheet from the map.
///
/// Everything shown here is derived from the same values that drove the
/// surface, so the sheet can never disagree with the pixels behind it.
struct ELRipenessObservationSheet: View {
    let observation: ELRipeness.Observation
    let blockName: String?
    let atDateISO: String

    @Environment(\.dismiss) private var dismiss

    private var ageDays: Int {
        ELRipeness.daysBetween(observation.dateISO, atDateISO)
    }

    private var weight: Double {
        ELRipeness.recencyWeight(ageDays: ageDays)
    }

    private var isInfluencing: Bool {
        ageDays >= 0 && weight > 0
    }

    private var stageColour: Color {
        let rgb = ELRipeness.elColour(observation.el)
        return Color(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(stageColour)
                            .frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 2))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ELRipeness.formatEl(observation.el))
                                .font(.title3.weight(.semibold))
                            Text(statusText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    detailRow("Block", observation.assigned ? (blockName ?? "Unknown block") : PinPlacementContract.unassignedLocationLabel)
                    detailRow("Recorded", ELRipeness.dayKey(observation.dateISO))
                    detailRow("Age at this date", ageText)
                    detailRow("Influence weight", isInfluencing ? String(format: "%.3f", weight) : "0 — outside the 84-day window")
                    detailRow("Coordinates", String(format: "%.5f, %.5f", observation.lat, observation.lng))
                }

                if !observation.assigned {
                    Section {
                        Text("This observation has no block recorded, so it is excluded from every block's heat surface and median. Assign it to a block from the pin itself to include it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if !isInfluencing {
                    Section {
                        Text("This observation is older than 84 days, so it no longer contributes to the surface or the median. It stays on the map as a record of where you have been.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Observation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusText: String {
        if !observation.assigned { return "Unassigned — not used in any block" }
        return isInfluencing ? "Currently influencing the surface" : "Stale — no longer influencing"
    }

    private var ageText: String {
        if ageDays < 0 { return "Recorded after this date" }
        if ageDays == 0 { return "Same day" }
        return ageDays == 1 ? "1 day" : "\(ageDays) days"
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
