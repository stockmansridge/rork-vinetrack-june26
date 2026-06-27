#if DEBUG
import SwiftUI

/// DEBUG-only diagnostic harness for MigratedDataStore. Not wired into production navigation.
struct MigratedDataStoreDiagnosticView: View {
    @State private var store = MigratedDataStore()
    @State private var log: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section("State") {
                    LabeledContent("Vineyards", value: "\(store.vineyards.count)")
                    LabeledContent("Selected", value: store.selectedVineyard?.name ?? "—")
                    LabeledContent("Pins", value: "\(store.pins.count)")
                    LabeledContent("Paddocks", value: "\(store.paddocks.count)")
                    LabeledContent("Trips", value: "\(store.trips.count)")
                    LabeledContent("Spray records", value: "\(store.sprayRecords.count)")
                    LabeledContent("Work tasks", value: "\(store.workTasks.count)")
                    LabeledContent("Maintenance logs", value: "\(store.maintenanceLogs.count)")
                }

                Section("Actions") {
                    Button("Create local vineyard") { createVineyard() }
                    Button("Create local pin") { createPin() }
                    Button("Create local paddock") { createPaddock() }
                    Button("Create local spray record") { createSpray() }
                    Button("Reload current vineyard data") {
                        store.reloadCurrentVineyardData()
                        append("Reloaded data for \(store.selectedVineyard?.name ?? "—")")
                    }
                    Button("Clear in-memory state") {
                        store.clearInMemoryState()
                        append("Cleared in-memory state")
                    }
                    Button("Delete all local data", role: .destructive) {
                        store.deleteAllLocalData()
                        append("Deleted all local data")
                    }
                }

                Section("Log") {
                    if log.isEmpty {
                        Text("No actions yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.footnote.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("MigratedDataStore")
        }
    }

    private func createVineyard() {
        let v = Vineyard(name: "Debug Vineyard \(store.vineyards.count + 1)", country: "AU")
        store.upsertLocalVineyard(v)
        append("Added vineyard \(v.name) (selected: \(store.selectedVineyard?.name ?? "—"))")
    }

    private func createPin() {
        guard store.selectedVineyardId != nil else {
            append("No selected vineyard — create one first")
            return
        }
        let pin = VinePin(
            latitude: -34.5,
            longitude: 138.5,
            heading: 0,
            buttonName: "Debug",
            buttonColor: "blue",
            side: .left,
            mode: .repairs
        )
        store.addPin(pin)
        append("Added pin (total \(store.pins.count))")
    }

    private func createPaddock() {
        guard store.selectedVineyardId != nil else {
            append("No selected vineyard — create one first")
            return
        }
        let paddock = Paddock(name: "Debug Paddock \(store.paddocks.count + 1)")
        store.addPaddock(paddock)
        append("Added paddock (total \(store.paddocks.count))")
    }

    private func createSpray() {
        guard store.selectedVineyardId != nil else {
            append("No selected vineyard — create one first")
            return
        }
        let record = SprayRecord(sprayReference: "DEBUG-\(store.sprayRecords.count + 1)")
        store.addSprayRecord(record)
        append("Added spray record (total \(store.sprayRecords.count))")
    }

    private func append(_ message: String) {
        log.insert(message, at: 0)
    }
}

#Preview {
    MigratedDataStoreDiagnosticView()
}
#endif
