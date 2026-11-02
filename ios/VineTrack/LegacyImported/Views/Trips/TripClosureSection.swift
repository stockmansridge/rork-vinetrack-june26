import SwiftUI

/// P0 Phase C (Issue #40): an ended Trip is reported fully synced only as CLOSED_SYNCED, which
/// requires every dependent acknowledged; "verified" additionally needs a fresh server read.
/// Behaviour matches Android `TripClosureCard`; read-only.
struct TripClosureSection: View {
    let trip: Trip
    @Environment(MigratedDataStore.self) private var store
    @State private var verified: TripClosureStatus.Result?
    @State private var lastInput: TripClosureStatus.Input?
    @State private var checking = false

    private var service: TripActivityCancellationService { .shared }

    var body: some View {
        if trip.endTime != nil {
            let local = service.closureStatus(trip: trip, store: store)
            if local.state != .localEndPending {
                let shown = verified ?? local
                Section {
                    Label(title(shown), systemImage: symbol(shown.state))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint(shown.state))
                    Text(detail(shown.state)).font(.caption).foregroundStyle(.secondary)
                    Text("Status: \(shown.state.rawValue)").font(.caption2).foregroundStyle(.secondary)
                    Button {
                        Task { await verify() }
                    } label: {
                        Label(checking ? "Checking…" : "Check with server", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(checking)
                    Button {
                        let input = lastInput ?? service.closureInput(trip: trip, store: store, fresh: nil)
                        UIPasteboard.general.string = (["VineTrack Trip closure status v1", "platform: iOS",
                            "verified_recovery_source: 4e177a9109f3f729d16c11a527cf64e3fe443611; public: 64516a77082f3eb4b3917c7cf10170dbf3c31b19; diagnostic_overlay: issue41-rc1",
                            "version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")"] +
                            TripClosureStatus.diagnosticLines(input, TripClosureStatus.evaluate(input))).joined(separator: "\n")
                    } label: {
                        Label("Copy Trip status", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("Sync status")
                }
            }
        }
    }

    private func verify() async {
        checking = true
        let (input, result) = await service.verifyClosure(trip: trip, store: store)
        lastInput = input
        verified = result
        checking = false
    }

    private func title(_ r: TripClosureStatus.Result) -> String {
        switch r.state {
        case .closedSynced: return verified != nil ? "Closed and synced · verified with server" : "Closed and synced"
        case .localEndPending: return "Ended on this device · waiting to sync"
        case .dependentsPending: return "Ended · records still syncing"
        case .dependentsHeld: return "Ended · sync held for review"
        case .serverStateUnconfirmed: return "Ended · server state not confirmed"
        case .active: return "Server still shows this Trip active"
        }
    }

    private func detail(_ s: TripClosureStatus.State) -> String {
        switch s {
        case .closedSynced: return "The server shows this Trip ended, and its tank records, actual amounts, spray record and route are all acknowledged."
        case .localEndPending: return "The end is saved here and will finish on the server when sync completes. Recorded GPS and tank amounts are kept."
        case .dependentsPending: return "The Trip has ended but some linked records have not been acknowledged by the server yet. They are kept and will retry automatically."
        case .dependentsHeld: return "A linked record could not be confirmed on the server. Nothing has been discarded. Copy the Trip status and send it to support."
        case .serverStateUnconfirmed: return "The server could not confirm this Trip's ended state. Nothing has been changed. Try again when online."
        case .active: return "This device recorded an end, but the server row is not terminal. Nothing has been discarded."
        }
    }

    private func symbol(_ s: TripClosureStatus.State) -> String {
        switch s {
        case .closedSynced: return "checkmark.seal.fill"
        case .dependentsHeld, .active: return "exclamationmark.triangle.fill"
        case .serverStateUnconfirmed: return "questionmark.circle"
        default: return "icloud.and.arrow.up"
        }
    }

    private func tint(_ s: TripClosureStatus.State) -> Color {
        switch s {
        case .closedSynced: return .green
        case .dependentsHeld, .active: return .orange
        default: return VineyardTheme.olive
        }
    }
}
