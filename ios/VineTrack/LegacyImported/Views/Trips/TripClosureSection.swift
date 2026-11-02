import SwiftUI

/// P0 Phase C (Issue #40): an ended Trip is reported fully synced only as CLOSED_SYNCED, which
/// requires every dependent acknowledged; "verified" additionally needs a fresh server read.
/// Behaviour matches Android `TripClosureCard`; read-only.
struct TripClosureSection: View {
    let trip: Trip
    @Environment(MigratedDataStore.self) private var store
    @Environment(TripSyncService.self) private var tripSync
    @State private var verified: TripClosureStatus.Result?
    @State private var lastInput: TripClosureStatus.Input?
    @State private var checking = false
    @State private var verifiedAgainst: TripClosureStatus.Input?
    @State private var verifiedTrip: Trip?

    private var service: TripActivityCancellationService { .shared }

    var body: some View {
        if trip.endTime != nil {
            let current = service.closureInput(trip: trip, store: store, fresh: nil)
            let local = TripClosureStatus.evaluate(current)
            let stillVerified = verifiedAgainst == current && verifiedTrip == trip
            let shown = stillVerified ? (verified ?? local) : local
            // A fresh server-end read is useful even while the original local
            // upload receipt remains pending. Do not turn this into CLOSED_SYNCED.
            let serverEndConfirmed = stillVerified && lastInput?.evidence == .freshRead &&
                lastInput?.serverIsActive == false &&
                lastInput?.serverEndTime == trip.endTime
            Group {
                Section {
                    Label(serverEndConfirmed && shown.state == .localEndPending
                          ? "Trip end confirmed on server · original local sync pending"
                          : title(shown, isVerified: stillVerified && verified != nil),
                          systemImage: symbol(shown.state))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint(shown.state))
                    Text(serverEndConfirmed && shown.state == .localEndPending
                         ? "This exact Trip end exists on the server. The original phone's local upload and dependent-record receipts are still being reconciled; nothing was re-uploaded, erased or marked fully synced."
                         : detail(shown.state))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Status: \(shown.state.rawValue)").font(.caption2).foregroundStyle(.secondary)
                    if let receiptHold = tripSync.receiptReconciliationHolds[trip.id] {
                        Label("Original local record held: \(receiptHold)",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("trip.receiptReconciliationHold")
                    }
                    Button {
                        Task { await verify() }
                    } label: {
                        Label(checking ? "Verifying…" : "Verify & reconcile with server", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(checking)
                    Button {
                        let input = stillVerified ? (lastInput ?? current) : current
                        UIPasteboard.general.string = (["VineTrack Trip closure status v1", "platform: iOS",
                            "source_revision: unknown_no_verified_build_receipt",
                            "version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")"] +
                            TripClosureStatus.diagnosticLines(input, TripClosureStatus.evaluate(input))).joined(separator: "\n")
                    } label: {
                        Label("Copy Trip status", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("Sync status")
                }
            }
            .task(id: trip.id) {
                // A one-time read-only check when an ended Trip is opened.
                // The explicit button remains available for another check.
                // Never replay, acknowledge or delete historical queue entries.
                guard store.selectedVineyardId == trip.vineyardId,
                      NetworkMonitor.shared.isOnline else { return }
                await verify()
            }
            .onChange(of: current) { _, _ in
                verified = nil; lastInput = nil; verifiedAgainst = nil; verifiedTrip = nil
            }
            .onChange(of: trip) { _, _ in
                verified = nil; lastInput = nil; verifiedAgainst = nil; verifiedTrip = nil
            }
        }
    }

    private func verify() async {
        checking = true
        let before = service.closureInput(trip: trip, store: store, fresh: nil)
        let capturedTrip = trip
        let (input, result) = await service.verifyClosure(trip: capturedTrip, store: store)
        // A matching, independently read server end can now reconcile the
        // exact original pending Trip ID. This never sends a second End or
        // replays the legacy queue: the sync service verifies GPS, tank
        // sessions, completed Spray and actual chemical quantities first.
        // If any evidence differs, the original operation remains held.
        if input.evidence == .freshRead,
           input.serverIsActive == false,
           input.serverEndTime == capturedTrip.endTime,
           input.linkedSprayIssue == nil,
           input.pendingActualIds.isEmpty,
           input.occurrencePending == 0,
           input.occurrenceHeldReason == nil {
            _ = await tripSync.reconcileServerEndedTrip(capturedTrip.id)
        }
        let after = service.closureInput(trip: trip, store: store, fresh: nil)
        if before == after && capturedTrip == trip {
            lastInput = input
            verified = result
            verifiedAgainst = after
            verifiedTrip = capturedTrip
        } else {
            verified = nil; lastInput = nil; verifiedAgainst = nil; verifiedTrip = nil
        }
        checking = false
    }

    private func title(_ r: TripClosureStatus.Result, isVerified: Bool) -> String {
        switch r.state {
        case .closedSynced: return isVerified ? "Closed and synced · verified with server" : "Closed and synced"
        case .localEndPending: return "Ended on this device · waiting to sync"
        case .dependentsPending: return "Ended · records still syncing"
        case .dependentsHeld: return "Ended · sync held for review"
        case .serverStateUnconfirmed: return "Ended · server state not confirmed"
        case .active: return "Server still shows this Trip active"
        }
    }

    private func detail(_ s: TripClosureStatus.State) -> String {
        switch s {
        case .closedSynced: return "The retained evidence shows a matching Trip and linked Spray End with no outstanding required dependencies. Check with server for an independent current read."
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
