import SwiftUI

/// Issue #54. Counts every bunch in one explicit post-to-post panel.
/// Raw panel measurements are never disguised as single-vine observations.
struct PanelCountEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    let site: SampleSite
    /// Block config Intermediate Post Spacing (metres) — the post-to-post panel length.
    var blockPanelLengthMetres: Double? = nil
    let onSave: (PanelCountMeasurement, String) -> Bool

    private var configuredLength: Double? {
        guard let value = blockPanelLengthMetres, value.isFinite, value > 0 else { return nil }
        return value
    }

    @State private var totalBunches = ""
    @State private var plantedPositions = ""
    @State private var fruitingVines = ""
    @State private var missingPositions = ""
    @State private var nonproductiveVines = ""
    @State private var panelLength = ""
    @State private var recordedBy = ""
    @State private var saveFailed = false

    private var validated: PanelCountMeasurement? {
        guard let total = Int(totalBunches),
              let planted = Int(plantedPositions),
              let fruiting = Int(fruitingVines),
              let missing = Int(missingPositions),
              let nonproductive = Int(nonproductiveVines) else { return nil }
        let optionalLength: Double?
        if let configuredLength {
            // Panel length comes from the block config; never typed when it is set.
            optionalLength = configuredLength
        } else if panelLength.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            optionalLength = nil
        } else {
            optionalLength = Double(panelLength.replacingOccurrences(of: ",", with: "."))
            guard optionalLength != nil else { return nil }
        }
        return PanelCountMeasurement.make(
            totalBunches: total, plantedPositions: planted,
            fruitingVines: fruiting, missingPositions: missing,
            nonproductiveVines: nonproductive, panelLengthMetres: optionalLength
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sample #\(site.siteIndex) · \(site.paddockName)")
                        .font(.headline)
                    Text("Count all bunches in a single post-to-post panel. Record how many planting positions are present, including missing and nonproductive positions.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let row = site.yieldRowReference {
                        Text("Row \(row)" + (site.yieldPanelReference.map { " · Panel \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Post-to-post panel observations") {
                    integerField("Total bunches counted", text: $totalBunches)
                    integerField("Planted positions (including missing)", text: $plantedPositions)
                    integerField("Fruiting vines counted", text: $fruitingVines)
                    integerField("Missing positions", text: $missingPositions)
                    integerField("Nonproductive vines", text: $nonproductiveVines)
                    if let configuredLength {
                        LabeledContent("Panel length") {
                            Text(String(format: "%.2f m", configuredLength))
                        }
                        Text("From the block's Intermediate Post Spacing.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("This block has no Intermediate Post Spacing set. Add it in the block settings so panel length fills in automatically.")
                            .font(.caption).foregroundStyle(.orange)
                        HStack {
                            Text("Panel length (metres, optional)")
                            Spacer()
                            TextField("e.g. 6.0", text: $panelLength)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 105)
                        }
                    }
                    TextField("Recorded by", text: $recordedBy)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    if let validated {
                        Label(String(format: "%.2f bunches per planted position",
                                     validated.bunchesPerPlantingPosition), systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        Text("Planted positions must equal fruiting vines + missing positions + nonproductive vines. All values must be whole numbers at least zero and planted positions must exceed zero.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Panel Count is stored as its own method and does not automatically replace the vineyard's current Yield Estimate.")
                        .font(.caption).foregroundStyle(.secondary)
                    if saveFailed {
                        Text("The reading could not be saved locally. Your form is unchanged; please retry.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Panel Count")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Record Panel") {
                        guard let validated else { return }
                        if onSave(validated, recordedBy) { dismiss() }
                        else { saveFailed = true }
                    }
                    .disabled(validated == nil)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let prior = site.panelCountEntry {
                    let m = prior.measurement
                    totalBunches = String(m.totalBunches)
                    plantedPositions = String(m.plantedPositions)
                    fruitingVines = String(m.fruitingVines)
                    missingPositions = String(m.missingPositions)
                    nonproductiveVines = String(m.nonproductiveVines)
                    panelLength = m.panelLengthMetres.map { String($0) } ?? ""
                    recordedBy = prior.recordedBy
                }
            }
        }
    }

    @ViewBuilder
    private func integerField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 88)
                .accessibilityLabel(label)
        }
    }
}
